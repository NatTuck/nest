defmodule Nest.AgentsTest do
  @moduledoc """
  Tests for the Agents context module.
  """
  use ExUnit.Case, async: false

  import Eventually
  import Mimic

  alias Nest.Agents
  alias Nest.Agents.Agent, as: AgentGenServer
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient

  setup :verify_on_exit!

  setup do
    # Agents supervision tree is already started by Application
    # Just need to clean up any agents from previous tests
    for id <- Agents.list_agents() do
      Agents.delete_agent(id)
    end

    # Note: we don't wipe /tmp/nest-VMPID/ because the path is
    # shared across all tests in this BEAM VM and wiping in setup
    # races with concurrent async tests' agents. Per-agent cleanup
    # is the agent's own responsibility in `terminate/2`.

    :ok
  end

  describe "create_agent/1" do
    test "creates agent with model map" do
      # Use a model map directly instead of looking up from DotConfig
      {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus", provider: "model-studio"})
      assert Regex.match?(~r/^[a-z]+-[a-z]+$/, id)
      assert {:ok, info} = Agents.get_info(id)
      assert info.model.name == "qwen3.5-plus"
    end

    test "enriches model with provider from DotConfig when only :name is given" do
      # Callers (e.g. NewAgentPage) send just %{name: ...}; the API
      # looks up the provider so the chat header can render
      # "provider: model-name".
      {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus"})
      assert {:ok, info} = Agents.get_info(id)
      assert info.model.name == "qwen3.5-plus"
      assert info.model.provider == "model-studio"
    end

    test "starts the agent in :model_missing state when the model is unresolvable" do
      # An unknown model used to make `create_agent/1` return
      # `{:error, %ChatModel.ModelNotFoundError{}}`. The recovery
      # flow keeps the row + the GenServer alive (status
      # `:model_missing`) and lets the user call `change_model/2`
      # to repair it instead of silently losing the agent.
      #
      # The unresolvable model fires a `Logger.error` from
      # `Agent.init/1` (the model probe failure) — capture
      # it and assert it's the expected error path, not noise.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, name} = Agents.create_agent(%{name: "custom-model"})
          assert is_binary(name)

          {:ok, info} = Agents.get_info(name)
          assert info.status == :model_missing
          assert info.model.name == "custom-model"
        end)

      assert log =~ "could not resolve model"
    end
  end

  describe "get_info/1" do
    test "returns agent public info" do
      {:ok, name} = Agents.create_agent(%{name: "qwen3.5-plus"})
      {:ok, info} = Agents.get_info(name)
      assert info.name == name
      assert info.model.name == "qwen3.5-plus"
      assert info.status == :idle
      assert info.message_count == 1
      assert info.partial == nil
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Agents.get_info("nonexistent")
    end
  end

  describe "get_agent/1 error propagation" do
    test "returns {:error, reason} when Supervisor.get_agent/1 times out" do
      # Regression for the post-`change_model` channel crash:
      # `Supervisor.get_agent/1` returned
      # `{:error, {:timeout, {GenServer, :call, [Nest.Models, :list, 5000]}}}`
      # when `Models.list/0` was unresponsive, and the previous
      # `get_agent/1` only matched `{:ok, _}` / `{:error, :not_found}`,
      # raising `CaseClauseError`. The catch-all now propagates
      # the underlying reason so `AgentChannel.join/3` returns
      # `{:error, %{"reason" => "agent_unavailable"}}` cleanly.
      Nest.Agents.Supervisor
      |> expect(:get_agent, fn _name ->
        {:error, {:timeout, {GenServer, :call, [Nest.Models, :list, 5000]}}}
      end)

      assert {:error, {:timeout, {GenServer, :call, [Nest.Models, :list, 5000]}}} =
               Agents.get_agent("any-name")
    end

    test "returns {:error, reason} for arbitrary non-{:ok, pid} reasons" do
      # Defensive: any error tuple (not just `:not_found` and not
      # just `:timeout`) must propagate so callers can pattern-match
      # or display a friendly message.
      Nest.Agents.Supervisor
      |> stub(:get_agent, fn _name -> {:error, :gen_server_timeout} end)

      assert {:error, :gen_server_timeout} = Agents.get_agent("any-name")
    end
  end

  describe "list_agents/0" do
    test "returns list of agent names" do
      {:ok, id1} = Agents.create_agent(%{name: "qwen3.5-plus"})
      {:ok, id2} = Agents.create_agent(%{name: "MiniMax-M2.5"})

      # This file is async; other tests' agents may be in the
      # registry too. Verify our two are present rather than
      # asserting a count.
      agents = Agents.list_agents()
      assert id1 in agents
      assert id2 in agents
    end

    test "returns empty list when no agents" do
      assert Agents.list_agents() == []
    end
  end

  describe "list_agents_info/0" do
    test "returns list of agent info" do
      {:ok, id1} = Agents.create_agent(%{name: "qwen3.5-plus"})
      {:ok, id2} = Agents.create_agent(%{name: "MiniMax-M2.5"})

      # See note in list_agents/0 test: async file, so we only
      # verify our two names are present, not the total count.
      agents_info = Agents.list_agents_info()
      assert Enum.any?(agents_info, fn info -> info.name == id1 end)
      assert Enum.any?(agents_info, fn info -> info.name == id2 end)
    end

    test "returns empty list when no agents" do
      assert Agents.list_agents_info() == []
    end
  end

  describe "chat/2" do
    test "sends message to agent" do
      {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus"})
      {:ok, agent_pid} = Supervisor.get_agent(id)

      MockClient.start_link(agent_pid)
      Process.put(:nest_test_agent_pid, agent_pid)

      on_exit(fn ->
        MockClient.stop(agent_pid)
        Process.delete(:nest_test_agent_pid)
      end)

      MockClient.set_response("Hi there!")

      :sys.replace_state(agent_pid, fn state ->
        %{state | client_config: %{state.client_config | client: MockClient}}
      end)

      :ok = Agents.chat(id, "Hello, agent!")

      assert eventually(
               fn ->
                 {:ok, info} = Agents.get_info(id)
                 info.message_count == 3
               end,
               timeout: 1000
             )
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Agents.chat("nonexistent", "Hello")
    end
  end

  describe "retry_compaction/1" do
    test "sends :retry_compaction to the agent pid" do
      {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus"})
      {:ok, agent_pid} = Supervisor.get_agent(id)

      # The function returns :ok synchronously; the agent then
      # runs `handle_info(:retry_compaction, state)` and decides
      # whether to actually re-run the compactor based on its
      # current status. Since the agent is in :idle status (not
      # `:compaction_failed`), the handler logs a warning and is
      # a no-op. We capture the log and assert the warning.
      # We sync the GenServer mailbox via `:sys.get_state/2` to
      # make the test deterministic — the previous version relied
      # on async delivery which was racy.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Agents.retry_compaction(id)
          # Force the GenServer to process the message before
          # `capture_log` returns. `:sys.get_state/2` is
          # synchronous and runs after every queued message.
          :sys.get_state(agent_pid)
        end)

      assert log =~ "retry_compaction ignored"
      assert log =~ ":idle"
      assert log =~ ":compaction_failed"
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Agents.retry_compaction("nonexistent")
    end
  end

  describe "compaction_loop_detected_ok/1" do
    test "sends :compaction_loop_detected_ok to the agent pid" do
      {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus"})
      {:ok, agent_pid} = Supervisor.get_agent(id)

      # Agent is in :idle (not :compaction_loop_detected), so
      # the handler logs a warning and is a no-op. Capture log.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Agents.compaction_loop_detected_ok(id)
          :sys.get_state(agent_pid)
        end)

      assert log =~ "compaction_loop_detected_ok ignored"
      assert log =~ ":idle"
      assert log =~ ":compaction_loop_detected"
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Agents.compaction_loop_detected_ok("nonexistent")
    end
  end

  describe "delete_agent/1" do
    test "removes agent" do
      {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus"})
      :ok = Agents.delete_agent(id)

      assert eventually(fn ->
               Agents.get_info(id) == {:error, :not_found}
             end)
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Agents.delete_agent("nonexistent")
    end
  end

  describe "change_model/2" do
    test "repairs an agent that started in :model_missing state" do
      # The create flow lands in :model_missing when the model
      # can't resolve. change_model should transition to :idle
      # with the Anthropic client.
      #
      # The unresolvable model fires a `Logger.error` from
      # `Agent.init/1` — capture and assert it's the expected
      # error path, not noise.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, name} = Agents.create_agent(%{name: "ghost-model"})

          # Sanity: we're in :model_missing before the change.
          {:ok, info} = Agents.get_info(name)
          assert info.status == :model_missing

          :ok =
            Agents.change_model(name, %{
              name: "qwen3.5-plus",
              provider: "model-studio"
            })

          {:ok, info} = Agents.get_info(name)
          assert info.status == :idle
          assert info.model.name == "qwen3.5-plus"
        end)

      assert log =~ "could not resolve model"
    end

    test "returns :not_found for an unknown agent" do
      assert {:error, :not_found} =
               Agents.change_model("nope", %{
                 name: "qwen3.5-plus",
                 provider: "model-studio"
               })
    end

    test "proxies the agent's {:error, reason} reply verbatim" do
      # The change_model error contract is `{:error, term()}`
      # where `term()` can be `:agent_busy`,
      # `{:invalid_model, reason}`, or any other GenServer
      # reply tuple. Stub the setter to return a less-common
      # tuple (`:gen_server_timeout`) to confirm the wrapper
      # passes through without rewriting.
      {:ok, name} = Agents.create_agent(%{name: "qwen3.5-plus"})
      {:ok, pid} = Supervisor.get_agent(name)

      AgentGenServer
      |> stub(:set_model, fn _pid, _new_model -> {:error, :gen_server_timeout} end)

      assert {:error, :gen_server_timeout} =
               Agents.change_model(name, %{
                 name: "claude-3-opus-20240229",
                 provider: "anthropic-provider"
               })

      # State must not have been mutated.
      assert :sys.get_state(pid).model.name == "qwen3.5-plus"
    end
  end

  describe "list_broken_agents/0" do
    test "returns an empty list when persistence is disabled" do
      # Default test config has `persistence_enabled: false`,
      # so `fetch_all_agents/0` returns `[]` and so does
      # `list_broken_agents/0`. Persistence-enabled coverage
      # for the function lives in
      # `agent_change_model_test.exs`.
      assert Agents.list_broken_agents() == []
    end
  end
end
