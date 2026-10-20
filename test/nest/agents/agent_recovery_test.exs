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
  alias Nest.Agents.Agent.Machine

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.RecoveryClient

  setup :verify_on_exit!

  # A fresh space per test (`create_test_space/0` inserts a space and
  # nothing else), so there are no agent rows to clear.
  setup do
    {:ok, _space_id} = AgentTestHelpers.create_test_space()
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
                 space_id: AgentTestHelpers.current_space_id(),
                 name: "ghost-agent-#{System.unique_integer([:positive])}",
                 model: %{name: "ghost-model"},
                 vocation_id: vocation_id(),
                 sandbox_backend: "bwrap",
                 network_access: true
               }}
            )

          # allowlist: snapshot — client config + status + model
          state = :sys.get_state(pid, 1_000)
          assert Machine.status_for(state.live.machine) == :model_missing
          assert state.client_config.client == RecoveryClient
          assert state.model == %{name: "ghost-model"}
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
        tools: ["context"]
      })

    v.id
  end
end
