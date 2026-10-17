defmodule Nest.Agents.AgentCompactionTest do
  @moduledoc """
  Agent compaction and pre-flight tests: tool budget loop,
  compaction history, pre-flight streaming guard,
  `chat:compaction` broadcast, and system prompt regeneration
  on compaction (the on-demand-load fix — see
  `notes/update-system-msg-on-compaction.md`).
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine
  alias Nest.LLM.MockClient
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Persistence

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  # Build a `{:assistant, %Assistant{}}` with a single
  # `%Part.ToolUse{name: "context-compact"}` at index `idx`. Tests use
  # this when they need a carried tool_use without pre-seeding
  # `state.chat_state.messages` via `:sys.replace_state`.
  defp compact_tool_call_msg(idx) do
    {:assistant,
     %Assistant{
       index: idx,
       parts: [
         %Part.ToolUse{
           id: "c1",
           name: "context-compact",
           arguments: %{}
         }
       ],
       api_logs: []
     }}
  end

  # Create a Programmer vocation in the test DB and return its id.
  # `programmer_vocation_id_for_test/0` lives in `AgentTestHelpers`
  # (promoted from a local `defp` for cross-file reuse). Tests
  # that exercise the tool-call flow pass it as `vocation_id:`
  # to `start_agent/1` so `shell_cmd` (and the file tools) are
  # actually registered; otherwise BatchSizer returns
  # "Unknown tool: shell_cmd" for every call.
  import Nest.Agents.AgentTestHelpers

  describe "tool budget loop" do
    test "small tool results pass through unchanged" do
      MockClient.set_tool_response(%{
        text: "Reading file",
        tool_calls: [
          %{id: "call_1", name: "shell-cmd", arguments: %{"command" => "echo small"}}
        ]
      })

      MockClient.set_response("Done")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "Read a file")

      # The batch's own broadcast is the barrier for the real work: the agent
      # appends the tool results only after the `shell-cmd` run (a real bwrap
      # process) has returned, so this is the fence that covers it and the
      # end-of-turn wait below covers a mocked round trip only.
      assert_receive {:chat_message, {:tool, %Tool{parts: [result_part | _]}}}, 1_000

      # The end of the turn is the arrival of the `chat:status` "idle" frame,
      # with the machine (`status_for/1`) read behind it as the authority.
      await_idle(pid)

      assert_received {:chat_message, {:user, _}}
      assert_received {:chat_status, %{status: "streaming"}}
      assert_received {:chat_delta, %{content: "Reading file"}}
      assert_received {:chat_delta, %{content: "Done"}}
      assert_received {:chat_message, {:assistant, _}}
      # Zero fence for the block above: every one of those frames was
      # broadcast before the "idle" frame `await_idle/1` fences on, which is
      # where the assertion on that frame now lives.

      %Part.ToolResult{content: content} = result_part

      assert_shell_ok(result_part)

      refute String.contains?(content, "[truncated:")
      refute String.contains?(content, "[skipped:")
      assert content =~ "small"

      # The tool actually ran (we have a Programmer vocation with
      # shell_cmd registered), so the result should be the
      # command's output, not "Unknown tool: ...".
      assert content =~ "small"

      Agent.terminate(pid)
    end

    test "order is preserved when multiple tool calls are returned" do
      MockClient.set_stream_events([
        {:text, "Running two commands"},
        {:tool_call_start, %{id: "call_1", name: "shell-cmd"}},
        {:tool_call_delta, %{id: "call_1", arguments_delta: "{}"}},
        {:tool_call_start, %{id: "call_2", name: "shell-cmd"}},
        {:tool_call_delta, %{id: "call_2", arguments_delta: "{}"}},
        {:usage, %{input_tokens: 100, output_tokens: 50, total_tokens: 150}},
        {:finish_reason, "tool_calls"},
        {:done,
         %{
           response: %RunResponse{
             text: "Running two commands",
             tool_calls: [
               %Nest.Messages.ToolCall{
                 id: "call_1",
                 name: "shell-cmd",
                 arguments: %{"command" => "echo first"}
               },
               %Nest.Messages.ToolCall{
                 id: "call_2",
                 name: "shell-cmd",
                 arguments: %{"command" => "echo second"}
               }
             ],
             stop_reason: "tool_calls"
           }
         }}
      ])

      MockClient.set_response("All done")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      log =
        capture_log(fn ->
          # `Agent.chat/4` is a cast, so the "Missing required arguments"
          # diagnostic (asserted below) can otherwise be emitted by the HTTP
          # worker before `capture_log` installs its handler and be missed
          # entirely — under load it lost the race. The chat belongs inside the
          # capture.
          :ok = Agent.chat(pid, "Run two")

          # The batch's own broadcast is the barrier for the real work: the
          # agent appends the tool results only after both `shell-cmd` runs
          # (real bwrap processes) have returned, so this is the one fence that
          # covers them and the end-of-turn wait below covers a mocked round
          # trip only.
          assert_receive {:chat_message, {:tool, %Tool{parts: parts}}}, 1_000

          # The end of the turn is the arrival of the `chat:status` "idle"
          # frame, with the machine (`status_for/1`) read behind it as the
          # authority.
          await_idle(pid)

          assert_received {:chat_message, {:user, _}}
          assert_received {:chat_status, %{status: "streaming"}}
          assert_received {:chat_delta, %{content: "Running two commands"}}
          assert_received {:chat_delta, %{content: "All done"}}
          assert_received {:chat_message, {:assistant, _}}
          # Zero fence for the block above: every one of those frames was
          # broadcast before the "idle" frame `await_idle/1` fences on, which
          # is where the assertion on that frame now lives.

          assert length(parts) == 2
          assert Enum.map(parts, & &1.tool_call_id) == ["call_1", "call_2"]

          Agent.terminate(pid)
        end)

      # The MockClient stream events include `arguments_delta: "{}"`
      # which the turn validates against the schema's `required`
      # fields before the final `{:done, ...}` arrives. The
      # "Missing required arguments" log is a deliberate diagnostic
      # for that incremental-validation path.
      assert log =~ "Missing required arguments"
    end
  end

  describe "compaction history" do
    test "compaction_done archives previous messages to history with a marker" do
      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      old_messages = [
        {:user, %User{index: 0, parts: [%Part.Text{text: "First"}], api_logs: []}},
        {:assistant, %Assistant{index: 1, parts: [%Part.Text{text: "A1"}], api_logs: []}},
        {:user, %User{index: 2, parts: [%Part.Text{text: "Second"}], api_logs: []}},
        {:assistant, %Assistant{index: 3, parts: [%Part.Text{text: "A2"}], api_logs: []}},
        # The compaction request the machine appended *before* dispatching the
        # compactor. It is committed history — not a request-only addition —
        # so the commit archives it along with the segment it summarises.
        {:user,
         %User{index: 4, parts: [%Part.Text{text: "[mode: compact] summarize"}], api_logs: []}}
      ]

      # The compactor LLM's response text. The commit wraps it as
      # "Summary of previous conversation (compacted from N tokens):\n\n…".
      summary_text = "..."

      # `:tool_call` continuation: the resumed post-compaction turn
      # executes the carried tool call, then calls the LLM. Finish it so
      # the agent is idle when the test ends (the teardown asserts zero
      # in-flight agents) instead of killing it mid-turn.
      tool_call_msg = compact_tool_call_msg(3)

      # Replace the active list and point the counter past the in-memory
      # indices so the commit's appends don't collide with the persisted
      # system row.
      :sys.replace_state(
        pid,
        fn s ->
          %{s | chat_state: %{s.chat_state | messages: old_messages, next_message_index: 5}}
        end,
        1_000
      )

      carried_entry = {:tool_call, tool_call_msg, 3, 30}
      ref = make_ref()

      :sys.replace_state(
        pid,
        fn s ->
          machine = s.live.machine

          machine = %{
            machine
            | kind: :compaction,
              phase: :generating,
              entry: {:compaction, carried_entry},
              work: %{
                machine.work
                | worker_kind: :http,
                  worker_ref: ref,
                  active_message_index: s.chat_state.next_message_index
              }
          }

          %{s | live: %{s.live | machine: machine}}
        end,
        1_000
      )

      send(
        pid,
        {:http_response, ref, %Nest.LLM.RunResponse{text: summary_text, usage: nil}}
      )

      # The commit broadcasts `chat:compaction` inline from the agent while it
      # handles the response (after the marker and the regenerated messages are
      # in the state), so the frame is the happens-after event for the commit.
      # The marker payload binds the fence to a commit rather than to ambient
      # traffic.
      assert_receive {:chat_compaction, payload}, 1_000
      assert payload.marker["role"] == "compaction"
      assert payload.marker["archivedCount"] == 6
      # The archive is no longer pushed with the marker; the client
      # fetches it lazily over `chat:history`.
      refute Map.has_key?(payload, :history)

      assert_receive {:chat_status, %{status: "idle"}}, 1_000
    end
  end

  describe "final-reply reserve deferral" do
    test "an over-reserve final reply is compacted and committed active-side exactly once" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      info = Agent.get_public_info(pid, 1_000)
      space_id = info.space_id
      name = info.name

      # A small effective window: the reply's reported usage (85k) plus the
      # reserve (20k) exceeds 100k, while the pre-reply context fits.
      :sys.replace_state(
        pid,
        fn state ->
          %{
            state
            | llm_metrics: %{
                state.llm_metrics
                | context_limit: 100_000,
                  context_limit_source: :config
              }
          }
        end,
        1_000
      )

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{space_id}:#{name}")

      # The reply reports a usage that would spend the reserve, so the
      # machine must defer it across a compaction instead of persisting it
      # into the live list.
      MockClient.set_stream_events([
        {:text, "FINAL"},
        {:usage, %{input_tokens: 85_000, output_tokens: 10}}
      ])

      :ok = Agent.chat(pid, "answer this")

      assert_receive {:chat_compaction, %{marker: _}}, 1_000
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      # allowlist: snapshot — messages + status
      state = :sys.get_state(pid, 1_000)
      messages = state.chat_state.messages

      # The deferred reply landed exactly once on the active side.
      replies =
        Enum.filter(messages, fn
          {:assistant, %{parts: [%Part.Text{text: "FINAL"}]}} -> true
          _ -> false
        end)

      assert length(replies) == 1,
             "expected exactly one committed final reply; got #{inspect(messages)}"

      # The compaction produced the active summary_user.
      assert Enum.any?(messages, fn
               {:user, %{parts: [%Part.Text{text: t}]}} when is_binary(t) ->
                 String.starts_with?(t, "Summary of previous conversation (")

               _ ->
                 false
             end)

      assert Machine.status_for(state.live.machine) == :idle
    end
  end

  describe "per-iteration preflight has been removed" do
    test "CompactionHandler does not accept {:preflight_request, _, _} (the per-iteration trigger is gone)" do
      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      # Per-iteration preflight compaction was removed in favor of the
      # BatchSizer preflight (`Machine.Response`) and staged compaction
      # (`Machine.Compaction.stage/2`). The Agent
      # must NOT have a handler for `{:preflight_request, _, _}` —
      # any such message lands in the Agent's mailbox unhandled
      # and is silently discarded.
      # allowlist: harness — a fabricated preflight payload needs the whole state
      state_before = :sys.get_state(pid, 1_000)
      fake_task = self()

      send(pid, {:preflight_request, fake_task, state_before.chat_state.messages || []})

      # There should be NO `:preflight_result` reply. `:sys.get_state/2` is a
      # synchronous call, and the Agent processes its mailbox in order, so by
      # the time it returns the `send/2` above has been handled — a handler,
      # if one existed, would already have replied. That makes this a
      # deterministic check instead of a 200 ms timing window.
      refute_no_preflight_reply(pid)

      Agent.terminate(pid)
    end

    test "CompactionHandler does not accept {:compaction_failed_for_preflight, _, _}" do
      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      fake_task = self()

      send(pid, {:compaction_failed_for_preflight, fake_task, :llm_returned_empty})

      refute_no_preflight_reply(pid)

      Agent.terminate(pid)
    end

    test "streaming_acc is no longer consulted by any preflight path" do
      # The legacy design had a `streaming_active?` shortcut that
      # returned `:proceed` while the LLM was still streaming the
      # response. That shortcut is forbidden under our constraint
      # ("never send an LLM request whose message list predictably
      # overflows"). Streaming_acc still exists — the BatchSizer
      # waits for the assistant message to be finalized before
      # running — but no preflight handler reads it.
      #
      # Structural assertion: the pure preflight/request-staging path has
      # no branch that consults `streaming_acc` to short-circuit fit.
      dispatch = File.read!("lib/nest/agents/agent/turn/dispatch.ex")

      refute dispatch =~ "streaming_acc",
             "the preflight/request-staging path must not consult streaming_acc " <>
               "(forbidden under the never-overflow constraint)"
    end
  end

  describe "context-compact tool flow" do
    test "context-compact triggers compaction and returns to idle" do
      # First LLM call emits the context-compact tool call.
      MockClient.set_tool_response(%{
        text: "compacting",
        tool_calls: [
          %{
            id: "call_1",
            name: "context-compact",
            arguments: %{"cover" => "recent", "preserve" => "PRESERVED-TEXT"}
          }
        ]
      })

      # Second LLM call (after compaction) consumes this.
      MockClient.set_response("Done")

      # The compactor's LLM call doesn't thread `agent_pid` through
      # so it falls back to a random text summary. We assert on
      # the final post-compaction shape, not on the compactor's text.

      # Use a real Programmer vocation so the compaction
      # re-renders the system prompt (proving the
      # `compose_vocation_config/6` path runs). Tests
      # without a real vocation also pass — the
      # re-rendered system is just absent — but this
      # exercises the full code path.
      voc_id = programmer_vocation_id_for_test()

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: voc_id,
          vocation: Persistence.load_vocation(voc_id)
        })

      :ok = Agent.chat(pid, "compact please")

      # Single deterministic fence: `:chat_status "idle"` fires once
      # at the end. Read intermediate broadcasts races the BEAM
      # scheduler.
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      # allowlist: snapshot — messages + space_id + name
      state = :sys.get_state(pid, 1_000)
      messages = state.chat_state.messages
      history = Nest.Persistence.load_history(state.space_id, state.name)

      # Post-compaction shape (compactor is a chat turn, compactor
      # re-renders the system message per AGENTS.md exception).
      #
      # History:  [old_system, old_user, old_assistant, compact_assistant,
      #             compact_tool_result, bridge_ack, [mode: compact] request,
      #             compactor_assistant, marker]
      # Messages: [new_system_fresh, summary_user, post_chat_assistant]
      #
      # The compact call and its synthetic result are persisted *before* the
      # request, so the archive reads in causal order and the pair is never
      # replayed into the new segment. Index positions vary; assert by content.

      # The fresh system message is the head of the active list (re-rendered
      # from the latest DB vocation + AGENTS.md at compaction time).
      assert match?({:system, _}, Enum.at(messages, 0)),
             "expected fresh system message at messages[0]; got #{inspect(Enum.at(messages, 0))}"

      # The summary row follows it: the compactor's prose, wrapped with what
      # this compaction replaced and the agent's own `preserve` text verbatim
      # (the machinery writes that part, so it survives whatever the compactor
      # returned).
      summary_row =
        Enum.find_value(messages, fn
          {:user, %{parts: [%Part.Text{text: t}]}} when is_binary(t) ->
            if String.starts_with?(t, "Summary of previous conversation ("), do: t

          _ ->
            nil
        end)

      assert summary_row, "expected a summary_user in the active chat"
      assert summary_row =~ "PRESERVED-TEXT"

      # ...and the pointer at the archive, whose range `HistoryTest` proves
      # `agents-history` reads (the numbers in it are the marker's own).
      assert summary_row =~ "`agents-history` (start_index 0, length "

      # The call that triggered the compaction is archived with the turn it
      # belonged to: the call, its synthetic result, the bridge ack, the
      # request — in that order.
      archive =
        Enum.map(history, fn
          {:user, %{parts: [%Part.Text{text: t}]}} when is_binary(t) -> {:user, t}
          {:assistant, %Assistant{parts: parts}} -> {:assistant, parts}
          {:tool, %Tool{parts: parts}} -> {:tool, parts}
          {role, _} -> {role, nil}
        end)

      call_at =
        Enum.find_index(archive, fn
          {:assistant, parts} ->
            Enum.any?(parts, &match?(%Part.ToolUse{name: "context-compact"}, &1))

          _ ->
            false
        end)

      assert call_at, "expected the context-compact call in the archive"

      assert {:tool, [%Part.ToolResult{content: "Compacting now.", is_error: false}]} =
               Enum.at(archive, call_at + 1)

      assert {:assistant, [%Part.Text{text: ack}]} = Enum.at(archive, call_at + 2)
      assert ack =~ "Let me pause to summarize"

      assert {:user, request} = Enum.at(archive, call_at + 3)
      assert request =~ "[mode: compact]"

      # And none of it leaks into the new segment.
      refute Enum.any?(messages, fn
               {:assistant, %{parts: parts}} ->
                 Enum.any?(parts, &match?(%Part.ToolUse{name: "context-compact"}, &1))

               _ ->
                 false
             end),
             "the compact call belongs to the archived segment"

      # The fresh system message's text contains the
      # rendered system prompt (vocation `system_prompt`
      # plus tool budget / context limit / delegation sections).
      [{:system, sys_struct} | _] = messages

      sys_text =
        sys_struct.parts
        |> Enum.map_join("", fn
          %Part.Text{text: text} -> text
          _ -> ""
        end)

      assert sys_text =~ "Test programmer prompt.",
             "expected fresh system message to contain the rendered system prompt"

      # The resumed turn generated over the new segment — the summary plus the
      # compaction's own state — so the active list ends on its assistant
      # response. The compact call and its result are in the archive, not here.
      assert Enum.any?(messages, &match?({:assistant, _}, &1)),
             "expected a final assistant message in the active chat"

      # Compaction marker in history.
      assert Enum.any?(history, fn
               {:compaction, %{archived_count: n}} when n > 0 -> true
               _ -> false
             end),
             "expected chat:compaction marker in history with archived_count > 0"

      # The original system message is now in history
      # (the swap archives the pre-compaction active list, which
      # included the original system message at index 0).
      assert Enum.any?(history, &match?({:system, _}, &1)),
             "expected the original system message in history"

      # The suffix + compactor's assistant response are in
      # history (they were the pre-compaction active messages).
      assert Enum.any?(history, fn
               {:system, %{parts: [%Part.Text{text: t}]}} when is_binary(t) ->
                 String.starts_with?(t, "[mode: compact]")

               {:user, %{parts: [%Part.Text{text: t}]}} when is_binary(t) ->
                 String.starts_with?(t, "[mode: compact]")

               _ ->
                 false
             end),
             "expected the [mode: compact] suffix in history"

      # Trigger user message archived during the swap.
      assert Enum.any?(history, &match?({:user, _}, &1)),
             "expected the trigger user message archived into history"

      # Exactly once: the staged `[mode: compact]` suffix is committed once
      # (it is not persisted before the compaction and never re-appended).
      suffix_count =
        Enum.count(history, fn
          {_, %{parts: [%Part.Text{text: t}]}} when is_binary(t) ->
            String.starts_with?(t, "[mode: compact]")

          _ ->
            false
        end)

      assert suffix_count == 1, "expected exactly one [mode: compact] suffix; got #{suffix_count}"

      Agent.terminate(pid)
    end
  end

  describe "the compaction request is a committed message (#98)" do
    test "/compact commits the request before the compactor runs, and a failure leaves it visible" do
      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      # An empty summary is rejected by the commit path
      # (`TokensCompactor.validate_summary/1` → `:llm_returned_empty`), so this
      # drives the *failure* branch: the request went out, and the compaction
      # did not succeed. That is the branch where the old design sent a
      # sequence and persisted nothing.
      MockClient.set_response("")

      log =
        capture_log(fn ->
          _ = Agent.compact(pid, "keep the API decisions")

          # The failure frame is the happens-after event for the failed
          # compaction (the status broadcast follows it).
          assert_receive {:chat_error, %{compactionError: true}}, 1_000
        end)

      assert log =~ "Compaction failed"

      # allowlist: snapshot — messages
      state = :sys.get_state(pid, 1_000)

      requests =
        for {:user, %User{parts: [%Part.Text{text: text}]} = user} <- state.chat_state.messages,
            String.contains?(text, "[mode: compact]"),
            do: {user, text}

      # Exactly one: the failed attempt did not append a second request, and
      # the request is committed history rather than a request-only addition.
      assert [{request, text}] = requests

      # A real index — the row was stamped like any other message, which is
      # what makes it visible in the transcript and on the wire.
      assert is_integer(request.index)

      # The operator's `/compact <focus>` guidance rides in this message's
      # text, which is why the slash command needs no row of its own.
      assert text =~ "keep the API decisions"

      # ... and it is on the payload the client reads, not only in the agent's
      # own state.
      assert Enum.any?(Agent.get_messages(pid, 1_000), fn
               {:user, %User{parts: [%Part.Text{text: text}]}} ->
                 String.contains?(text, "[mode: compact]")

               _ ->
                 false
             end)
    end
  end

  # Assert the Agent produced no `:preflight_result` reply for a message it was
  # just sent. See the call sites: the `:sys.get_state/2` is what makes this
  # sound (and is why it needs no wait).
  defp refute_no_preflight_reply(pid) do
    # allowlist: barrier — refute_no_preflight_reply/1's anchor
    _ = :sys.get_state(pid, 1_000)
    refute_receive {:preflight_result, _, _}, 0
  end

  # Wait for the end of the turn on the turn's own event — the agent's
  # `{:chat_status, %{status: "idle"}}` broadcast — and then read the machine,
  # the authority, for the state it settled to. `Turn.run/6` announces the
  # status change last in the settle, after every effect of the turn (message
  # appends, the tool batch) has landed, so a subscriber woken by the "idle"
  # frame already holds every frame of the turn; the `get_public_info/2` call
  # behind the fence is a synchronous `GenServer.call` to the same process, so
  # it orders the call sites' `assert_received/1` assertions behind it too.
  # Every call site first fences on the batch's own broadcast, so the
  # sandbox work (real bwrap processes) is never inside this wait.
  defp await_idle(pid) do
    assert_receive {:chat_status, %{status: "idle"}}, 1_000

    assert Agent.get_public_info(pid, 1_000).status == :idle
  end
end
