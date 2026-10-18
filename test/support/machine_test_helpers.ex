defmodule Nest.TestSupport.MachineTestHelpers do
  @moduledoc """
  The fixtures `MachineTest` drives `Nest.Agents.Agent.Machine` with.

  Extracted to make room for the machine tests this branch adds — `MachineTest`
  was at 699 of its 700-line cap, so the fixtures moved out to leave space for
  the four new compaction tests (issue #80's remedy) — and so a second test
  file can drive the same machine without duplicating `ctx/0`, which is the
  piece that is genuinely fiddly to rebuild.

  The fixtures are pure — none of them touches a process or the database —
  except `send_compaction_done/3`, which drives a live agent's machine into the
  compactor's phase and delivers the response. It lives here because it reaches
  straight into the machine's fields, and `AgentTestHelpers` delegates to it.

  `sample_event/1` is the event vocabulary: `MachineTest` walks it to prove
  every declared event has a total transition, so a new event belongs here.
  """

  alias Nest.Agents.Agent.Machine
  alias Nest.Messages.User

  def action_tag(:iterate), do: :iterate
  def action_tag({tag}), do: tag
  def action_tag({tag, _}), do: tag
  def action_tag({tag, _, _}), do: tag
  def action_tag({tag, _, _, _}), do: tag

  def kind_for(:committing), do: :compaction
  def kind_for(_), do: :chat

  def user do
    %Nest.Messages.User{index: nil, parts: [%Nest.Messages.Part.Text{text: "hi"}], api_logs: []}
  end

  # The compaction request row, as `Nest.Tokens.Compactor` builds it: a `user`
  # row marked with the runtime's origin, which is what keeps it out of the
  # recall list and out of `MessageAppender`'s progress rule.
  def compaction_request do
    %Nest.Messages.User{
      index: nil,
      parts: [%Nest.Messages.Part.Text{text: "[mode: compact] Summarize the conversation."}],
      metadata: User.compaction_metadata(),
      api_logs: []
    }
  end

  def response(overrides \\ []) do
    struct(
      %Nest.LLM.RunResponse{
        text: "",
        thinking: nil,
        tool_calls: [],
        refusal: nil,
        stop_reason: :end_turn,
        model: "m",
        usage: %{}
      },
      overrides
    )
  end

  def system_message do
    {:system,
     %Nest.Messages.System{
       index: 0,
       parts: [%Nest.Messages.Part.Text{text: "sys"}],
       api_logs: []
     }}
  end

  # An assistant message carrying one unanswered `tool_use` — the tail
  # `Response.regular/5` leaves behind when a tool batch is about to run.
  def assistant_with_tool_use do
    {:assistant,
     %Nest.Messages.Assistant{
       index: 1,
       parts: [
         %Nest.Messages.Part.ToolUse{id: "call_1", name: "shell-cmd", arguments: %{}}
       ],
       api_logs: []
     }}
  end

  def ctx do
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
      mode: "chat",
      next_message_index: 1,
      crossed_thresholds: %MapSet{},
      context_projection: nil,
      api_log_sequences: %{},
      vocation: nil,
      depth: 0
    }
  end

  def state_at(phase, opts \\ []) do
    work = %Machine.Work{
      worker_kind: worker_kind_for(phase),
      worker_ref: ref_for(phase),
      ctx: Keyword.get(opts, :ctx, ctx()),
      preflight: Keyword.get(opts, :preflight),
      max_iterations: 10
    }

    Machine.new(
      [
        phase: phase,
        kind: kind_for(phase),
        work: work
      ] ++ Keyword.take(opts, [:kind, :entry, :loop_count])
    )
  end

  def worker_kind_for(:generating), do: :http
  def worker_kind_for(:executing_tools), do: :tools
  def worker_kind_for(_), do: nil

  def ref_for(p) when p in [:generating, :executing_tools, :stopping], do: make_ref()
  def ref_for(_), do: nil

  def sample_event(:chat_request), do: {:chat_request, {:user_message, user()}}
  def sample_event(:iterate), do: :iterate
  def sample_event(:inbox_drain), do: {:inbox_drain, [], "queued"}
  def sample_event(:http_ok), do: {:http_ok, make_ref(), response()}
  def sample_event(:http_error), do: {:http_error, make_ref(), :boom}
  def sample_event(:worker_crashed), do: {:worker_crashed, make_ref(), %RuntimeError{}, []}
  def sample_event(:worker_down), do: {:worker_down, self(), :killed}
  def sample_event(:worker_started), do: {:worker_started, make_ref(), self(), :http}
  def sample_event(:llm_error), do: {:llm_error, make_ref(), "boom"}
  def sample_event(:append_result), do: {:append_result, :stale, nil}
  def sample_event(:preflight_result), do: {:preflight_result, :fits}
  def sample_event(:stop), do: {:stop, self()}
  def sample_event(:stop_timer), do: :stop_timer
  def sample_event(:timer_armed), do: {:timer_armed, :stop_timer, make_ref()}
  def sample_event(:commit_done), do: {:commit_done}
  def sample_event(:commit_error), do: {:commit_error, :boom}
  def sample_event(:compaction_error), do: {:compaction_error, :boom, nil}
  def sample_event(:retry_compaction), do: :retry_compaction
  def sample_event(:compact_request), do: {:compact_request, nil}
  def sample_event(:loop_ack), do: :loop_ack
  def sample_event(:blocked), do: {:blocked, :needs_repair, nil}
  def sample_event(:unblocked), do: {:unblocked}
  def sample_event(:workspace_notice), do: :workspace_notice
  def sample_event(:tool_results), do: {:tool_results, make_ref(), []}
  def sample_event(:reply_sent), do: {:reply_sent, "peer"}
  def sample_event(:child_spawned), do: {:child_spawned, "kid", false, nil}
  def sample_event(:child_completed), do: {:child_completed, "kid", "resp", %{}}
  def sample_event(:child_failed), do: {:child_failed, "kid", :crashed}
  def sample_event(:child_terminated), do: {:child_terminated, "kid", :killed}
  def sample_event(:abandon_child), do: {:abandon_child, "kid"}

  @doc """
  Deliver a compaction result to an agent by driving the production
  compaction entry: put the machine into the compactor's `:generating`
  phase with `entry = {:compaction, carried_entry, nil}`, then send the
  `{:http_response, ref, %RunResponse{}}` the executor's commit path
  consumes (via `Compaction.commit_compaction/2`).
  """
  def send_compaction_done(agent_pid, summary_text, carried_entry) do
    ref = make_ref()

    # Put the machine into the compactor's generating phase with a live
    # worker ref, then deliver the HTTP response. `active_message_index` is
    # the index the *summary* will be stamped with; the request message is
    # not fabricated here — in production the machine appends it before
    # dispatching the compactor, and this helper starts after that point.
    :sys.replace_state(
      agent_pid,
      fn state ->
        machine = state.live.machine

        machine = %{
          machine
          | kind: :compaction,
            phase: :generating,
            entry: {:compaction, carried_entry, nil},
            work: %{
              machine.work
              | worker_kind: :http,
                worker_ref: ref,
                active_message_index: state.chat_state.next_message_index
            }
        }

        %{state | live: %{state.live | machine: machine}}
      end,
      1_000
    )

    send(
      agent_pid,
      {:http_response, ref, %Nest.LLM.RunResponse{text: summary_text, usage: nil}}
    )
  end
end
