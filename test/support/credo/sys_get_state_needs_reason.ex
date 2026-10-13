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
    3. **A read inside a polling predicate.** A `:sys.get_state` in the
       predicate argument of an `Eventually.eventually/2` call is an issue
       whatever markers surround it. The predicate must return a boolean; this
       call blocks for up to the GenServer's 5 s and *exits* on timeout, so the
       poll dies instead of returning `false` — the failure is an exit, not the
       assertion `eventually/2` promises. Only the predicate is the rule's
       subject: the options are evaluated once by the caller, so a read there is
       an ordinary call-site read (rule 1), not a poll.

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
  call twice for a difference the formatter erases.

  That is why the rule is "the marker shares the call's statement" and not "the
  marker is exactly one line above the call": a statement may span several
  lines, and the marker lands above its first one. It also means the marker's
  reach is bounded twice: nothing between the two lines may end a statement, and
  nothing may *open a block* on a line in between. A marker above a block header
  (`test "…" do`, `describe "…" do`, `def f(pid) do`) therefore excuses no read
  inside that block — it is a marker in the enclosing block, and a leftover one
  above a `test` must not silently excuse a new read inside it, which is exactly
  the case this check exists to catch. The one carve-out is a block that opens
  on the call's *own* line: a marker above a one-line
  `defp settle(socket), do: :sys.get_state(…)` stays valid, because the
  alternative — rewriting that definition as a multi-line `def` — is a code
  change, and a marker must never require one.

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
    * Rule 3 knows one helper: the bare `eventually(…)` this project's tests call
      (they `import Eventually`) and `Eventually.eventually(…)`. Another
      module's `Foo.eventually(…)` is not the poll helper, so its arguments are
      not scanned — matching any `.eventually` would flag an unrelated function
      that happens to share the name.
    * A predicate passed by name (`eventually(&waiting?/1)`) hides its read from
      rule 3, which sees only the source of the predicate argument.
    * **Two reads in one statement share one marker.** The marker's unit is the
      statement, so a marked `{:sys.get_state(a), :sys.get_state(b)}` needs one
      reason for two reads, and a third read added to that tuple passes. This is
      the price of the adjacency rule: a marker is a comment line, and the
      formatter gives a comment no position inside an expression to attach a
      reason to. A statement with several reads therefore deserves a reason that
      covers all of them.
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
    {ends, opens} = statement_bounds(ast)
    markers = marker_lines(comments)

    excusals = excusals(markers, ends, opens, MapSet.difference(calls, polls))

    (unmarked(excusals) ++ stale(markers, excusals) ++ poll_findings(polls))
    |> Enum.sort_by(fn {kind, line} -> {line, Map.fetch!(@kind_order, kind)} end)
  end

  # Call line => every marker that excuses it (empty when none does).
  defp excusals(markers, ends, opens, calls) do
    for line <- calls, into: %{}, do: {line, excusing_markers(markers, ends, opens, line)}
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
  # calls written inside an `eventually(...)` predicate.
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
    case poll_predicate(node) do
      nil -> {node, polls}
      predicate -> {node, MapSet.union(polls, get_state_lines(predicate))}
    end
  end

  # The predicate is the first argument. The options are evaluated once by the
  # caller, so a read there is an ordinary call-site read, not a poll. A bare
  # `eventually(…)` is this project's helper (the tests `import Eventually`);
  # another module's `Foo.eventually(…)` is not, so it is not scanned.
  defp poll_predicate({:eventually, _meta, [predicate | _]}), do: predicate

  defp poll_predicate(
         {{:., _, [{:__aliases__, _, [:Eventually]}, :eventually]}, _meta, [pred | _]}
       ) do
    pred
  end

  defp poll_predicate(_node), do: nil

  # Where statements end (`end_of_expression`) and where block bodies open
  # (`:do`, or an `fn`), both of which need `token_metadata: true`.
  defp statement_bounds(ast) do
    {_ast, {ends, opens}} =
      Macro.prewalk(ast, {MapSet.new(), MapSet.new()}, fn
        node, {ends, opens}
        when is_tuple(node) and tuple_size(node) == 3 and is_list(elem(node, 1)) ->
          meta = elem(node, 1)
          {node, {add_statement_end(ends, meta), add_block_open(opens, node, meta)}}

        node, acc ->
          {node, acc}
      end)

    {ends, opens}
  end

  defp add_statement_end(ends, meta) do
    case Keyword.get(meta, :end_of_expression) do
      nil -> ends
      end_meta -> MapSet.put(ends, Keyword.fetch!(end_meta, :line))
    end
  end

  defp add_block_open(opens, node, meta) do
    case block_open_line(node, meta) do
      nil -> opens
      line -> MapSet.put(opens, line)
    end
  end

  defp block_open_line({:fn, meta, _clauses}, _meta), do: meta[:line]

  defp block_open_line(_node, meta) do
    case Keyword.get(meta, :do) do
      nil -> nil
      do_meta -> Keyword.fetch!(do_meta, :line)
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
  # statement ending and no block opening in between.
  defp excusing_markers(markers, ends, opens, call_line) do
    markers
    |> Enum.filter(&(&1 <= call_line))
    |> Enum.reject(&crosses?(ends, opens, &1, call_line))
  end

  # A marker excuses a call only within its own statement: nothing between the
  # two lines may end a statement, and nothing may open a block on a line in
  # between. A marker above a block header (`test … do`, `describe … do`,
  # `def f(pid) do`) sits in the enclosing block, so it must not excuse a read
  # inside the block. A block that opens on the call's own line is not "in
  # between", which is what keeps a marker above a one-line
  # `defp settle(socket), do: :sys.get_state(…)` valid — the alternative would be
  # a code change, and a marker must not require one.
  defp crosses?(ends, opens, from_line, to_line) do
    ends_between?(ends, from_line, to_line) or opens_between?(opens, from_line, to_line)
  end

  defp ends_between?(_ends, from_line, to_line) when from_line >= to_line, do: false

  defp ends_between?(ends, from_line, to_line) do
    Enum.any?(from_line..(to_line - 1), &MapSet.member?(ends, &1))
  end

  defp opens_between?(_opens, from_line, to_line) when from_line + 1 >= to_line, do: false

  defp opens_between?(opens, from_line, to_line) do
    Enum.any?((from_line + 1)..(to_line - 1), &MapSet.member?(opens, &1))
  end

  defp issue_for(source_file, {kind, line}) do
    format_issue(source_file, message: Map.fetch!(@messages, kind), line_no: line)
  end
end
