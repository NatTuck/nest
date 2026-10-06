defmodule MachineStructureTest do
  @moduledoc false
  # Structural "no reintroduction" tests for the Agent machine. These assert
  # properties of the source that unit/integration tests cannot catch.

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Machine

  @machine_sources Path.wildcard("lib/nest/agents/agent/machine.ex") ++
                     Path.wildcard("lib/nest/agents/agent/machine/*.ex")

  @agent_sources Path.wildcard("lib/nest/agents/agent.ex") ++
                   Path.wildcard("lib/nest/agents/agent/**/*.ex")

  describe "intent-comment placement" do
    test "intent notes are inline # comments, never in @doc/@moduledoc" do
      # INTENT-RULE: intentional behavior is recorded as an inline # comment
      # adjacent to the code it governs. A @doc/@moduledoc attribute lives in
      # a different region than the function body, so a line-range read of the
      # body can miss it; an inline comment cannot be separated from its code.
      forbidden = ~r/\b(intentional|do not|must not|don't|shouldn't)\b/i

      for path <- @machine_sources do
        for {doc, _} <- doc_blocks(File.read!(path)) do
          refute Regex.match?(forbidden, doc),
                 "#{path}: intent must be an inline # comment, not @doc/@moduledoc:\n#{doc}"
        end
      end
    end
  end

  describe "single transition authority" do
    test "Machine.step/2 is exported and there is no `to_*` side door" do
      assert Code.ensure_loaded?(Machine)
      assert function_exported?(Machine, :step, 2)
      refute function_exported?(Machine, :to_chat_generating, 1)
      refute function_exported?(Machine, :to_idle, 1)
      refute function_exported?(Machine, :to_blocked, 2)
      refute function_exported?(Machine, :to_stopping, 1)
      refute function_exported?(Machine, :to_compaction_generating, 1)
      refute function_exported?(Machine, :to_compaction_committing, 1)
    end

    test "no lib source calls a Machine.to_ transition" do
      offenders =
        for path <- @agent_sources, source = File.read!(path) do
          if Regex.match?(~r/Machine\.to_/, source), do: path
        end
        |> Enum.reject(&is_nil/1)

      assert offenders == [], "reintroduced side-door transition(s): #{inspect(offenders)}"
    end

    test "Turn is the only lib caller of Machine.step/2" do
      # Every machine event must flow through the settle loop so the
      # returned actions are run and status changes are broadcast. A
      # caller that steps the machine directly would silently drop
      # actions. Init enters its blocked phase via `Machine.Phase.enter_blocked/2`
      # (a pure phase write with no actions); model changes route
      # `{:unblocked}` through `Turn.settle/2`.
      offenders =
        for path <- @agent_sources,
            File.read!(path) =~ ~r/Machine\.step\(/,
            path != "lib/nest/agents/agent/turn.ex",
            do: path

      assert offenders == [],
             "Machine.step/2 must only be called from Turn; found: #{inspect(offenders)}"
    end

    test "no Agent source stores an observable status on live" do
      for path <- @agent_sources do
        for base <- map_update_status_bases(File.read!(path)) do
          refute base =~ "live",
                 "#{path}: `status:` is set on a live update (#{base}); " <>
                   "derive it with Machine.status_for/1 instead"
        end
      end
    end
  end

  describe "struct-field pins (no mirrored observable state)" do
    test "Machine, Work, and Live expose exactly their declared fields" do
      assert field_set(Machine) ==
               Enum.sort([
                 :children,
                 :entry,
                 :kind,
                 :loop_count,
                 :mid_turn_entry,
                 :pending_user_message,
                 :phase,
                 :resume,
                 :stop_timer,
                 :work
               ])

      assert field_set(Machine.Work) ==
               Enum.sort([
                 :active_message_index,
                 :active_worker,
                 :active_worker_kind,
                 :ctx,
                 :force_finalize,
                 :iteration,
                 :max_iterations,
                 :pending_notice,
                 :preflight,
                 :worker_kind,
                 :worker_ref
               ])

      assert field_set(Nest.Agents.Agent.ChatState.Live) ==
               Enum.sort([
                 :api_log_sequences,
                 :cancelled,
                 :context_projection,
                 :crossed_thresholds,
                 :inbox,
                 :machine,
                 :mode,
                 :pending_notice,
                 :repair,
                 :streaming_acc,
                 :tool_index_map
               ])
    end
  end

  describe "tag coverage" do
    test "every route_for/1 tag is a Machine event or a known lifecycle tag" do
      lifecycle =
        MapSet.new([
          :delta_received,
          :thinking_signature_received,
          :llm_usage,
          :api_log_sequences_updated,
          :llm_error,
          :http_response,
          :http_error,
          :worker_crashed,
          :DOWN,
          :EXIT
        ])

      tags = route_tags()

      assert :iterate in tags and :http_error in tags and :stop_timer in tags

      for tag <- tags do
        assert tag in Machine.events() or MapSet.member?(lifecycle, tag),
               "route_for/1 tag #{inspect(tag)} is neither a Machine event nor a " <>
                 "known lifecycle tag; classify it explicitly"
      end
    end

    test "step/2 handles every declared Machine event" do
      for tag <- Machine.events() do
        state = Machine.new(work: %Machine.Work{ctx: ctx(), max_iterations: 10})

        refute Machine.step(state, sample_event(tag)) == :quarantine,
               "declared Machine event #{inspect(tag)} is not handled by step/2"
      end
    end
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
      next_message_index: 0,
      crossed_thresholds: %MapSet{},
      context_projection: nil,
      api_log_sequences: %{},
      vocation: nil,
      depth: 0
    }
  end

  defp doc_blocks(source) do
    Regex.scan(~r/@(?:moduledoc|doc)\s+"""(.*?)"""/s, source)
    |> Enum.map(fn [_, body] -> {body, :doc} end)
  end

  defp field_set(mod), do: mod.__struct__() |> Map.from_struct() |> Map.keys() |> Enum.sort()

  defp map_update_status_bases(source) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {:|, _, [base, fields]} = node, acc when is_list(fields) ->
        if Keyword.keyword?(fields) and Keyword.has_key?(fields, :status),
          do: {node, [Macro.to_string(base) | acc]},
          else: {node, acc}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp route_tags do
    source = File.read!("lib/nest/agents/agent/handlers.ex")

    Regex.scan(~r/defp route_for\((.+?)\), do:/, source, capture: :all_but_first)
    |> Enum.map(fn [pattern] -> pattern |> Code.string_to_quoted!() |> event_tag_of() end)
    |> Enum.reject(&is_nil/1)
  end

  defp event_tag_of({:{}, _, [tag | _]}) when is_atom(tag), do: tag
  defp event_tag_of(tag) when is_atom(tag), do: tag
  defp event_tag_of(_), do: nil

  defp sample_event(:chat_request) do
    user =
      %Nest.Messages.User{
        index: nil,
        parts: [%Nest.Messages.Part.Text{text: "hi"}],
        api_logs: []
      }

    {:chat_request, {:user_message, user}}
  end

  defp sample_event(:iterate), do: :iterate
  defp sample_event(:inbox_drain), do: {:inbox_drain, [], "queued"}
  defp sample_event(:http_ok), do: {:http_ok, %{tool_calls: []}}
  defp sample_event(:http_error), do: {:http_error, :boom}
  defp sample_event(:worker_crashed), do: {:worker_crashed, %RuntimeError{}, []}
  defp sample_event(:worker_down), do: {:worker_down, :killed}
  defp sample_event(:worker_started), do: {:worker_started, make_ref(), self(), :http}
  defp sample_event(:llm_error), do: {:llm_error, make_ref(), "boom"}
  defp sample_event(:append_result), do: {:append_result, :stale, nil}
  defp sample_event(:preflight_result), do: {:preflight_result, :fits}
  defp sample_event(:stop), do: {:stop, self()}
  defp sample_event(:stop_timer), do: :stop_timer
  defp sample_event(:timer_armed), do: {:timer_armed, :stop_timer, make_ref()}
  defp sample_event(:commit_done), do: {:commit_done}
  defp sample_event(:commit_error), do: {:commit_error, :boom}
  defp sample_event(:compaction_error), do: {:compaction_error, :boom, nil}
  defp sample_event(:retry_compaction), do: :retry_compaction
  defp sample_event(:compact_request), do: :compact_request
  defp sample_event(:loop_ack), do: :loop_ack
  defp sample_event(:blocked), do: {:blocked, :needs_repair, nil}
  defp sample_event(:unblocked), do: {:unblocked}
  defp sample_event(:workspace_notice), do: :workspace_notice
  defp sample_event(:tool_results), do: {:tool_results, %{results: []}}
  defp sample_event(:child_spawned), do: {:child_spawned, "kid", make_ref(), false}
  defp sample_event(:child_completed), do: {:child_completed, "kid", "resp", %{}}
  defp sample_event(:child_failed), do: {:child_failed, "kid", :crashed}
  defp sample_event(:child_terminated), do: {:child_terminated, "kid", :killed}
  defp sample_event(:abandon_child), do: {:abandon_child, "kid"}
end
