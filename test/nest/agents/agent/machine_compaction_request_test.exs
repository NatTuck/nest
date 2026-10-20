defmodule MachineCompactionRequestTest do
  @moduledoc false
  # NOTE: per the project rule, this file's behavior contract is carried by
  # the tests + inline # comments below, not by this moduledoc.

  use ExUnit.Case, async: true

  import Nest.TestSupport.MachineTestHelpers

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Response
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolCall

  describe "manual compaction (:compact_request)" do
    test "from :idle it stages a compaction turn and defers an :iterate" do
      # intentional: /compact reuses the exact automatic-compaction path;
      # the only difference is the user-initiated entry point. The focus rides
      # on `work.focus` — `Dispatch.compaction_plan/1` renders it into the
      # `[mode: compact]` request message's own text, which is why
      # `/compact <focus>` needs no row of its own in the transcript.
      {:ok, actions, next} =
        Machine.step(state_at(:idle), {:compact_request, "keep the API decisions"})

      assert :iterate in actions
      assert next.kind == :compaction and next.phase == :generating
      assert {:compaction, nil, nil} = next.entry
      assert next.work.focus == "keep the API decisions"

      # The request is appended before the compactor runs, carrying the focus.
      assert {:append, {:user, %{parts: [%Part.Text{text: text}]}}} =
               Enum.find(actions, &match?({:append, _}, &1))

      assert text =~ "keep the API decisions"

      Machine.validate!(next)
    end

    test "from a non-idle phase it is ignored" do
      # intentional: compaction only starts from idle; a request while a
      # turn is in flight is a no-op (the Agent rejects it before stepping).
      generating = state_at(:generating)

      assert {:ignore, :not_applicable, ^generating} =
               Machine.step(generating, {:compact_request, nil})
    end

    test "a fourth consecutive manual request never trips the loop breaker" do
      # intentional: a manual request resets loop_count before staging, so
      # deliberate back-to-back compactions are not mistaken for the
      # automatic compaction loop the breaker guards against. Four is one
      # more than the cap, so this only passes because of the reset: without
      # it the fourth request would trip `:compaction_loop_detected`.
      {tripped?, final} =
        Enum.reduce(1..4, {false, state_at(:idle)}, fn _, {tripped?, machine} ->
          {:ok, actions, next} = Machine.step(machine, {:compact_request, nil})

          tripped =
            tripped? or
              Enum.any?(actions, &match?({:broadcast, {:compaction_loop, _, _, _}, _}, &1))

          # Simulate the compaction completing and returning to idle,
          # carrying the loop_count the stage left behind.
          {tripped, %{next | phase: :idle, kind: :chat, work: %{next.work | worker_kind: nil}}}
        end)

      refute tripped?
      assert final.loop_count == 1
    end
  end

  describe "context-compact tool arguments" do
    test "the call and its synthetic result are persisted before the request" do
      call =
        tool_call(%{
          "cover" => "the #117 work",
          "preserve" => "PRESERVED: the task and the state"
        })

      {:ok, actions, next} =
        Response.dispatch(state_at(:generating), response(tool_calls: [call]))

      # The call is an ordinary action of the turn being archived, so it lands
      # before the request row: the archive holds call, result, bridge ack,
      # request, summary — and the pair never has to be replayed into the new
      # segment, which is what put the call on the wrong side of the marker.
      assert [
               {:append, {:assistant, _}},
               {:append, {:tool, _}},
               {:append, {:user, _}} | _
             ] = Enum.filter(actions, &match?({:append, _}, &1))

      assert {:compaction, {:compact_resume, 0, 10}, nil} = next.entry

      # The result is a plain success that says what is true when it is
      # written: the compaction is starting.
      {:append, {:tool, %Tool{parts: [%Part.ToolResult{content: content, is_error: false}]}}} =
        Enum.find(actions, &match?({:append, {:tool, _}}, &1))

      assert content == "Compacting now."

      # The request names the arguments instead of repeating them (they are in
      # the conversation, one message back) and says how to treat them.
      {:append, {:user, %{parts: [%Part.Text{text: request}]}}} =
        Enum.find(actions, &match?({:append, {:user, _}}, &1))

      refute request =~ "PRESERVED"
      refute request =~ "the #117 work"
      assert request =~ "`cover` argument"
      assert request =~ "`preserve` argument"
    end

    test "a call with no arguments stages a compaction with no preserve" do
      {:ok, _actions, next} =
        Response.dispatch(state_at(:generating), response(tool_calls: [tool_call(%{})]))

      assert next.kind == :compaction and next.phase == :generating
      assert next.work.preserve == nil

      # The tool path's guidance is the constant clause, so it does not depend
      # on the call having arguments.
      assert next.work.focus =~ "`cover` argument"
    end

    test "an over-long cover is refused and stages no compaction" do
      long = String.duplicate("x", 101)

      {:ok, actions, next} =
        Response.dispatch(
          state_at(:generating),
          response(tool_calls: [tool_call(%{"cover" => long})])
        )

      # Nothing staged: no compaction turn, no request row, and the agent is
      # back in its chat turn with an error result naming the contract, so it
      # can shorten the cover or move the text to `preserve` and ask again.
      assert next.entry == nil
      assert next.kind == :chat and next.phase == :generating
      refute Enum.any?(actions, &match?({:append, {:user, _}}, &1))
      assert :iterate in actions

      {:append, {:tool, %Tool{parts: [%Part.ToolResult{content: content, is_error: true}]}}} =
        Enum.find(actions, &match?({:append, {:tool, _}}, &1))

      assert content =~ "101 characters"
      assert content =~ "`preserve`"
    end

    test "a non-string preserve is refused rather than silently dropped" do
      {:ok, actions, next} =
        Response.dispatch(
          state_at(:generating),
          response(tool_calls: [tool_call(%{"preserve" => 42})])
        )

      assert next.entry == nil

      {:append, {:tool, %Tool{parts: [%Part.ToolResult{content: content, is_error: true}]}}} =
        Enum.find(actions, &match?({:append, {:tool, _}}, &1))

      assert content =~ "`preserve` must be a string"
    end

    test "a legacy focus argument is refused, not ignored" do
      # An agent that is already running holds the tool schema it was started
      # with — the list is only rebuilt on a workspace change or a compaction —
      # so its first `context-compact` call after this deploy still passes
      # `focus`. Ignoring it would lose that guidance silently, once, which is
      # the loss this contract exists to prevent. The refusal costs one
      # iteration, and its message is the only place the new contract can reach
      # a caller that cannot see the new descriptions.
      cases = [
        %{"focus" => "keep the API decisions"},
        %{"focus" => "keep the API decisions", "cover" => "the API decisions"}
      ]

      for arguments <- cases do
        {:ok, actions, next} =
          Response.dispatch(state_at(:generating), response(tool_calls: [tool_call(arguments)]))

        assert next.entry == nil, "expected no compaction staged for #{inspect(arguments)}"
        refute Enum.any?(actions, &match?({:append, {:user, _}}, &1))
        assert :iterate in actions

        {:append, {:tool, %Tool{parts: [%Part.ToolResult{content: content, is_error: true}]}}} =
          Enum.find(actions, &match?({:append, {:tool, _}}, &1))

        assert content =~ "`focus` no longer exists"
        assert content =~ "`cover`"
        assert content =~ "`preserve`"
      end
    end

    test "a non-string cover is refused" do
      {:ok, actions, next} =
        Response.dispatch(
          state_at(:generating),
          response(tool_calls: [tool_call(%{"cover" => 42})])
        )

      assert next.entry == nil

      {:append, {:tool, %Tool{parts: [%Part.ToolResult{content: content, is_error: true}]}}} =
        Enum.find(actions, &match?({:append, {:tool, _}}, &1))

      assert content =~ "`cover` must be a string"
      assert content =~ "42"
    end

    test "a blank or whitespace-only preserve is treated as absent" do
      # The summary body joins its sections with a blank line between them, so a
      # preserve of `"   "` would render an empty section. Both normalize away,
      # and the compaction still stages.
      for blank <- ["", "   \n "] do
        {:ok, _actions, next} =
          Response.dispatch(
            state_at(:generating),
            response(tool_calls: [tool_call(%{"preserve" => blank})])
          )

        assert next.kind == :compaction and next.phase == :generating,
               "expected #{inspect(blank)} to stage a compaction"

        assert next.work.preserve == nil, "expected #{inspect(blank)} to normalize to nil"
      end
    end

    test "an unknown argument is refused rather than ignored" do
      # The same principle as the legacy `focus` refusal: an argument the tool
      # does not take would otherwise stage a compaction without whatever it
      # carried, silently. `preserve_text` is the shape a model invents; an atom
      # key is the shape a hand-built call has.
      for arguments <- [%{"preserve_text" => "KEEP"}, %{preserve: "KEEP"}] do
        {:ok, actions, next} =
          Response.dispatch(state_at(:generating), response(tool_calls: [tool_call(arguments)]))

        assert next.entry == nil, "expected no compaction staged for #{inspect(arguments)}"
        refute Enum.any?(actions, &match?({:append, {:user, _}}, &1))

        {:append, {:tool, %Tool{parts: [%Part.ToolResult{content: content, is_error: true}]}}} =
          Enum.find(actions, &match?({:append, {:tool, _}}, &1))

        assert content =~ "unknown argument"
        assert content =~ "`cover`"
        assert content =~ "`preserve`"
      end
    end

    test "a compaction that cannot start follows its own claim with a notice" do
      # The call and its synthetic "Compacting now." result are persisted before
      # the plan runs, so a staging failure cannot un-write them: the notice is
      # what follows the claim up. A second tool result would answer the same
      # call twice, which the wire's pairing rule rejects. An empty message list
      # with no vocation is the cheapest way to reach the failure (no system
      # prompt to render).
      machine = state_at(:generating, ctx: %{ctx() | messages: []})

      {:ok, actions, _next} =
        Response.dispatch(machine, response(tool_calls: [tool_call(%{"preserve" => "KEEP"})]))

      # The pair is in the transcript, and no request row was appended.
      assert Enum.any?(actions, &match?({:append, {:assistant, _}}, &1))
      assert Enum.any?(actions, &match?({:append, {:tool, _}}, &1))

      refute Enum.any?(actions, fn
               {:append, {:user, %{parts: [%Part.Text{text: text}]}}} ->
                 text =~ "[From nest runtime | mode: compact]"

               _ ->
                 false
             end)

      notice =
        Enum.find_value(actions, fn
          {:append, {:user, %{parts: [%Part.Text{text: text}]}}} -> text
          _ -> nil
        end)

      assert notice, "expected a notice row after the failed staging"
      assert notice =~ "Compaction did not start"
    end

    test "preserve reaches the commit data and does not survive the turn" do
      {:ok, _actions, staged} =
        Response.dispatch(
          state_at(:generating),
          response(tool_calls: [tool_call(%{"preserve" => "PRESERVED"})])
        )

      assert staged.work.preserve == "PRESERVED"

      # The commit is the last reader: it puts the text in the action data the
      # executor builds the summary message from.
      {:ok, actions, _committing} =
        Machine.Compaction.commit_compaction(staged, response(text: "a summary"))

      assert Enum.any?(actions, &match?({:commit_compaction, %{preserve: "PRESERVED"}}, &1))

      # And the turn boundary drops it, like the focus: a later *automatic*
      # compaction must not re-carry content nobody preserved for it. The
      # `:compact_resume` entry resumes generation, so the machine lands in a
      # chat turn rather than idling. (The focus's own turn-scoped lifetime,
      # and its observable consequence, are pinned below.)
      {:ok, resumed_actions, resumed} =
        Machine.step(%{staged | phase: :committing}, {:commit_done})

      assert resumed.kind == :chat and resumed.phase == :generating
      assert :iterate in resumed_actions
      assert resumed.work.preserve == nil
    end
  end

  defp tool_call(arguments) do
    %ToolCall{id: "c1", name: "context-compact", arguments: arguments}
  end

  describe "turn-scoped focus lifetime" do
    test "the focus does not survive the compaction turn into a later automatic compaction" do
      {:ok, _actions, staged} =
        Machine.step(state_at(:idle), {:compact_request, "keep the API decisions"})

      {:ok, _actions, resumed} = Machine.step(%{staged | phase: :committing}, {:commit_done})

      # intentional: finishing the compaction turn ends it (chat/idle), and
      # that turn boundary drops the focus. A stale focus that survived
      # would be silently applied to the NEXT *automatic* compaction
      # (staged from `start_chat/3`'s `:needs_compaction`,
      # `finalize_or_defer/4`, or `:workspace_notice`) — a summary nobody
      # asked for.
      assert resumed.phase == :idle
      assert resumed.work.focus == nil

      # intentional: the observable consequence of the reset — the next
      # compaction plan renders the plain budget suffix, with no stale
      # operator guidance in it.
      assert {:ok, request_message} = Dispatch.compaction_plan(resumed)
      assert {:user, %{parts: [%Part.Text{text: text}]}} = request_message
      refute text =~ "keep the API decisions"
      assert text =~ "remaining tokens"
    end

    test "a retry after a compaction failure re-renders the same focus" do
      {:ok, _actions, staged} =
        Machine.step(state_at(:idle), {:compact_request, "keep the API decisions"})

      {:ok, _actions, failed} = Machine.Compaction.compaction_failed(staged, :boom, nil)

      # intentional: `:compaction_failed` is entered via `enter_blocked/2`,
      # which must KEEP the focus — the failed turn is retryable and the
      # retry is the same compaction turn.
      assert failed.phase == :compaction_failed
      assert failed.work.focus == "keep the API decisions"

      {:ok, actions, retried} = Machine.step(failed, :retry_compaction)

      # intentional: a retry re-sends the existing sequence — it does not
      # re-plan, so it appends nothing and `work.focus` survives.
      assert retried.kind == :compaction and retried.phase == :generating
      assert retried.work.focus == "keep the API decisions"
      assert {:compaction, nil, nil} = retried.entry
      refute Enum.any?(actions, &match?({:append, _}, &1))
      assert :iterate in actions
    end
  end
end
