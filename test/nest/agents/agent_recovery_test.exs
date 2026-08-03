defmodule Nest.Agents.Agent.RecoveryTest do
  @moduledoc """
  Tests for the `:model_missing` recovery flow.

  When an agent's persisted `model` no longer resolves to a
  runtime provider (e.g. a `[providers.<name>]` entry was
  removed from `~/.config/nest/config.toml`), the Agent's
  `init/1` previously returned `{:stop, reason}`. The runtime
  then had no GenServer, no Registry entry, and `list_agents_info/0`
  silently filtered the row out — so the user perceived the
  agent as having vanished.

  The recovery flow keeps the GenServer alive with a
  `RecoveryClient` placeholder and a `:model_missing` chat
  status. The channel layer rejects inbound `chat:message`
  traffic while the agent is in this state, and the lobby
  surfaces the row via `Agents.list_broken_agents/0`. The user
  can call `Agents.change_model/2` to repair.
  """

  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.RecoveryClient

  setup :verify_on_exit!

  # The pre-test cleanup uses `Nest.Persistence.list_agent_names/0`
  # (DB query) rather than `Agents.list_agents/0`
  # (`Registry.list/0`). The Registry only contains live
  # GenServers; per-test on_exit handlers terminate the
  # GenServer but leave the DB row behind, so the Registry
  # misses those rows. Querying the DB catches both running
  # and dead-but-row-still-present agents.
  #
  # `Nest.Persistence.delete_agent_by_name/1` is a single SQL
  # DELETE — no `Supervisor.stop_agent/1` call, so this loop
  # doesn't serialize through the supervisor's GenServer under
  # parallel load. The previous `Agents.delete_agent/1` loop
  # timed out at 5s when many parallel tests' setups queued
  # supervisor stops on a single mailbox.
  setup do
    for name <- Nest.Persistence.list_agent_names() do
      Nest.Persistence.delete_agent_by_name(name)
    end

    :ok
  end

  describe "Agent.init/1 with an unresolvable model" do
    test "starts the agent with status :model_missing instead of stopping" do
      # Mock the dotconfig so "ghost-model" cannot be resolved.
      # The Agent's `Config.create_client_config/1` calls
      # `ChatModel.new(model: name)`, which routes through
      # `DotConfig.get_model/2`. An explicit nil return there
      # produces a `ModelNotFoundError`.
      #
      # The model-probe failure fires a `Logger.error` from
      # `Agent.init/1` — capture it and assert it's the
      # expected error path, not noise.
      #
      # `name:` is suffixed with `System.unique_integer/1` so
      # the agent's registry key doesn't collide with another
      # test (or a prior run whose auto-cleanup hasn't yet
      # finished) under `async: true` parallel execution.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Nest.DotConfig
          |> stub(:get_model, fn _config, "ghost-model" -> nil end)

          {:ok, pid} =
            start_supervised(
              {Agent,
               %{
                 name: "ghost-agent-#{System.unique_integer([:positive])}",
                 model: %{name: "ghost-model"},
                 vocation_id: vocation_id()
               }}
            )

          assert Process.alive?(pid)

          state = :sys.get_state(pid)
          assert state.chat_state.status == :model_missing
          assert state.client_config.client == RecoveryClient
          assert state.model == %{name: "ghost-model"}
        end)

      assert log =~ "could not resolve model"
    end

    test "subsequent chat:message is dropped in :model_missing state" do
      # Same model-probe failure as above — capture the
      # `Logger.error` and assert it's the expected error path.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Nest.DotConfig
          |> stub(:get_model, fn _config, "ghost-model" -> nil end)

          {:ok, pid} =
            start_supervised(
              {Agent,
               %{
                 name: "ghost-agent-#{System.unique_integer([:positive])}",
                 model: %{name: "ghost-model"},
                 vocation_id: vocation_id()
               }}
            )

          # Sanity: the agent is alive. The chat:message drop happens
          # in `chat_or_drop/3` so the message counter never
          # advances. We assert that the GenServer returns
          # {:noreply, state} and the in-memory `messages` list
          # stays at the initial `[{:system, _}]`.
          _ref = Agent.chat(pid, "hello?")
          # Yield to the GenServer so the cast has been handled.
          _ = :sys.get_state(pid)
          state = :sys.get_state(pid)
          assert Enum.all?(state.chat_state.messages, &match?({:system, _}, &1))
        end)

      assert log =~ "could not resolve model"
    end
  end

  defp vocation_id do
    {:ok, v} =
      Nest.Vocations.upsert_vocation(%{
        name: "Recovery Test Vocation",
        description: "v",
        system_prompt: "x",
        tools: ["context"],
        modes: %{}
      })

    v.id
  end
end
