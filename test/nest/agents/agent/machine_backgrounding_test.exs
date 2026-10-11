defmodule Nest.Agents.Agent.MachineBackgroundingTest do
  @moduledoc """
  The mid-batch backgrounding transition (issue #36, step 3).

  A message that arrives while a tool batch is executing is delivered *now*: the
  batch moves out of `worker_ref`/`active_worker` into `work.backgrounded`, its
  calls are answered by the synthetic result, and the turn continues with the
  delivered message. `MachineBackgroundedTest` covers step 2's routing of an
  entry that already exists; this file covers how the entry is created, what the
  delivery appends, and that the result still finds its entry while a *new*
  batch is in flight.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.LLM.Preflight
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolCall
  alias Nest.Messages.User

  describe "a delivery while a batch executes" do
    test "backgrounds the batch and continues the turn with the delivered message" do
      m = executing_state()
      entries = [entry("peer note")]

      {:ok, actions, next} = Machine.step(m, {:inbox_drain, entries, "peer note"})

      ref = m.work.worker_ref
      calls = MessageList.unpaired_tail_tool_uses(m.work.ctx.messages)

      assert [{:append_many, [synthetic, ack, user]}, {:consume_inbox, ^entries}, :iterate] =
               actions

      # The synthetic result answers *every* pending call: a partial answer
      # appends fine and then fails the turn at the next `:iterate`, and a
      # missing answer would be dropped as `:stale` and strand the turn.
      assert {:tool, %Tool{parts: parts}} = synthetic
      assert Enum.map(parts, & &1.tool_call_id) == Enum.map(calls, & &1.id)

      assert Enum.all?(
               parts,
               &(&1.is_error == false and &1.content =~ "moved to the background")
             )

      # The ack is the machine's own, not the live-bridge alternation ack: it
      # has to say what happened to the call.
      assert {:assistant, %{parts: [%Part.Text{text: ack_text}]}} = ack
      assert ack_text =~ "running in the background"

      assert {:user, %User{parts: [%Part.Text{text: text}]}} = user
      assert text == "[mode: chat]\npeer note"

      # The batch moved out of the worker fields — which `Phase.enter/4` nulls —
      # into the entry its late result is routed on. The calls are not kept:
      # the synthetic result answered them, and the transcript holds that answer.
      assert next.work.backgrounded == %{ref => %{pid: m.work.active_worker, calls: 1}}
      assert next.work.worker_ref == nil
      assert next.work.active_worker == nil

      # The turn continues in `:generating`. Staying in `:executing_tools` would
      # strand it: `:iterate` is ignored there.
      assert next.phase == :generating and next.kind == :chat
      assert Machine.status_for(next) == :streaming
      Machine.validate!(next)
    end

    test "the appended batch leaves the transcript wire-valid" do
      m = executing_state()

      {:ok, [{:append_many, batch}, _consume, :iterate], _next} =
        Machine.step(m, {:inbox_drain, [entry("peer note")], "peer note"})

      # What the model is shown next: the batch's assistant, the synthetic
      # result, the ack, and the delivered message.
      transcript = m.work.ctx.messages ++ batch

      assert Preflight.validate_request(transcript) == :ok
      assert Preflight.validate_tool_call_pairing(transcript) == :ok
    end

    test "a :query mid-batch incurs the reply debt and fires the context notice" do
      # The two effects `start_chat/3`'s `:fits` branch owns that the
      # backgrounding path has to reach through the *same* assembly
      # (`Machine.Delivery`):
      #
      #   * the reply obligation a delivered `:query` incurs (issue #31 §1.3).
      #     Without it a later failure, block or restart gives up nothing for
      #     the requester, whose `agents-wait` then just times out.
      #   * the context-threshold notice, which has to land *between* the
      #     synthetic batch and the delivered message: a notice pair is
      #     assistant-shaped, so after the user message the request would end on
      #     an assistant and `Preflight.validate_request/1` would fail it.
      #
      # The limit is small enough that the padded transcript crosses 25% of the
      # working budget (reserve 8_192, budget 1_808, so 25% is ~452 tokens) and
      # large enough that the delivery still fits it.
      base = put_messages(executing_state(), padded_tail())

      m = %{
        base
        | work: %{
            base.work
            | ctx: %{base.work.ctx | context_limit: 10_000, crossed_thresholds: MapSet.new()}
          }
      }

      entries = [entry("the question", :query, "alice")]

      {:ok, actions, next} = Machine.step(m, {:inbox_drain, entries, "the question"})

      # The debt is the boundary's own shape: one key per named query sender,
      # its reminder count starting at 0.
      assert next.owed_replies == %{"alice" => 0}

      assert [
               {:append_many, [synthetic, ack]},
               {:append_many, [notice, notice_ack]},
               {:set_crossed_thresholds, crossed},
               {:set_context_projection, _used},
               {:append, delivered},
               {:consume_inbox, ^entries},
               :iterate
             ] = actions

      assert {:tool, _} = synthetic
      assert {:assistant, _} = ack

      assert {:user, %User{parts: [%Part.Text{text: notice_text}]}} = notice
      assert notice_text =~ "Context at 25%"

      assert {:assistant, %Assistant{parts: [%Part.Text{text: ack_text}]}} = notice_ack
      assert ack_text =~ "plenty of space"

      assert {:user, %User{parts: [%Part.Text{text: text}]}} = delivered
      assert text == "[mode: chat]\nthe question"

      # The threshold is recorded on the machine, so it does not fire again for
      # this segment, and the turn continues in `:generating`.
      assert next.work.ctx.crossed_thresholds == MapSet.new([:p25])
      assert crossed == MapSet.new([:p25])
      assert next.phase == :generating and next.kind == :chat

      # The delivered batch still leaves a wire-valid transcript.
      transcript = m.work.ctx.messages ++ [synthetic, ack, notice, notice_ack, delivered]

      assert Preflight.validate_request(transcript) == :ok
    end
  end

  describe "the guard (decision D3)" do
    test "a delivery that would not fit is declined, not dispatched" do
      # Backgrounding *dispatches* the delivered message, so a delivery the turn
      # boundary would have compacted for or blocked on is declined here
      # instead: the entries stay queued and the boundary runs the real
      # decision. The fixture's own decision is asserted, so the test cannot
      # pass by a limit that happens to fit.
      cases = [
        {"needs compaction", 8_300, :needs_compaction},
        {"cannot compact", 100, :cannot_compact}
      ]

      for {label, limit, expected} <- cases do
        base = put_messages(executing_state(), over_budget_tail())
        m = %{base | work: %{base.work | ctx: %{base.work.ctx | context_limit: limit}}}
        user = Dispatch.build_user_message("peer note", "chat")

        assert ^expected = Dispatch.preflight_decision(m.work.ctx.messages ++ [user], limit),
               "#{label}: the fixture must decide #{inspect(expected)}"

        assert {:ignore, :delivery_would_not_fit, ^m} =
                 Machine.step(m, {:inbox_drain, [entry("peer note")], "peer note"}),
               "#{label}: the delivery must stay queued"
      end
    end

    test "a delivery with nothing to background is a no-op that leaves the entries queued" do
      base = executing_state()

      cases = [
        {"no live worker", %{base | work: %{base.work | active_worker: nil}}},
        {"no worker ref", %{base | work: %{base.work | worker_ref: nil}}},
        {"nothing left to answer",
         %{base | work: %{base.work | ctx: %{base.work.ctx | messages: answered_tail()}}}},
        {"no context at all", %{base | work: %{base.work | ctx: nil}}}
      ]

      for {label, m} <- cases do
        entries = [entry("peer note")]

        assert {:ignore, :no_batch_to_background, ^m} =
                 Machine.step(m, {:inbox_drain, entries, "peer note"}),
               "#{label} must not background anything"

        # The machine is untouched, so the entries are still queued and the turn
        # boundary drains them exactly as it did before.
        assert m.work.backgrounded == %{}
      end
    end
  end

  describe "the recorded call count (issue #36 step 4)" do
    test "a multi-call batch records how many calls it answered" do
      m =
        put_messages(executing_state(), [
          system_message(),
          user_message(),
          assistant_tool_call(2, ["c1", "c2", "c3"])
        ])

      {:ok, _actions, next} = Machine.step(m, {:inbox_drain, [entry("peer note")], "peer note"})

      # One entry per *batch*, so the entry count says nothing about how many
      # promises the batch holds: the stop's cancellation record counts calls,
      # and it reads this field.
      assert next.work.backgrounded ==
               %{m.work.worker_ref => %{pid: m.work.active_worker, calls: 3}}
    end
  end

  describe "the two-batch interleaving" do
    test "batch A's real result finds its entry while batch B is in flight" do
      m = executing_state()
      ref_a = m.work.worker_ref
      pid_a = m.work.active_worker

      # A message arrives mid-batch, so batch A moves to the background.
      {:ok, _actions, m} = Machine.step(m, {:inbox_drain, [entry("first note")], "first note"})

      assert %{^ref_a => %{pid: ^pid_a}} = m.work.backgrounded

      # The delivered message's turn runs, the model asks for a second batch,
      # and batch B's worker starts.
      m = start_batch(m, make_ref())
      ref_b = m.work.worker_ref

      assert m.phase == :executing_tools
      assert ref_b != ref_a

      # A's real result arrives while B is in flight. The routing keys on the
      # entry, not on `worker_ref` — which now belongs to B — so a
      # `valid_ref?/2`-style check would drop A's result as stale.
      results = [result("A finished")]
      {:ok, [delivery], m} = Machine.step(m, {:tool_results, ref_a, results})

      # The delivery carries the ids its notice answers: the fulfilled marker
      # a later load reads to tell this kept promise from a lost one.
      assert {:deliver_backgrounded, ref_a, {:results, ^results}, ["c1"]} = delivery
      assert m.work.backgrounded == %{}

      # B is untouched, and A's ref can never answer twice.
      assert m.work.worker_ref == ref_b
      assert {:ignore, :stale_result, _m} = Machine.step(m, {:tool_results, ref_a, results})
    end
  end

  # --- helpers ---

  # Drive the machine through one model turn that asks for a tool batch and
  # whose worker starts: the state every `:executing_tools` fixture here needs.
  defp start_batch(m, ref) do
    http_ref = make_ref()
    {:ok, [], m} = Machine.step(m, {:worker_started, http_ref, self(), :http})
    {:ok, _actions, m} = Machine.step(m, {:http_ok, http_ref, response()})
    {:ok, _actions, m} = Machine.step(m, {:preflight_result, :fits})
    {:ok, [], m} = Machine.step(m, {:worker_started, ref, self(), :tools})
    m
  end

  defp executing_state do
    ref = make_ref()

    machine =
      Machine.new(
        phase: :executing_tools,
        kind: :chat,
        work: %Machine.Work{
          worker_kind: :tools,
          worker_ref: ref,
          active_worker: self(),
          ctx: ctx(),
          max_iterations: 10,
          active_message_index: 2
        }
      )

    # The turn that asked for the batch: the assistant carrying the calls, whose
    # ids the synthetic result has to answer.
    put_messages(machine, [system_message(), user_message(), assistant_tool_call()])
  end

  # The same transcript, with the batch's call already answered (so there is
  # nothing left to background).
  defp answered_tail do
    [system_message(), user_message(), assistant_tool_call(), tool_result()]
  end

  # A transcript whose projected total is over a tight limit while its system
  # prompt alone stays under it. Both halves matter: the head between the system
  # prompt and the last user message has to be non-empty (or compaction is a
  # no-op and the decision is `:cannot_compact` at any limit), and the padded
  # body keeps the margin from depending on the estimator's per-message
  # overhead.
  defp over_budget_tail do
    [
      system_message(),
      user_message(1, String.duplicate("x", 2_000)),
      assistant_text(2, "ok"),
      user_message(3, "more"),
      assistant_tool_call(4, ["c1"])
    ]
  end

  defp put_messages(m, messages) do
    %{m | work: %{m.work | ctx: %{m.work.ctx | messages: messages}}}
  end

  defp entry(content, kind \\ :agent, from \\ "peer") do
    %{from: from, content: content, timestamp: DateTime.utc_now(), kind: kind, mode: nil}
  end

  # The batch fixture's transcript with a body big enough to cross 25% of a
  # 10_000-token limit's working budget (reserve 8_192, budget 1_808, so 25%
  # fires at ~452 tokens) while staying well under it, and with the assistant
  # carrying the batch's unanswered call still as the tail.
  defp padded_tail do
    [
      system_message(),
      user_message(1, String.duplicate("x", 3_000)),
      assistant_tool_call(2, ["c1"])
    ]
  end

  defp result(content) do
    %Part.ToolResult{
      tool_call_id: "c1",
      name: "shell-cmd",
      arguments: %{},
      content: content,
      is_error: false
    }
  end

  defp assistant_tool_call(index \\ 2, ids \\ ["c1"]) do
    {:assistant,
     %Nest.Messages.Assistant{
       index: index,
       parts: Enum.map(ids, &%Part.ToolUse{id: &1, name: "shell-cmd", arguments: %{}}),
       api_logs: []
     }}
  end

  defp assistant_text(index, text) do
    {:assistant,
     %Nest.Messages.Assistant{index: index, parts: [%Part.Text{text: text}], api_logs: []}}
  end

  defp tool_result do
    {:tool, %Tool{index: 3, parts: [result("ok")], api_logs: []}}
  end

  defp user_message(index \\ 1, text \\ "hi") do
    {:user, %User{index: index, parts: [%Part.Text{text: text}], api_logs: []}}
  end

  defp system_message do
    {:system, %Nest.Messages.System{index: 0, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp response do
    %RunResponse{
      text: "second",
      thinking: nil,
      tool_calls: [
        %ToolCall{id: "c2", name: "shell-cmd", arguments: %{}}
      ],
      refusal: nil,
      stop_reason: :tool_calls,
      model: "m",
      usage: %{}
    }
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
      messages: [],
      tmp_path: nil,
      workspace_path: nil,
      mode: "chat",
      next_message_index: 4,
      crossed_thresholds: %MapSet{},
      context_projection: nil,
      api_log_sequences: %{},
      vocation: nil,
      depth: 0
    }
  end
end
