defmodule Nest.Credo.Check.SysGetStateNeedsReason do
  @moduledoc """
  Flags an unexplained `:sys.get_state` in a test.

  Issue #21 removed wall-clock-as-synchronisation from the test suite — the
  drain loops, the idle polls, the barriers and the accessor reads. The drain
  half is guarded by `Nest.Credo.Check.NoDrainLoops`; this is the
  `:sys.get_state` half. It has regrown twice already (five sites in one commit,
  then 291 grep hits) and every cleanup before this check needed a human to
  notice, so the rule is enforced rather than remembered.

  ## What fails

    1. **A call with no reason.** Every `:sys.get_state` call in `test/` must
       carry a marker: a comment whose text is `# allowlist: ` followed by a
       reason, in the comments above the statement the call is part of.
       `notes/sys-get-state-audit.md` §5 records the reasons for the 48 kept
       sites, and `notes/issue-21-sysstate-final.md` records the 59 kept because
       no single accessor returns every field they read.
    2. **A marker that excuses nothing.** The reason has to live next to the
       code it excuses, so a marker that excuses no call — the call it was
       written for is gone, or another statement now sits between them — is an
       issue.
    3. **A read inside a polling predicate.** A `:sys.get_state` anywhere in an
       `Eventually.eventually/2` call's arguments is an issue whatever markers
       surround it. The predicate must return a boolean; this call blocks for up
       to the GenServer's 5 s and *exits* on timeout, so the poll dies instead of
       returning `false` — the failure is an exit, not the assertion
       `eventually/2` promises.

  ## Why a comment, and not a `file:line` allowlist

  A list of line numbers was the obvious alternative and is the wrong one: lines
  move, and all three review rounds of the audit found the previous list's
  numbers stale within days of being written. A comment travels with the call it
  excuses, and it forces the reason to live next to the code — which is the
  point. In the tree this check ships with, every marker sits on the line above
  its call's statement:

      # allowlist: harness — Turn.build_ctx/1's argument
      ctx = Turn.build_ctx(:sys.get_state(pid, 1_000))

      # allowlist: snapshot — messages + status
      pre =
        :sys.get_state(pid, 1_000)
        |> Map.fetch!(:status)

  A marker is accepted on the call's own line too. The Elixir formatter
  normalises a trailing comment onto its own line above the statement — writing
  `state = :sys.get_state(pid) # allowlist: …` and running `mix format` leaves
  the marker where the first example has it — so the two positions are the same
  site at different moments, and rejecting one of them would report the same
  call twice for a difference the formatter erases. That is also why the rule is
  "the marker shares the call's statement" and not "the marker is exactly one
  line above the call": a statement may span several lines, and the marker lands
  above its first one.

  What the check enforces is *that* a reason exists and sits next to the call.
  It cannot judge whether the reason is true — that is what review is for, and a
  lint that pretended otherwise would be worse than none. The reasons follow the
  audit's families, one per marker:

    * `harness` — the struct is the argument to a pure function under test
      (`Turn.build_ctx/1`, `Machine.step/2`, the `Agent.Timeline` emitters, …),
      so no accessor can serve the call;
    * `snapshot` — the site reads two or more field families from one atomic
      snapshot, and no single accessor returns all of them;
    * `barrier` — the read is a happens-after anchor for a `refute_*` or a
      0-timeout assertion, and the handler it orders broadcasts nothing;
    * `registry` — `Nest.Agents.Registry`'s per-name cleanup announces nothing,
      so the partition read is the only ordering primitive (measured: ~27% of
      exits are still in the table right after the caller's `:DOWN`);
    * `dev-only` — `NestWeb.SurgicalReloader` is dev-only tooling with no
      introspection API;
    * `fixture` — the read half of a `:sys.replace_state` fixture against the
      process-global `Nest.Models` singleton.

  ## Scope: `test/`, and why `lib/` is out

  The check runs on files under `test/`, `test/support/` included: those helpers
  are test infrastructure and carry the same defect. Production code is *not* in
  scope, and the two `lib/` call sites are the reason to say so out loud rather
  than leave it implicit:

    * `lib/nest/agents/agent/turn/give_up_delivery.ex:75` reads a child's owed
      senders before stopping it — a bounded synchronous read of another
      process's state, taken deliberately. The pattern #21 removed was a
      *round-trip used as synchronisation*, and that is a test-suite defect;
    * `lib/nest/agents/agent/turn/http_worker.ex:98` is the one production site
      genuinely in the defect family, and the audit's §7 says it should be
      *replaced* (a non-blocking mailbox check), not allowlisted.

  A marker records a reason a *test* may read another process's state.
  Production code has no such allowlist: its question is "should this read
  exist, and what should its bound be", which a comment cannot answer and a lint
  cannot decide. That is a separate check with separate semantics — see
  `notes/wallclock-audit.md` design decisions 4 and 5 — and marking those sites
  here would launder an open design question into a comment.

  ## Coverage, and what "fail loud" can actually reach

  Credo analyses what `.credo.exs`'s `files.included` lists, so this check sees
  every `test/**/*.{ex,exs}`. Through `mix credo` a file that cannot be parsed
  never reaches a check: Credo validates its source files first and hands checks
  only the `:valid` ones, and `Credo.Check.do_run_on_source_file/3` rescues a
  check's raise unless `crash_on_error` is set. `findings/2`'s raise is
  therefore belt-and-braces for a direct caller — but unlike `NoDrainLoops`'
  equivalent it is reachable, and reached: this check's own test walks every file
  under `test/` and parses it, so an unparseable file fails the suite loudly, and
  one test drives the raise directly.

  The check parses each in-scope source a second time. Credo's `SourceFile`
  carries the AST but not the comments, and the marker *is* a comment; the
  re-parse is `test/`-only, on files Credo has already parsed, and costs ~0.2 s
  over the whole suite.

  ## Blind spots

  The limits of a source-level Credo check, stated so they are not mistaken for
  coverage:

    * `apply(:sys, :get_state, [pid])` is invisible, and so is an alias that
      renames the module (`alias :sys, as: S`). Both are contrived; the rule
      matches the literal `:sys.get_state` remote call, and a call is a node with
      an argument list (`&:sys.get_state/1` parses as the same node with none,
      and is not a call).
    * A predicate passed by name (`eventually(&waiting?/1)`) hides its read from
      rule 3, which sees only what is written inside the call's own arguments.
    * Rule 3 names `:sys.get_state`, not every blocking call: an accessor
      (`Agent.get_public_info/2`) in a predicate blocks and exits in exactly the
      same way. Catching that needs a different rule — "a predicate must not
      block on the process it polls" — and the accessor is the sanctioned
      primitive everywhere else, so this check deliberately does not guess at
      it.
    * `:sys.replace_state` mutates rather than reads and is a different question,
      out of scope here; the three `models_test.exs` fixture sites are marked as
      the reads they are.
  """
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      An unexplained `:sys.get_state` in a test.

      Wait on the event that decides the outcome, or use the accessor that
      serves the read (`Agent.get_public_info/2`, `Agent.get_messages/2`, …).
      Where neither can serve it, put the reason in the comments above the
      statement the call is part of:

          # allowlist: <reason>
          state = :sys.get_state(pid, 1_000)

      See `notes/sys-get-state-audit.md` for the audited sites and the families
      their reasons come from.
      """
    ]

  @marker ~r/\A#\s*allowlist:\s*\S/

  @messages %{
    unmarked:
      "`:sys.get_state` in a test needs a written reason: put `# allowlist: <reason>` in the " <>
        "comments above the statement this call is part of, saying why the read cannot be an " <>
        "accessor call or an event wait. See notes/sys-get-state-audit.md.",
    stale_marker:
      "This `# allowlist:` marker excuses no `:sys.get_state` call: no call at or below it " <>
        "shares its statement. Delete it, or move it next to the call it excuses.",
    poll_predicate:
      "`:sys.get_state` inside an `eventually` predicate: the predicate must return a boolean, " <>
        "but this read blocks (and exits on timeout), so the poll dies instead of returning " <>
        "false. Wait on the event, or poll something that cannot block."
  }

  @typedoc "What is wrong, and the line it is wrong on."
  @type finding :: {:unmarked | :stale_marker | :poll_predicate, pos_integer()}

  # So two findings on one line come out in a fixed order, whatever the sort
  # does with equal keys.
  @kind_order %{unmarked: 0, stale_marker: 1, poll_predicate: 2}

  @doc false
  def run(%SourceFile{filename: filename} = source_file, _params) do
    if in_scope?(filename) do
      source_file
      |> SourceFile.source()
      |> findings(filename)
      |> Enum.map(&issue_for(source_file, &1))
    else
      []
    end
  end

  @doc """
  Whether `filename` is in scope: files under `test/`, and nothing else.

  Public so the check's own test can pin the scope decision, `lib/` half
  included.
  """
  @spec in_scope?(String.t()) :: boolean()
  def in_scope?("test/" <> _), do: true
  def in_scope?(_), do: false

  @doc """
  Every finding in `source`, as `{kind, line}` pairs sorted by line.

  Public so the check's own test can drive it with source text instead of a
  `SourceFile`, and so the project-wide test can walk the real tree.
  """
  @spec findings(String.t(), String.t()) :: [finding()]
  def findings(source, filename \\ "nofilename") do
    {ast, comments} = parse!(source, filename)
    {calls, polls} = scan(ast)
    markers = marker_lines(comments)
    boundaries = statement_end_lines(ast)

    excusals = excusals(markers, boundaries, MapSet.difference(calls, polls))

    (unmarked(excusals) ++ stale(markers, excusals) ++ poll_findings(polls))
    |> Enum.sort_by(fn {kind, line} -> {line, Map.fetch!(@kind_order, kind)} end)
  end

  # Call line => every marker that excuses it (empty when none does).
  defp excusals(markers, boundaries, calls) do
    for line <- calls, into: %{}, do: {line, excusing_markers(markers, boundaries, line)}
  end

  defp unmarked(excusals), do: for({line, []} <- excusals, do: {:unmarked, line})

  defp stale(markers, excusals) do
    used = excusals |> Map.values() |> List.flatten() |> MapSet.new()

    for marker <- markers, not MapSet.member?(used, marker), do: {:stale_marker, marker}
  end

  defp poll_findings(polls), do: for(line <- polls, do: {:poll_predicate, line})

  defp parse!(source, filename) do
    options = [emit_warnings: false, token_metadata: true]

    case Code.string_to_quoted_with_comments(source, options) do
      {:ok, ast, comments} ->
        {ast, comments}

      {:error, error} ->
        raise "SysGetStateNeedsReason could not parse #{filename}: #{inspect(error)}"
    end
  end

  # One walk each: the line of every `:sys.get_state` call, and the lines of the
  # calls written inside an `eventually(...)` argument.
  defp scan(ast), do: {get_state_lines(ast), poll_lines(ast)}

  # A call always has an argument list; `&:sys.get_state/1` parses as the same
  # remote node with none, and a mention in prose is not a call at all.
  defp get_state_lines(ast) do
    {_ast, lines} = Macro.prewalk(ast, MapSet.new(), &collect_get_state_line/2)
    lines
  end

  defp collect_get_state_line({{:., _, [:sys, :get_state]}, meta, [_ | _]} = node, lines) do
    {node, MapSet.put(lines, meta[:line])}
  end

  defp collect_get_state_line(node, lines), do: {node, lines}

  # A predicate that reads state blocks, and exits on timeout, instead of
  # returning `false` — so the poll dies rather than failing its assertion.
  defp poll_lines(ast) do
    {_ast, polls} = Macro.prewalk(ast, MapSet.new(), &collect_poll_lines/2)
    polls
  end

  defp collect_poll_lines(node, polls) do
    case eventually_args(node) do
      nil -> {node, polls}
      args -> {node, MapSet.union(polls, get_state_lines(args))}
    end
  end

  defp eventually_args({name, _meta, args}) when name == :eventually and is_list(args), do: args
  defp eventually_args({{:., _, [_module, :eventually]}, _meta, args}), do: args
  defp eventually_args(_node), do: nil

  # The last line of every statement (`end_of_expression` metadata, which needs
  # `token_metadata: true`). Two calls are in the same statement exactly when no
  # line in between is one of these.
  defp statement_end_lines(ast) do
    {_ast, lines} =
      Macro.prewalk(ast, MapSet.new(), fn
        node, lines when is_tuple(node) and tuple_size(node) == 3 and is_list(elem(node, 1)) ->
          {node, add_statement_end(lines, elem(node, 1))}

        node, lines ->
          {node, lines}
      end)

    lines
  end

  defp add_statement_end(lines, meta) do
    case Keyword.get(meta, :end_of_expression) do
      nil -> lines
      end_meta -> MapSet.put(lines, Keyword.fetch!(end_meta, :line))
    end
  end

  # The marker is a comment, so the reasons come from the comment list rather
  # than from the line text: a `# allowlist:` inside a string is a string.
  defp marker_lines(comments) do
    for %{line: line, text: text} <- comments,
        Regex.match?(@marker, text),
        into: MapSet.new(),
        do: line
  end

  # Every marker that excuses a call on `call_line`: at or above it, with no
  # statement ending in between. The formatter puts a trailing marker on the
  # line above its statement, so this is where a marker lands either way.
  defp excusing_markers(markers, boundaries, call_line) do
    markers
    |> Enum.filter(&(&1 <= call_line))
    |> Enum.reject(&boundary_between?(boundaries, &1, call_line))
  end

  defp boundary_between?(_boundaries, marker_line, call_line) when marker_line >= call_line do
    false
  end

  defp boundary_between?(boundaries, marker_line, call_line) do
    Enum.any?(marker_line..(call_line - 1), &MapSet.member?(boundaries, &1))
  end

  defp issue_for(source_file, {kind, line}) do
    format_issue(source_file, message: Map.fetch!(@messages, kind), line_no: line)
  end
end
