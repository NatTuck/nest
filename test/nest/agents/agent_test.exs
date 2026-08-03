defmodule Nest.Agents.AgentTest do
  @moduledoc """
  Agent lifecycle tests: `start_link/1`.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Registry
  alias Nest.Messages.Assistant
  alias Nest.Messages.{Tool, User}
  # `System` left unaliased to avoid shadowing Elixir.System.

  describe "start_link/1" do
    test "starts agent and registers in registry" do
      agent_name = "registered-agent-#{System.unique_integer([:positive])}"
      model = %{name: "qwen3.5-plus", provider: "model-studio"}

      {:ok, name} =
        Agents.create_agent(model,
          name: agent_name,
          vocation_id: AgentTestHelpers.vocation_id_for_test()
        )

      assert ^name = agent_name
      assert {:ok, _pid} = Registry.lookup(name)
    end
  end

  describe "consecutive_compaction_count reset on append_message" do
    test "appending :user, :assistant, or :tool messages resets to 0" do
      agent_name = "loop-counter-agent-#{System.unique_integer([:positive])}"
      model = %{name: "qwen3.5-plus", provider: "model-studio"}

      {:ok, name} =
        Agents.create_agent(model,
          name: agent_name,
          vocation_id: AgentTestHelpers.vocation_id_for_test()
        )

      {:ok, pid} = Registry.lookup(name)

      # The supervisor-spawned agent pid doesn't inherit the
      # test pid's sandbox via `$callers` (that walked through
      # `start_supervised!` in the old design). DB writes
      # from `append_message/1` therefore need an explicit
      # allow.
      Sandbox.allow(Nest.Repo, self(), pid)

      # Bump the counter out-of-band via the GenServer API.
      :ok = GenServer.call(pid, {:set_consecutive_compaction_count, 5})

      user_msg = {:user, %User{parts: [], index: nil}}
      assistant_msg = {:assistant, %Assistant{parts: [], index: nil}}
      tool_msg = {:tool, %Tool{parts: [], index: nil}}
      system_msg = {:system, %Nest.Messages.System{parts: [], index: nil}}
      # Plain map (not a `%Compaction{}` struct) so
      # `Persistence.insert_message/2` logs a warning
      # rather than inserting a row. The counter logic
      # under test doesn't care which branch fires.
      compaction_msg = {:compaction, %{parts: [], index: nil}}

      capture_log(fn ->
        for msg <- [user_msg, assistant_msg, tool_msg] do
          GenServer.call(pid, {:set_consecutive_compaction_count, 5})
          _ = GenServer.call(pid, {:append_message, msg})
          after_count = GenServer.call(pid, :get_consecutive_compaction_count)
          assert after_count == 0, "expected reset after appending #{inspect(elem(msg, 0))}"
        end

        # `:system` and `:compaction` appends do NOT reset.
        for msg <- [system_msg, compaction_msg] do
          GenServer.call(pid, {:set_consecutive_compaction_count, 5})
          _ = GenServer.call(pid, {:append_message, msg})
          after_count = GenServer.call(pid, :get_consecutive_compaction_count)
          assert after_count == 5, "expected NO reset after appending #{inspect(elem(msg, 0))}"
        end
      end)
    end
  end
end
