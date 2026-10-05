defmodule MachineStructureTest do
  @moduledoc false
  # Structural "no reintroduction" tests for the Agent machine. These assert
  # properties of the source that unit/integration tests cannot catch.

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Machine

  @machine_sources Path.wildcard("lib/nest/agents/agent/machine.ex") ++
                     Path.wildcard("lib/nest/agents/agent/machine/*.ex")

  # Every Agent-owned source file. Used to prove the observable status is
  # never mirrored onto `live` / the machine structs.
  @agent_sources Path.wildcard("lib/nest/agents/agent.ex") ++
                   Path.wildcard("lib/nest/agents/agent/**/*.ex")

  describe "intent-comment placement" do
    test "intent notes are inline # comments, never in @doc/@moduledoc" do
      # INTENT-RULE: intentional behavior is recorded as an inline # comment
      # adjacent to the code it governs. A @doc/@moduledoc attribute lives in
      # a different region than the function body, so a line-range read of the
      # body can miss it; an inline comment cannot be separated from its code.
      # This test fails if a machine module puts intent notes in
      # @doc/@moduledoc. Put the note inline next to the behavior instead.
      forbidden = ~r/\b(intentional|do not|must not|don't|shouldn't)\b/i

      for path <- @machine_sources do
        for {doc, _} <- doc_blocks(File.read!(path)) do
          refute Regex.match?(forbidden, doc),
                 "#{path}: intent must be an inline # comment, not @doc/@moduledoc:\n#{doc}"
        end
      end
    end
  end

  describe "single status authority" do
    test "Machine.status_for/1 is the exported observable-status authority" do
      # `function_exported?/3` does not load the module, so ensure it first;
      # otherwise this is order-dependent and can fail on a cold boot.
      assert Code.ensure_loaded?(Machine)
      assert function_exported?(Machine, :status_for, 1)
    end

    test "no Agent source stores an observable status on live" do
      # A status key set through a struct update (`%{state.live | status: _}`)
      # is the reintroduction shape: the observed status must be derived via
      # Machine.status_for/1, never written as a parallel field.
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
      # route_for/1 tags the machine deliberately does not model: the
      # in-process Turn applies them directly (worker results, LLM stream
      # events, sub-agent + compaction lifecycle, stop/idle bookkeeping,
      # EXIT/DOWN). Adding a tag to Handlers without classifying it here or
      # in Machine.events/0 fails this test.
      lifecycle =
        MapSet.new([
          :delta_received,
          :thinking_signature_received,
          :llm_error,
          :tool_calls_received,
          :tool_results_received,
          :llm_usage,
          :iterate,
          :http_response,
          :DOWN,
          :chat_idle,
          :chat_stopped,
          :chat_crashed,
          :set_crossed_thresholds,
          :set_context_projection,
          :api_log_sequences_updated,
          :compaction_done,
          :compaction_failed,
          :needs_compaction,
          :EXIT
        ])

      tags = route_tags()

      # Anchor the extraction: if the source shape changes and the scan
      # returns nothing, the loop below would be vacuously true.
      assert :iterate in tags and :http_error in tags and :compaction_done in tags

      for tag <- tags do
        assert tag in Machine.events() or MapSet.member?(lifecycle, tag),
               "route_for/1 tag #{inspect(tag)} is neither a Machine event nor a " <>
                 "known lifecycle tag; classify it explicitly"
      end
    end

    test "step/2 handles every declared Machine event" do
      for tag <- Machine.events() do
        refute Machine.step(Machine.new(), sample_event(tag)) == :quarantine,
               "declared Machine event #{inspect(tag)} is not handled by step/2"
      end
    end
  end

  # Extract the string bodies of @doc / @moduledoc attributes only (never
  # inline comments). Only triple-quoted attributes carry bodies; bare
  # `@moduledoc false` has none.
  defp doc_blocks(source) do
    Regex.scan(~r/@(?:moduledoc|doc)\s+"""(.*?)"""/s, source)
    |> Enum.map(fn [_, body] -> {body, :doc} end)
  end

  defp field_set(mod), do: mod.__struct__() |> Map.from_struct() |> Map.keys() |> Enum.sort()

  # Base expressions of `%{base | ..., status: ...}` map updates.
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

  defp sample_event(:chat_request), do: {:chat_request, %{text: "hi"}}
  defp sample_event(:http_ok), do: {:http_ok, %{tool_calls: []}}
  defp sample_event(:http_error), do: {:http_error, :boom}
  defp sample_event(:worker_crashed), do: {:worker_crashed, %RuntimeError{}, []}
  defp sample_event(:worker_down), do: {:worker_down, :killed}
  defp sample_event(:tool_results), do: {:tool_results, %{results: []}}
  defp sample_event(:stop), do: {:stop, self()}
  defp sample_event(:stop_timer), do: :stop_timer
  defp sample_event(:compaction_request), do: {:compaction_request, {:tool_call, %{}, 1, 10}}
  defp sample_event(:compaction_ok), do: {:compaction_ok, %{summary: "s"}}
  defp sample_event(:compaction_error), do: {:compaction_error, :boom}
  defp sample_event(:child_completed), do: {:child_completed, "kid", "resp", %{}}
  defp sample_event(:child_failed), do: {:child_failed, "kid", :crashed}
  defp sample_event(:child_terminated), do: {:child_terminated, "kid", :killed}
  defp sample_event(:abandon_child), do: {:abandon_child, "kid"}
  defp sample_event(:inbox_drain), do: {:inbox_drain, %{text: "queued"}}
  defp sample_event(:retry_compaction), do: :retry_compaction
  defp sample_event(:loop_ack), do: :loop_ack
end
