defmodule Nest.Agents.AgentRegenerateOnCompactionTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.Handlers.CompactionHandler.regenerate_for_compaction/2` —
  the shared helper that rebuilds the agent's system prompt
  (position 0 of `state.chat_state.messages`) from the latest
  DB state on every compaction. Re-fetches the Vocation row,
  re-renders the system prompt, re-builds the tool set,
  re-resolves the context limit, and persists all new
  messages. See `notes/update-system-msg-on-compaction.md`.

  The `regenerate_for_compaction/2` helper now takes the raw
  compactor LLM response text directly (not a `[system,
  wrap_summary]` tuple). Stripping of `<think>` blocks happens
  inside the regenerator when building the post-compaction
  "Summary of earlier conversation:" user message.

  This file is `async: false` so the agent's regeneration
  can use the test's sandboxed connection via the
  `Ecto.Adapters.SQL.Sandbox` ownership chain. Async tests
  lose the connection walking at the agent's supervisor
  boundary, which causes `DBConnection.OwnershipError`s
  during the regeneration's DB lookup.
  """
  use Nest.DataCase, async: false

  import ExUnit.CaptureLog
  import Mimic

  import Nest.Agents.AgentTestHelpers, only: [start_agent: 1]

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Config, as: AgentConfig
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  # Create a Programmer vocation in the test DB and return its
  # id. The system-prompt regeneration tests need a vocation
  # with `shell_cmd` registered (so the tools actually run)
  # and a non-trivial system_prompt (so we can assert that
  # position 0 reflects the latest value).
  defp programmer_vocation_id do
    {:ok, vocation} =
      Vocations.create_vocation(%{
        name: "Test Programmer (#{Elixir.System.unique_integer([:positive])})",
        description: "A coding assistant that can read and write files in a workspace",
        system_prompt: "Test programmer prompt.",
        tools: ["read_file", "write_file", "edit", "shell_cmd", "context"],
        modes: %{
          "build" => %{
            "description" => "Test mode",
            "caps" => %{
              "net" => true,
              "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
            }
          }
        }
      })

    vocation.id
  end

  defp unique_tmp_dir do
    dir =
      Path.join(
        Elixir.System.tmp_dir!(),
        "agents-md-#{Elixir.System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  # Append an `assistant+ToolUse[context.compact]` to the
  # agent's `state.chat_state.messages` so the messages list
  # ends with the trailing tool call (matching production
  # where the chat turn has already emitted the tool call
  # before the compaction fires). Returns the tool_call_id
  # so the carried pair can reference the same call.
  defp seed_compact_tool_call(pid) do
    tool_call_id = "compact_call_#{Elixir.System.unique_integer([:positive])}"

    :sys.replace_state(pid, fn state ->
      %{
        state
        | chat_state: %{
            state.chat_state
            | messages:
                (state.chat_state.messages || []) ++
                  [
                    {:assistant,
                     %Assistant{
                       index: nil,
                       parts: [
                         %Part.ToolUse{
                           id: tool_call_id,
                           name: "context",
                           arguments: %{"action" => "compact"}
                         }
                       ],
                       api_logs: []
                     }}
                  ]
          }
      }
    end)

    tool_call_id
  end

  # Build the carried `[tool_call, tool_result]` pair for the
  # `:compact_tool` continuation. `iter` defaults to 0 and
  # `max` defaults to the configured tool-iteration cap,
  # matching the post-refactor `normalize_continuation/2`
  # literal. The handler doesn't inspect
  # `state.chat_state.messages` for the trailing tool call —
  # the pair is carried in the continuation itself.
  defp compact_tool_continuation(
         tool_call_id,
         iter \\ 0,
         max \\ AgentConfig.configured_max_tool_iterations()
       ) do
    arguments = %{"action" => "compact"}

    tool_call_msg =
      {:assistant,
       %Assistant{
         index: nil,
         parts: [%Part.ToolUse{id: tool_call_id, name: "context", arguments: arguments}],
         api_logs: []
       }}

    tool_result_msg =
      {:tool,
       %Tool{
         index: nil,
         timestamp: DateTime.utc_now(),
         parts: [
           %Part.ToolResult{
             tool_call_id: tool_call_id,
             name: "context",
             arguments: arguments,
             content: "Compacted from N token previous context.",
             is_error: false
           }
         ],
         api_logs: []
       }}

    {:compact_tool, [tool_call_msg, tool_result_msg], iter, max}
  end

  defp extract_position0_text(state) do
    [{:system, %System{parts: [%Part.Text{text: text}]}} | _] = state.chat_state.messages
    text
  end

  describe "system prompt regeneration" do
    test "position 0 reflects the latest vocation.system_prompt after compaction" do
      vocation_id = programmer_vocation_id()

      {pid, _agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})

      Vocations.update_vocation(
        Vocations.get_vocation!(vocation_id),
        %{system_prompt: "UPDATED via Vocations.update_vocation/2"}
      )

      tool_call_id = seed_compact_tool_call(pid)

      send(
        pid,
        {:compaction_done, "the LLM summary text", compact_tool_continuation(tool_call_id)}
      )

      # `:sys.get_state/2` queues behind the compaction handler
      # and returns only after the handler has run.
      _ = :sys.get_state(pid, 500)

      text0 = extract_position0_text(:sys.get_state(pid))
      assert text0 =~ "UPDATED via Vocations.update_vocation/2"

      Agent.terminate(pid)
    end

    test "position 0 reflects a mutated AGENTS.md on disk after compaction" do
      workspace = unique_tmp_dir()
      File.write!(Path.join(workspace, "AGENTS.md"), "FIRST version")
      on_exit(fn -> File.rm_rf!(workspace) end)

      vocation_id = programmer_vocation_id()

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation_id,
          workspace_path: workspace
        })

      # Mutate AGENTS.md on disk.
      File.write!(Path.join(workspace, "AGENTS.md"), "SECOND version")

      tool_call_id = seed_compact_tool_call(pid)

      send(
        pid,
        {:compaction_done, "the LLM summary text", compact_tool_continuation(tool_call_id)}
      )

      # `:sys.get_state/2` queues behind the compaction handler
      # and returns only after the handler has run.
      _ = :sys.get_state(pid, 500)

      text0 = extract_position0_text(:sys.get_state(pid))
      assert text0 =~ "SECOND version"
      refute text0 =~ "FIRST version"

      Agent.terminate(pid)
    end

    test "state.vocation is updated to the fresh struct after compaction" do
      vocation_id = programmer_vocation_id()

      {pid, _agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})

      Vocations.update_vocation(
        Vocations.get_vocation!(vocation_id),
        %{description: "UPDATED description for the fresh fetch"}
      )

      tool_call_id = seed_compact_tool_call(pid)

      send(
        pid,
        {:compaction_done, "the LLM summary text", compact_tool_continuation(tool_call_id)}
      )

      # `:sys.get_state/2` queues behind the compaction handler
      # and returns only after the handler has run.
      _ = :sys.get_state(pid, 500)

      state = :sys.get_state(pid)
      assert state.vocation.description == "UPDATED description for the fresh fetch"

      Agent.terminate(pid)
    end

    test "encoded summary-as-user carries the compactor LLM's response text with the prefix" do
      vocation_id = programmer_vocation_id()

      {pid, _agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})

      tool_call_id = seed_compact_tool_call(pid)

      send(
        pid,
        {:compaction_done, "key facts", compact_tool_continuation(tool_call_id)}
      )

      # `:sys.get_state/2` queues behind the compaction handler
      # and returns only after the handler has run.
      _ = :sys.get_state(pid, 500)

      state = :sys.get_state(pid)
      # 2-message regenerator output (fresh_system + summary_user)
      # + the carried pair [tool_call, tool_result] appended via
      # `append_continuation_tail/2` = 4 total in-memory messages
      # after the swap.
      assert length(state.chat_state.messages) == 4

      [_, {:user, %User{parts: [%Part.Text{text: text1}]}}, _, _] = state.chat_state.messages
      assert text1 =~ "Summary of earlier conversation"
      assert text1 =~ "key facts"

      Agent.terminate(pid)
    end

    test "summary_user has <think> blocks stripped from the LLM response text" do
      vocation_id = programmer_vocation_id()

      {pid, _agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})

      tool_call_id = seed_compact_tool_call(pid)

      send(
        pid,
        {:compaction_done, "<think>hidden reasoning</think>visible summary",
         compact_tool_continuation(tool_call_id)}
      )

      _ = :sys.get_state(pid, 500)

      state = :sys.get_state(pid)

      [_, {:user, %User{parts: [%Part.Text{text: text1}]}}, _, _] = state.chat_state.messages
      # Visible text present, thinking markers + content gone.
      assert text1 =~ "visible summary"
      refute text1 =~ "hidden reasoning"
      refute text1 =~ "<think>"
      refute text1 =~ "</think>"

      Agent.terminate(pid)
    end

    test "Vocations.get_vocation returns nil: graceful fallback (cached state, warning logged)" do
      # The DB-missing case is "expected to come back quickly"
      # (per the design in notes/update-system-msg-on-compaction.md).
      # We simulate it by deleting the vocation row mid-test;
      # the agent's regenerate_for_compaction/2 calls
      # Vocations.get_vocation/1 which returns nil, and the
      # handler falls back to the cached state.
      vocation_id = programmer_vocation_id()

      {pid, _agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})

      # Delete the vocation row to simulate a transient DB blip.
      # Bypass the agents_using_vocation? check by deleting
      # directly via Repo.
      vocation = Vocations.get_vocation!(vocation_id)
      Nest.Repo.delete!(vocation)

      tool_call_id = seed_compact_tool_call(pid)

      log =
        capture_log(fn ->
          send(
            pid,
            {:compaction_done, "the LLM summary text", compact_tool_continuation(tool_call_id)}
          )

          # `:sys.get_state/2` queues behind the compaction
          # handler and returns only after the handler has run.
          _ = :sys.get_state(pid, 500)
        end)

      # The fallback path is observable: a warning is logged
      # and the cached vocation stays in state.
      assert log =~ "Vocation #{vocation_id} not found during compaction regeneration"
      assert log =~ "using cached state"

      state = :sys.get_state(pid)
      # The fallback returns the existing messages unchanged
      # (no swap, no fresh system). The post-swap list reflects
      # the carried pair [tool_call, tool_result] appended via
      # `append_continuation_tail/2`. The fresh ChatTurn spawned
      # by the `:compact_tool` continuation also iterates and
      # (in the typical case) appends a final assistant message
      # from the (random) MockClient response — but its iter is
      # async, so that message may or may not be in
      # `state.chat_state.messages` by the time this assertion
      # runs. Assert the messages we care about rather than
      # the exact total. The head should be the pre-seeded
      # system message; the carried tool_call/tool_result
      # pair sits at the tail.
      assert length(state.chat_state.messages) >= 4
      assert {:system, %System{}} = hd(state.chat_state.messages)
      assert {:tool, %Tool{}} = List.last(state.chat_state.messages)
      assert state.vocation.id == vocation_id

      Agent.terminate(pid)
    end
  end
end
