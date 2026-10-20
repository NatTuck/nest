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
        for doc <- doc_blocks(File.read!(path)) do
          refute Regex.match?(forbidden, doc),
                 "#{path}: intent must be an inline # comment, not @doc/@moduledoc:\n#{doc}"
        end
      end
    end
  end

  describe "single transition authority" do
    test "Machine.step/2 is exported and there is no `to_*` side door" do
      assert function_exported?(Machine, :step, 2)

      # A per-transition helper is the side door this pins shut, whatever it is
      # called: `step/2` must stay the only way to move the machine.
      side_doors =
        for {name, _arity} <- Machine.__info__(:functions),
            String.starts_with?(Atom.to_string(name), "to_"),
            do: name

      assert side_doors == [],
             "reintroduced side-door transition(s): #{inspect(side_doors)}"
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
                 :owed_replies,
                 :pending_user_message,
                 :phase,
                 :stop_timer,
                 :work
               ])

      assert field_set(Machine.Work) ==
               Enum.sort([
                 :active_message_index,
                 :active_worker,
                 :active_worker_kind,
                 :backgrounded,
                 :ctx,
                 :focus,
                 :force_finalize,
                 :iteration,
                 :max_iterations,
                 :pending_notice,
                 :preflight,
                 :preserve,
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
                 :inbox_seq,
                 :machine,
                 :mode,
                 :pending_notice,
                 :repair,
                 :streaming_acc,
                 :tool_index_map,
                 :watches
               ])
    end
  end

  defp doc_blocks(source) do
    Regex.scan(~r/@(?:moduledoc|doc)\s+"""(.*?)"""/s, source)
    |> Enum.map(fn [_, body] -> body end)
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
end
