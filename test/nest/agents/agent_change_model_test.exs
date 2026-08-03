defmodule Nest.Agents.Agent.ChangeModelTest do
  @moduledoc """
  Tests for `Agent.set_model/2` and the recovery flow that
  transitions an agent from `:model_missing` back to `:idle`
  via `Agents.change_model/2`.

  The atomicity of `Persistence.update_agent_model/2` is
  covered separately in `test/nest/persistence_test.exs`.
  """

  use Nest.DataCase, async: true

  import Mimic

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.AnthropicClient
  alias Nest.LLM.OpenAIClient
  alias Nest.LLM.RecoveryClient
  alias Nest.Persistence
  alias Nest.Repo

  setup :verify_on_exit!

  setup do
    vid = AgentTestHelpers.vocation_id_for_test()
    Process.put(:test_vocation_id, vid)

    # The DataCase's automatic sandbox rollback covers
    # the agent rows. A `for id <- ...; delete_agent(id)`
    # here would deadlock on `DBConnection.OwnershipError`
    # because `on_exit` runs in `ExUnit.OnExitHandler`'s
    # runner process — no sandbox ownership. See
    # `agent_file_policy_test.exs` for the canonical
    # version of this comment.
    on_exit(fn -> :ok end)

    :ok
  end

  defp vid, do: Process.get(:test_vocation_id)

  defp persist_and_start!(attrs) do
    name = Map.fetch!(attrs, :name)

    {:ok, _row} =
      Persistence.insert_agent(Map.put(attrs, :vocation_id, vid()))

    {:ok, ^name} = Supervisor.fetch_or_start_agent(attrs)
    {:ok, pid} = Supervisor.get_agent(name)

    # Runtime DB writes from the agent pid (`set_model/2`
    # calls `Persistence.update_agent_model/2`) need
    # explicit sandbox access — the supervisor-spawned
    # child doesn't inherit the test pid's `$callers`.
    Sandbox.allow(Repo, self(), pid)

    {pid, name}
  end

  describe "Agent.set_model/2 happy path" do
    test "updates state.client_config and state.model in place" do
      {pid, _name} =
        persist_and_start!(%{
          name: "switch-agent",
          model: %{name: "qwen3.5-plus", provider: "model-studio"},
          vocation_id: vid()
        })

      state_before = :sys.get_state(pid)
      assert state_before.client_config.client == OpenAIClient

      :ok =
        Agent.set_model(pid, %{
          name: "claude-3-opus-20240229",
          provider: "anthropic-provider"
        })

      state = :sys.get_state(pid)
      assert state.client_config.client == AnthropicClient

      assert state.model == %{
               name: "claude-3-opus-20240229",
               provider: "anthropic-provider"
             }

      assert state.chat_state.status == :idle
    end

    test "broadcasts chat:status with the new model" do
      {pid, name} =
        persist_and_start!(%{
          name: "broadcast-agent",
          model: %{name: "qwen3.5-plus", provider: "model-studio"},
          vocation_id: vid()
        })

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{name}")

      Agent.set_model(pid, %{name: "claude-3-opus-20240229", provider: "anthropic-provider"})

      assert_receive {:chat_status, payload}, 500
      assert payload.status == "idle"

      assert payload.model == %{
               "name" => "claude-3-opus-20240229",
               "provider" => "anthropic-provider"
             }
    end
  end

  describe "Agent.set_model/2 refusal paths" do
    test "rejects while the agent is :streaming" do
      {pid, _name} =
        persist_and_start!(%{
          name: "busy-agent",
          model: %{name: "qwen3.5-plus", provider: "model-studio"},
          vocation_id: vid()
        })

      # Force the agent into :streaming without an actual LLM call.
      :sys.replace_state(pid, fn state ->
        %{state | chat_state: %{state.chat_state | status: :streaming}}
      end)

      state_before = :sys.get_state(pid)

      result =
        Agent.set_model(pid, %{
          name: "claude-3-opus-20240229",
          provider: "anthropic-provider"
        })

      assert result == {:error, :agent_busy}

      state_after = :sys.get_state(pid)
      assert state_after.client_config.client == state_before.client_config.client
      assert state_after.model == state_before.model
      assert state_after.chat_state.status == :streaming
    end

    test "rejects an unknown model with :invalid_model" do
      {pid, _name} =
        persist_and_start!(%{
          name: "unknown-agent",
          model: %{name: "qwen3.5-plus", provider: "model-studio"},
          vocation_id: vid()
        })

      state_before = :sys.get_state(pid)

      result = Agent.set_model(pid, %{name: "ghost-model-from-nowhere", provider: "nope"})
      assert {:error, {:invalid_model, %Nest.ChatModel.ModelNotFoundError{}}} = result

      state_after = :sys.get_state(pid)
      assert state_after.model == state_before.model
    end
  end

  describe "recovery from :model_missing" do
    test "transitioning to :idle updates status and persists the model" do
      # Force a :model_missing start by stubbing out the lookup
      # for the `:name` key. Other names go through the real
      # `DotConfig.get_model/2` since the helper is a passthrough
      # except for the stubbed name.
      #
      # The model-probe failure fires a `Logger.error` from
      # `Agent.init/1` — capture it and assert it's the
      # expected error path, not noise. Use a unique agent name
      # so the asserted substring is specific to this test's
      # agent (concurrent async tests' `:model_missing` agents
      # also log the same phrase, which would make a generic
      # substring match hit-or-miss under parallel load).
      agent_name = "ghost-agent-#{System.unique_integer([:positive])}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Nest.Agents.Agent.Config
          |> stub(:create_client_config, fn model ->
            # `build_attrs_for_start/1` round-trips the JSONB
            # `model` column as string keys (Ecto's :map
            # deserialization). The stub sees the agent's
            # in-memory shape, which the supervisor reads back
            # from DB. Handle both shapes here so this test
            # doesn't depend on a specific keying.
            name = model[:name] || model["name"]

            if name == "ghost-model" do
              {:error, %Nest.ChatModel.ModelNotFoundError{message: "ghost"}}
            else
              real_fn = Function.capture(Nest.Agents.Agent.Config, :create_client_config, 1)
              real_fn.(model)
            end
          end)

          {pid, ^agent_name} =
            persist_and_start!(%{
              name: agent_name,
              model: %{name: "ghost-model"},
              vocation_id: vid()
            })

          state = :sys.get_state(pid)
          assert state.chat_state.status == :model_missing
          assert state.client_config.client == RecoveryClient

          # Repair through Agents.change_model/2.
          :ok =
            Agents.change_model(agent_name, %{
              name: "claude-3-opus-20240229",
              provider: "anthropic-provider"
            })

          state = :sys.get_state(pid)
          assert state.chat_state.status == :idle
          assert state.client_config.client == AnthropicClient

          assert state.model == %{
                   name: "claude-3-opus-20240229",
                   provider: "anthropic-provider"
                 }

          # The persisted row reflects the new model. Ecto's
          # `:map` column normalizes to string keys on read.
          {:ok, row} = Persistence.fetch_agent_by_name(agent_name)

          assert row.model == %{
                   "name" => "claude-3-opus-20240229",
                   "provider" => "anthropic-provider"
                 }
        end)

      assert log =~ "Agent #{agent_name} could not resolve model"
    end

    test "proxies {:error, reason} replies unchanged so the channel can pattern-match" do
      # Stub the persistence call so the change_model path
      # exercises its error branch.
      Nest.Agents.Agent
      |> stub(:set_model, fn _pid, _new_model ->
        {:error, :gen_server_timeout}
      end)

      {pid, name} =
        persist_and_start!(%{
          name: "busy-persist-agent",
          model: %{name: "qwen3.5-plus", provider: "model-studio"},
          vocation_id: vid()
        })

      assert {:error, :gen_server_timeout} =
               Agents.change_model(name, %{
                 name: "claude-3-opus-20240229",
                 provider: "anthropic-provider"
               })

      # State must not have been mutated. Model is stored as a
      # string-keyed map (jsonb JSON wire format).
      assert :sys.get_state(pid).model["name"] == "qwen3.5-plus"
    end

    test "preserves the MapSet invariant on crossed_thresholds" do
      # Regression for the `FunctionClauseError` reported on
      # `MapSet.member?(%{}, :p50)`: applying a new model
      # clears `chat_state.crossed_thresholds` so reminders
      # re-fire under the new model's context window, but the
      # reset must be a `MapSet.new()` — not a plain map — so
      # `ContextReminder.highest_unannounced/3` can call
      # `MapSet.member?/2` on the next chat turn.
      {pid, _name} =
        persist_and_start!(%{
          name: "threshold-invariant-agent",
          model: %{name: "qwen3.5-plus", provider: "model-studio"},
          vocation_id: vid()
        })

      # Seed the set with `:p25` so the path through
      # `apply_new_model/3` actually rewrites a non-empty
      # value — the bug was a plain `%{}` landing where a
      # `MapSet` was expected.
      :sys.replace_state(pid, fn state ->
        %{
          state
          | chat_state: %{
              state.chat_state
              | crossed_thresholds: MapSet.put(MapSet.new(), :p25)
            }
        }
      end)

      :ok =
        Agent.set_model(pid, %{
          name: "claude-3-opus-20240229",
          provider: "anthropic-provider"
        })

      state = :sys.get_state(pid)
      crossed = state.chat_state.crossed_thresholds

      assert is_struct(crossed, MapSet),
             "crossed_thresholds must be a MapSet (got #{inspect(crossed)})"

      # Empty after the model change, so reminders re-fire
      # under the new context window.
      assert MapSet.size(crossed) == 0

      # Sanity: every other writesite in the codebase
      # operates on this field as a MapSet — `MapSet.put/2`
      # must not raise.
      assert MapSet.put(crossed, :p50) |> MapSet.size() == 1
    end
  end

  describe "Agents.list_broken_agents/0 (persistence-enabled)" do
    test "includes an unresolvable agent that exists in the DB but not the Registry" do
      # Simulate the original "vanishing" bug: persist a row
      # with an unresolvable model directly (without starting
      # the agent, which avoids populating the Registry).
      # The DB row is sitting on disk, the lobby should
      # surface it, and the user can repair via change_model.
      attrs = %{
        name: "ghost-row-only",
        model: %{name: "ghost-model-from-disk"},
        vocation_id: vid()
      }

      {:ok, _} = Persistence.insert_agent(attrs)

      broken = Agents.list_broken_agents()

      assert Enum.any?(broken, fn entry ->
               entry.name == attrs.name and entry.status == :model_missing
             end)
    end

    test "drops an unresolvable agent that is alive in the Registry" do
      # When the agent is alive in the Registry (status may
      # be :model_missing or may have been recovered), the
      # lobby's broken list does NOT surface it — the user
      # already has the in-process handle, so a duplicate row
      # in `init.broken_agents` would be confusing.
      #
      # The model-probe failure fires a `Logger.error` from
      # `Agent.init/1` — capture it and assert it's the
      # expected error path, not noise. Use a unique agent name
      # so the asserted substring is specific to this test's
      # agent (concurrent async tests' `:model_missing` agents
      # also log the same phrase, which would make a generic
      # substring match hit-or-miss under parallel load).
      agent_name = "ghost-agent-#{System.unique_integer([:positive])}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Nest.Agents.Agent.Config
          |> stub(:create_client_config, fn model ->
            # `build_attrs_for_start/1` round-trips the JSONB
            # `model` column as string keys (Ecto's :map
            # deserialization). The stub sees the agent's
            # in-memory shape, which the supervisor reads back
            # from DB. Handle both shapes here so this test
            # doesn't depend on a specific keying.
            name = model[:name] || model["name"]

            if name == "ghost-model" do
              {:error, %Nest.ChatModel.ModelNotFoundError{message: "ghost"}}
            else
              real_fn = Function.capture(Nest.Agents.Agent.Config, :create_client_config, 1)
              real_fn.(model)
            end
          end)

          {_pid, ^agent_name} =
            persist_and_start!(%{
              name: agent_name,
              model: %{name: "ghost-model"},
              vocation_id: vid()
            })

          # Even though the agent's status is :model_missing,
          # it's alive in the Registry — `list_broken_agents/0`
          # skips it.
          broken = Agents.list_broken_agents()
          refute Enum.any?(broken, fn entry -> entry.name == agent_name end)
        end)

      assert log =~ "Agent #{agent_name} could not resolve model"
    end
  end
end
