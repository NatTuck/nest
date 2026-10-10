defmodule Nest.Agents.Agent.GuardTest do
  @moduledoc """
  Anti-drift guards for the Plan B architecture.

  These assert structural properties that unit tests cannot: `step/2` is the
  only transition authority and has a production caller, every declared
  action has an executor clause, effects only happen through the executor,
  no module outside `Machine` writes `phase:`, and every resting phase is
  entered through the funnel that gives up the reply debt.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.GiveUp

  @executor "lib/nest/agents/agent/turn/executor.ex"
  @turn "lib/nest/agents/agent/turn.ex"
  @handlers "lib/nest/agents/agent/handlers.ex"
  @funnel "lib/nest/agents/agent/machine/phase.ex"
  @give_up "lib/nest/agents/agent/machine/give_up.ex"
  @machine "lib/nest/agents/agent/machine.ex"

  # Every source the structural scans read. Deliberately wider than
  # `lib/nest/agents/**/*.ex`: `lib/nest/agents.ex` is the module *above* that
  # namespace (the glob never matches it) and `lib/nest_web/**` is where a
  # channel reads a machine (`agent_channel.ex` aliases `Machine`), so both are
  # places a phase writer could hide from a scan that stopped at the namespace.
  @sources Path.wildcard("lib/nest/agents.ex") ++
             Path.wildcard("lib/nest/agents/**/*.ex") ++ Path.wildcard("lib/nest_web/**/*.ex")

  # Turn-driving modules whose effects must route through the executor.
  @turn_drivers Path.wildcard("lib/nest/agents/agent/turn.ex") ++
                  Path.wildcard("lib/nest/agents/agent/machine.ex") ++
                  Path.wildcard("lib/nest/agents/agent/machine/*.ex") ++
                  Path.wildcard("lib/nest/agents/agent/chat_pipeline.ex") ++
                  Path.wildcard("lib/nest/agents/agent/handlers.ex") ++
                  Path.wildcard("lib/nest/agents/agent/handlers/*.ex") ++
                  Path.wildcard("lib/nest/agents/agent/compaction/*.ex") ++
                  Path.wildcard("lib/nest/agents/agent/init/*.ex") ++
                  Path.wildcard("lib/nest/agents/agent/inbox.ex")

  # Modules allowed to touch the sequence / spawn / timers directly.
  @effect_allowed MapSet.new([
                    "lib/nest/agents/agent/turn/executor.ex",
                    "lib/nest/agents/agent/message_appender.ex",
                    "lib/nest/agents/agent/callbacks.ex",
                    "lib/nest/agents/agent/inbox.ex"
                  ])

  test "every declared action has an executor clause" do
    source = File.read!(@executor)

    missing =
      for action <- Machine.actions(),
          not Regex.match?(~r/execute\(\{:#{action}\b/, source) and
            not Regex.match?(~r/execute\(:#{action}\b/, source),
          do: action

    assert missing == [], "actions with no executor clause: #{inspect(missing)}"
  end

  test "every declared event is handled by step/2" do
    for tag <- Machine.events() do
      event = sample_event(tag)
      refute Machine.step(Machine.new(work: %Machine.Work{ctx: ctx()}), event) == :quarantine
    end
  end

  test "step/2 has a production caller (the settle loop)" do
    assert File.read!(@turn) =~ "Machine.step("
  end

  test "no lib source calls a Machine.to_ transition" do
    offenders =
      for path <-
            Path.wildcard("lib/nest/agents/agent.ex") ++
              Path.wildcard("lib/nest/agents/agent/**/*.ex"),
          File.read!(path) =~ ~r/Machine\.to_/,
          do: path

    assert offenders == []
  end

  test "no lib source calls the test-only status_to_machine/2" do
    # `Machine.status_to_machine/2` is the inverse of `status_for/1` for
    # fixtures (its `@doc` says so). It is the one phase writer the resting-funnel
    # scan below cannot see: it writes the phase from a *value*
    # (`status_to_machine(m, status)` with `status` bound to `:idle` rests the
    # machine with no give-up and no notice), which is exactly why production
    # may not call it — production only ever reaches a phase through `step/2`.
    offenders =
      for path <- @sources,
          path != @machine,
          File.read!(path) =~ "status_to_machine",
          do: path

    assert offenders == [],
           "test-only phase writer called from lib/: #{inspect(offenders)}"
  end

  test "effects only happen through the executor and message appender" do
    forbidden =
      ~r/(MessageAppender\.[a-z_]+\(|Task\.Supervisor\.|Process\.send_after\(|GenServer\.cast\()/

    offenders =
      for path <- @turn_drivers,
          path not in @effect_allowed,
          Regex.match?(forbidden, File.read!(path)),
          do: path

    assert offenders == [], "effect call(s) outside the executor: #{inspect(offenders)}"
  end

  test "only the Machine namespace writes phase:" do
    forbidden = ~r/\|\s*phase:\s*:|phase:\s*:[a-z_]+,?\s*\n/

    offenders =
      for path <-
            Path.wildcard("lib/nest/agents/agent.ex") ++
              Path.wildcard("lib/nest/agents/agent/**/*.ex"),
          not String.starts_with?(path, "lib/nest/agents/agent/machine"),
          File.read!(path) =~ forbidden,
          do: path

    assert offenders == [], "imperative phase write(s) outside Machine: #{inspect(offenders)}"
  end

  test "only the resting funnel writes a resting phase" do
    # A resting phase — `:idle`, or any blocked phase — ends the turn, so the
    # reply it still owes is given up with it. `Phase.rest/4` and
    # `Phase.block/4` compute that give-up, which makes them the only doors to
    # those phases: a transition that entered one directly would rest with the
    # obligation still standing and no notice sent.
    #
    # The scan parses each file (`Code.string_to_quoted!/1`), so comments and
    # strings are invisible to it and formatting cannot hide a site. It is still
    # a static scan, and these are its limits, written where the next reader
    # looks:
    #
    #   * a phase passed as a *value* — `enter(m, kind, phase)` with `phase`
    #     bound to `:idle` — is invisible (the argument is a variable, not the
    #     atom);
    #   * the `Phase.rest/4` / `Phase.block/4` call scan keys on the literal
    #     `Phase.` spelling, so a call through an alias or a rename is
    #     invisible, and so is `apply/3` (the resting-*write* scan keys on the
    #     writer's function name, so an aliased `enter/3,4` is still caught);
    #   * only the sources in `@sources` are scanned — `lib/nest/agents.ex`,
    #     `lib/nest/agents/**/*.ex` and `lib/nest_web/**/*.ex` — so a phase
    #     write under another tree (e.g. `lib/nest/tools/`) is invisible;
    #   * `Machine.status_to_machine/2` writes a phase from a value as well; it
    #     has its own guard above ("no lib source calls the test-only
    #     status_to_machine/2") rather than relying on this scan.
    #
    # `resting_writes/1` recognises the shapes a writer could plausibly use —
    # `enter/3,4` (piped or not), `enter_blocked/2`, a `%{… | phase: …}` update,
    # `Map.put/3`, `struct/2` and `put_in/2` — and the "sees every cheap writer
    # shape" test below pins each of them, so this guard cannot pass by simply
    # not looking.
    offenders =
      for {path, ast} <- sources(), path != @funnel, write <- resting_writes(ast) do
        "#{path}:#{write.line}: #{write.kind}"
      end

    assert offenders == [], """
    resting phase(s) entered outside the funnel (`#{@funnel}`):

    #{Enum.map_join(offenders, "\n", &"  #{&1}")}

    A resting phase must be entered with `Machine.Phase.rest/4` (`:idle`) or
    `Machine.Phase.block/4` (a blocked phase), which compute the reply give-up
    (`Machine.GiveUp`) and prepend it to your actions. Pass a reason from
    `GiveUp.audit/0` and add a row there if it is a new one.
    """

    # The scan must still recognise the funnel's own write, otherwise an empty
    # offender list above would mean nothing.
    funnel_ast = sources() |> Enum.find_value(fn {path, ast} -> path == @funnel && ast end)

    assert Enum.any?(resting_writes(funnel_ast)), "the funnel's own write is not seen"
  end

  test "the resting-write scan sees every cheap writer shape" do
    # The scan is what makes the funnel the only door to a resting phase, so it
    # has to recognise the shapes a writer would plausibly use: a guard that
    # passes because it is not looking is worse than no guard.
    resting = [
      "Machine.Phase.enter(m, :chat, :idle)",
      "m |> Phase.enter(:chat, :idle)",
      "m |> Phase.enter(:chat, :needs_repair, :http)",
      "Phase.enter_blocked(m, :context_overflow)",
      "%{m | phase: :idle}",
      "Map.put(m, :phase, :compaction_failed)",
      "struct(m, phase: :model_missing)",
      "put_in(m.phase, :idle)"
    ]

    for source <- resting do
      assert source |> Code.string_to_quoted!() |> resting_writes() != [],
             "#{source} was not seen as a resting-phase write"
    end

    # ...and it must not fire on the same shapes writing a busy phase, or on a
    # different field.
    busy = [
      "Phase.enter(m, :chat, :generating, :http)",
      "m |> Phase.enter(:compaction, :committing)",
      "%{m | phase: :executing_tools}",
      "Map.put(m, :kind, :chat)",
      "struct(m, kind: :chat)",
      "put_in(m.kind, :chat)"
    ]

    for source <- busy do
      assert source |> Code.string_to_quoted!() |> resting_writes() == [],
             "#{source} was wrongly seen as a resting-phase write"
    end
  end

  test "the resting-site audit matches the funnel calls in the sources" do
    # The table in `Machine.GiveUp`'s moduledoc is rendered from `GiveUp.audit/0`
    # and this test is what keeps it honest: every `Phase.rest/4` /
    # `Phase.block/4` call in the sources must be in the table, with the same
    # number of sites, and every table row must have a site. So a new resting
    # transition fails the build until it is classified, and a deleted one
    # cannot leave a row behind.
    #
    # The scan matches the calls by the `Phase.` alias, so an aliased call is
    # reported as a missing site — write `Phase.rest(...)`.
    #
    # What it counts is *funnel calls in the sources*, not places that rest: a
    # wrapper helper (`defp my_rest(m), do: Phase.rest(m, :resume, [])`) is
    # counted once, inside the helper, while its own call sites are invisible —
    # so N rests through one helper look like one site, and a helper that fans
    # out is the one way to under-count this table. `apply/3` is invisible to it
    # for the same reason (there is no `Phase.rest(...)` call to see).
    calls = for {_path, ast} <- sources(), call <- funnel_calls(ast), do: call

    non_literal = Enum.reject(calls, &is_atom(&1.reason))

    assert non_literal == [], """
    every resting site must pass a literal reason atom, so the audit can see it:

    #{Enum.map_join(non_literal, "\n", &"  line #{&1.line}: #{inspect(&1.reason)}")}
    """

    found = calls |> Enum.map(& &1.reason) |> Enum.frequencies()
    audited = Map.new(GiveUp.audit(), &{&1.reason, &1.sites})

    assert found == audited, audit_message(found, audited)

    # The same rows are written out as the table a reader sees, in the module's
    # own documentation. Checking the source text is what keeps that table from
    # drifting: a row that `audit/0` does not have fails here too.
    source = File.read!(@give_up)

    for row <- GiveUp.audit() do
      assert source =~ "| `#{inspect(row.reason)}` | #{row.sites} |",
             "the audit table is missing the row for #{inspect(row.reason)}"
    end

    assert source |> table_rows() |> length() == length(GiveUp.audit()),
           "the audit table has a row that `audit/0` does not"
  end

  defp table_rows(source), do: Regex.scan(~r/^  \| `:[a-z_]+` \| \d+ \|/m, source)

  defp audit_message(found, audited) do
    """
    the resting-site audit (`Machine.GiveUp.audit/0`) does not match the sources.

    unclassified (add a row with this reason): #{inspect(unclassified(found, audited))}
    stale (no site passes this reason any more; delete the row): #{inspect(stale(found, audited))}
    site count changed (reason, audited, found): #{inspect(moved(found, audited))}
    """
  end

  defp unclassified(found, audited) do
    for {reason, n} <- found, not Map.has_key?(audited, reason), do: {reason, n}
  end

  defp stale(found, audited) do
    for {reason, n} <- audited, not Map.has_key?(found, reason), do: {reason, n}
  end

  defp moved(found, audited) do
    for {reason, n} <- found,
        Map.has_key?(audited, reason),
        audited[reason] != n,
        do: {reason, audited[reason], n}
  end

  test "every Handlers.route_for tag maps to a declared event or lifecycle tag" do
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

    assert :iterate in tags and :http_error in tags

    for tag <- tags do
      assert tag in Machine.events() or MapSet.member?(lifecycle, tag)
    end
  end

  defp route_tags do
    source = File.read!(@handlers)

    Regex.scan(~r/defp route_for\((.+?)\), do:/, source, capture: :all_but_first)
    |> Enum.map(fn [pattern] -> pattern |> Code.string_to_quoted!() |> event_tag_of() end)
    |> Enum.reject(&is_nil/1)
  end

  defp event_tag_of({:{}, _, [tag | _]}) when is_atom(tag), do: tag
  defp event_tag_of(tag) when is_atom(tag), do: tag
  defp event_tag_of(_), do: nil

  # --- source scan helpers ---

  defp sources do
    for path <- @sources, do: {path, ast_for(path)}
  end

  defp ast_for(path), do: path |> File.read!() |> Code.string_to_quoted!()

  # Every resting-phase write in `ast`: an `enter/3,4` call whose phase argument
  # is `:idle` or a blocked phase (piped or not), any `enter_blocked/2` call, and
  # the shapes that write the field without `enter/4` — a
  # `%{… | phase: <resting>}` struct update, `Map.put(m, :phase, <resting>)`,
  # `struct(m, phase: <resting>)` and `put_in(m.phase, <resting>)`.
  defp resting_writes(ast) do
    {_ast, writes} =
      Macro.prewalk(ast, [], fn node, acc -> {node, scan(node, acc, &resting_write/1)} end)

    Enum.reverse(writes)
  end

  defp resting_write({name, meta, args}) when name in [:enter, :enter_blocked] do
    write(name, meta, args)
  end

  defp resting_write({{:., _, [_mod, name]}, meta, args}) when name in [:enter, :enter_blocked] do
    write(name, meta, args)
  end

  defp resting_write({:|, meta, [_target, pairs]}) when is_list(pairs) do
    case Keyword.fetch(pairs, :phase) do
      {:ok, phase} ->
        if resting_phase?(phase), do: %{kind: "phase: #{inspect(phase)}", line: line(meta)}

      :error ->
        nil
    end
  end

  defp resting_write({{:., _, [{:__aliases__, _, [:Map]}, :put]}, meta, [_map, :phase, phase]}) do
    if resting_phase?(phase), do: %{kind: "Map.put phase: #{inspect(phase)}", line: line(meta)}
  end

  defp resting_write({:struct, meta, [_base, fields]}) when is_list(fields) do
    case Keyword.fetch(fields, :phase) do
      {:ok, phase} ->
        if resting_phase?(phase), do: %{kind: "struct phase: #{inspect(phase)}", line: line(meta)}

      :error ->
        nil
    end
  end

  defp resting_write({:put_in, meta, [key, phase]}) do
    if phase_field?(key) and resting_phase?(phase),
      do: %{kind: "put_in phase: #{inspect(phase)}", line: line(meta)}
  end

  defp resting_write(_node), do: nil

  # `m.phase` as a `put_in/2` key.
  defp phase_field?({{:., _, [_receiver, :phase]}, _, []}), do: true
  defp phase_field?(_node), do: false

  defp write(:enter_blocked, meta, _args),
    do: %{kind: "enter_blocked/2", line: line(meta)}

  # The phase is whichever argument *is* a resting phase: `Phase.enter/3,4`
  # takes `(machine, kind, phase, worker_kind)` and a pipe supplies the machine,
  # so the position differs between `Phase.enter(m, :chat, :idle)` and
  # `m |> Phase.enter(:chat, :idle)`. Neither `kind` nor `worker_kind` can be a
  # resting phase, so testing the arguments themselves is exact.
  defp write(:enter, meta, args) do
    case Enum.find(args, &resting_phase?/1) do
      nil -> nil
      phase -> %{kind: "enter/… #{inspect(phase)}", line: line(meta)}
    end
  end

  defp resting_phase?(:idle), do: true
  defp resting_phase?(phase), do: phase in Machine.blocked_phases()

  # Every `Phase.rest/4` / `Phase.block/4` call in `ast`, as
  # `%{line: line, reason: term}`. The reason is the call's third argument.
  defp funnel_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn node, acc -> {node, scan(node, acc, &funnel_call/1)} end)

    Enum.reverse(calls)
  end

  defp funnel_call({{:., _, [{:__aliases__, _, [:Phase]}, name]}, meta, args})
       when name in [:rest, :block] do
    %{line: line(meta), reason: Enum.at(args, 2)}
  end

  defp funnel_call(_node), do: nil

  defp scan(node, acc, fun) do
    case fun.(node) do
      nil -> acc
      found -> [found | acc]
    end
  end

  defp line(meta), do: Keyword.get(meta, :line, 0)

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

  defp user do
    {:user,
     %Nest.Messages.User{index: nil, parts: [%Nest.Messages.Part.Text{text: "hi"}], api_logs: []}}
  end

  defp sample_event(:chat_request), do: {:chat_request, {:user_message, elem(user(), 1)}}
  defp sample_event(:iterate), do: :iterate
  defp sample_event(:inbox_drain), do: {:inbox_drain, [], "queued"}
  defp sample_event(:http_ok), do: {:http_ok, make_ref(), %Nest.LLM.RunResponse{}}
  defp sample_event(:http_error), do: {:http_error, make_ref(), :boom}
  defp sample_event(:worker_crashed), do: {:worker_crashed, make_ref(), %RuntimeError{}, []}
  defp sample_event(:worker_down), do: {:worker_down, self(), :killed}
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
  defp sample_event(:compact_request), do: {:compact_request, nil}
  defp sample_event(:loop_ack), do: :loop_ack
  defp sample_event(:blocked), do: {:blocked, :needs_repair, nil}
  defp sample_event(:unblocked), do: {:unblocked}
  defp sample_event(:workspace_notice), do: :workspace_notice
  defp sample_event(:tool_results), do: {:tool_results, make_ref(), []}
  defp sample_event(:reply_sent), do: {:reply_sent, "peer"}
  defp sample_event(:child_spawned), do: {:child_spawned, "kid", false, nil}
  defp sample_event(:child_completed), do: {:child_completed, "kid", "resp", %{}}
  defp sample_event(:child_failed), do: {:child_failed, "kid", :crashed}
  defp sample_event(:child_terminated), do: {:child_terminated, "kid", :killed}
  defp sample_event(:abandon_child), do: {:abandon_child, "kid"}
end
