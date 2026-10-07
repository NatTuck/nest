defmodule MachineBoundaryDeliveryTest do
  @moduledoc false
  # The turn-boundary inbox delivery contract (issue #15). It lives beside
  # `machine_test.exs` rather than inside it because that file is at the
  # credo source-file cap. Behavior contract carried by the tests + inline
  # `#` comments, same as the rest of the machine contract.

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Messages.Part
  alias Nest.Tokens.ConversationSize

  describe "turn-boundary inbox delivery (issue #15)" do
    test "a queued message is drained at the boundary and the phase stays :generating" do
      # intentional: at the `:iterate` boundary reached after a tool batch or
      # a final assistant ack the wire sequence is complete and nothing is in
      # flight, so a queued inbox message is drained before the next request.
      # The phase must NOT pass through `:idle`: a transient idle would
      # resolve an idle-based `agents-query` wait with the pre-delivery answer
      # and would fire `:child_completed` at a parent.
      for {label, tail} <- [{"tool", tool_tail()}, {"assistant", assistant_tail()}] do
        {:ok, actions, next} = Machine.step(boundary_state(tail, inbox_count: 1), :iterate)

        assert {:drain_inbox} in actions, "#{label} tail must drain the inbox"

        refute Enum.any?(actions, &match?({:spawn_http, _}, &1)),
               "#{label} tail must not dispatch"

        assert next.phase == :generating and next.kind == :chat
        assert Machine.status_for(next) == :streaming
      end
    end

    test "no boundary delivery without a queued message, or while the turn is finalizing" do
      # intentional: three ways "nothing queued" is expressed — the
      # hand-built-ctx default (no key at all), an explicit 0, and nil (which
      # is NOT an empty inbox: `nil > 0` is true in Erlang term order, hence
      # the `is_integer/1` guard in the transition). `force_finalize` keeps
      # its "wrap this turn up now" meaning, so the queued message waits for
      # the turn end.
      cases = [
        {[], "absent inbox_count"},
        {[inbox_count: 0], "inbox_count 0"},
        {[inbox_count: nil], "inbox_count nil"},
        {[inbox_count: 1, force_finalize: true], "force_finalize"}
      ]

      for {opts, label} <- cases do
        {:ok, actions, next} = Machine.step(boundary_state(tool_tail(), opts), :iterate)

        refute {:drain_inbox} in actions, "#{label} must not drain the inbox"
        assert Enum.any?(actions, &match?({:spawn_http, _}, &1)), "#{label} must dispatch"
        assert next.phase == :generating and next.kind == :chat
      end
    end

    test "no boundary delivery onto a just-opened turn or an unanswered tool_use" do
      # intentional: the tail-tag check excludes the just-opened-turn shape
      # (the machine itself just appended the user message, e.g. the
      # compaction resume path). The position inside the `[]` branch of the
      # unpaired-tool-use case keeps an `{:assistant, _}` tail that still
      # carries unanswered `Part.ToolUse` out of the drain: appending a user
      # message there would be refused by `Repair` and fail the turn, so the
      # pending tool call is preflighted instead. `last_wire_role/1` is not
      # usable for the tail check (it maps `:tool` to `:user`, and a tool tail
      # is exactly the case we deliver into).
      {:ok, user_actions, user_next} =
        Machine.step(boundary_state([{:user, user()}], inbox_count: 1), :iterate)

      refute {:drain_inbox} in user_actions
      assert Enum.any?(user_actions, &match?({:spawn_http, _}, &1))
      assert user_next.phase == :generating

      {:ok, use_actions, use_next} =
        Machine.step(
          boundary_state([{:user, user()}, assistant_tool_call()], inbox_count: 1),
          :iterate
        )

      refute {:drain_inbox} in use_actions
      assert Enum.any?(use_actions, &match?({:preflight, _, _, _}, &1))
      assert use_next.phase == :generating
    end

    test "the :generating :inbox_drain event starts the delivered turn in place" do
      # intentional: the drained message is appended as a user message and the
      # turn continues in `:generating` — the same body as the `:idle` clause,
      # but without passing through idle: no `{:finalize, _}` is emitted, so
      # no parent notification fires and no transient idle is broadcast.
      entries = [inbox_entry()]
      m = boundary_state(tool_tail(), inbox_count: 1)

      {:ok, actions, next} = Machine.step(m, {:inbox_drain, entries, "queued payload"})

      assert Enum.any?(actions, fn
               {:append, {:user, %Nest.Messages.User{parts: [%Part.Text{text: text}]}}} ->
                 text =~ "[mode: chat]" and text =~ "queued payload"

               _ ->
                 false
             end)

      assert :iterate in actions
      refute Enum.any?(actions, &match?({:finalize, _}, &1))
      assert next.phase == :generating and next.kind == :chat
      assert Machine.status_for(next) == :streaming
      # A fresh turn budget for the delivered message, as the `:idle` drain
      # gives it.
      assert next.work.iteration == 0
      assert next.work.force_finalize == false
      Machine.validate!(next)
    end

    test "a delivered message that needs compaction is held for the compaction turn" do
      # intentional: `start_chat/3` owns the fits decision. When the projected
      # turn needs a compaction the drained message is held on
      # `pending_user_message` (not appended and not restored), so the
      # compaction runs first and the delivered content is not lost.
      m = boundary_state(two_turn_tool_tail(), inbox_count: 1)

      # The window between "the system prompt alone fits" and "everything
      # fits" is a few tokens wide; derive the limit from the same estimator
      # the transition uses so the branch is forced, not guessed.
      projected = m.work.ctx.messages ++ [Dispatch.build_user_message("queued", "chat")]
      limit = ConversationSize.size(projected) + 8_191
      m = %{m | work: %{m.work | ctx: %{m.work.ctx | context_limit: limit}}}

      {:ok, actions, next} = Machine.step(m, {:inbox_drain, [inbox_entry()], "queued"})

      refute Enum.any?(actions, &match?({:append, _}, &1))
      refute Enum.any?(actions, &match?({:restore_inbox, _}, &1))
      assert next.kind == :compaction
      assert {:compaction, staged, nil} = next.entry
      assert is_list(staged)

      assert {:user_message, {:user, %Nest.Messages.User{parts: [%Part.Text{text: text}]}}} =
               next.pending_user_message

      assert text =~ "queued"
      Machine.validate!(next)
    end

    test "a delivered message that cannot compact is restored to the inbox" do
      # intentional: when the turn cannot fit and cannot be compacted, the
      # agent blocks on `:context_overflow` and the drained entries go back to
      # the inbox (`{:restore_inbox, entries}`) rather than being dropped with
      # the drain that already consumed them.
      entries = [inbox_entry()]
      m = boundary_state(tool_tail(), inbox_count: 1, context_limit: 1)

      {:ok, actions, next} = Machine.step(m, {:inbox_drain, entries, "queued"})

      assert Enum.any?(actions, &match?({:restore_inbox, ^entries}, &1))
      refute Enum.any?(actions, &match?({:append, _}, &1))
      assert next.phase == :context_overflow
      assert Machine.status_for(next) == :context_overflow
    end
  end

  # --- helpers ---

  # A `:generating` machine whose ctx ends on `tail`. `inbox_count` is
  # omitted unless asked for, so the tests cover the hand-built-ctx shape
  # (no key) as well as explicit 0/nil.
  defp boundary_state(tail, opts) do
    base = generating_state()
    ctx = base.work.ctx

    ctx = %{
      ctx
      | messages: ctx.messages ++ tail,
        context_limit: Keyword.get(opts, :context_limit, ctx.context_limit)
    }

    ctx =
      case Keyword.fetch(opts, :inbox_count) do
        {:ok, count} -> Map.put(ctx, :inbox_count, count)
        :error -> ctx
      end

    %{
      base
      | work: %{
          base.work
          | ctx: ctx,
            force_finalize: Keyword.get(opts, :force_finalize, false)
        }
    }
  end

  # The boundary right after a tool batch lands: the results answer the
  # assistant's tool call, so nothing is unanswered and nothing is in flight.
  defp tool_tail, do: [{:user, user()}, assistant_tool_call(), tool_result()]

  # The boundary after a final assistant ack (the other deliverable tail).
  defp assistant_tail, do: [{:user, user()}, assistant_text()]

  # Two user turns, so a compaction has a non-empty head to summarize: the
  # `:needs_compaction` branch is unreachable when the head is empty (that is
  # `:cannot_compact`).
  defp two_turn_tool_tail do
    [{:user, user()}, assistant_text(), {:user, user()}, assistant_tool_call(), tool_result()]
  end

  defp assistant_tool_call do
    {:assistant,
     %Nest.Messages.Assistant{
       parts: [%Part.ToolUse{id: "c1", name: "shell-cmd", arguments: %{}}]
     }}
  end

  defp assistant_text do
    {:assistant, %Nest.Messages.Assistant{parts: [%Part.Text{text: "ack"}]}}
  end

  defp tool_result do
    {:tool,
     %Nest.Messages.Tool{
       parts: [
         %Part.ToolResult{tool_call_id: "c1", name: "shell-cmd", content: "ok", is_error: false}
       ]
     }}
  end

  defp inbox_entry do
    %{from: "peer", content: "queued payload", timestamp: DateTime.utc_now()}
  end

  defp user do
    %Nest.Messages.User{index: nil, parts: [%Nest.Messages.Part.Text{text: "hi"}], api_logs: []}
  end

  defp system_message do
    {:system,
     %Nest.Messages.System{
       index: 0,
       parts: [%Nest.Messages.Part.Text{text: "sys"}],
       api_logs: []
     }}
  end

  defp ctx do
    %{
      agent_pid: self(),
      agent_name: "a",
      space_id: 1,
      client_config: %Nest.LLM.ClientConfig{client: Nest.LLM.MockClient, model: "m"},
      tools: [],
      tool_choice: :auto,
      caps: %{},
      context_limit: 100_000,
      context_limit_source: :default,
      messages: [system_message()],
      tmp_path: nil,
      workspace_path: nil,
      mode: "chat",
      next_message_index: 1,
      crossed_thresholds: %MapSet{},
      context_projection: nil,
      api_log_sequences: %{},
      vocation: nil,
      depth: 0
    }
  end

  defp generating_state do
    Machine.new(
      phase: :generating,
      kind: :chat,
      work: %Machine.Work{
        worker_kind: :http,
        worker_ref: make_ref(),
        ctx: ctx(),
        max_iterations: 10
      }
    )
  end
end
