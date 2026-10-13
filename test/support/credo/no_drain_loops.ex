defmodule Nest.Credo.Check.NoDrainLoops do
  @moduledoc """
  Flags drain loops: a `receive` with a catch-all clause whose body leads back
  into a receive.

  A catch-all clause (a bare variable or `_`) matches whatever is at the mailbox
  head, so a `receive` carrying one is no longer selective: the clause discards
  the non-matching message and the loop re-`receive`s. That is a drain loop, and
  the loop is driven by the mismatch itself.

  The rule is deliberately narrow. A catch-all is **not** a drain loop on its
  own:

    * `receive do msg -> handle(msg) after 0 -> :none end` is the legitimate
      non-blocking idiom — one clause that takes whatever has arrived;
    * a single-clause receive with an explicit pattern (`receive do
      {:stop_chat, from} -> … after 0 -> … end`) is selective.

  So the check fires only when a catch-all clause's body leads back into a
  `receive`: a self-recursive call to the function that lexically encloses the
  `receive`, or a nested `receive`.

  ## Coverage

  The check runs on every file Credo analyses, which is what `.credo.exs`'s
  `files.included` lists — `lib/`, `test/`, `web/`, `src/` and their `apps/*/`
  equivalents. `scripts/`, `config/`, `priv/` and `mix.exs` are outside Credo's
  scope, so no Credo check sees them. Adding them to `files.included` would run
  *every* check over those trees, and they currently carry 33 pre-existing Credo
  issues (including an ABC-size failure in `scripts/`), so that is a project-wide
  linting decision rather than one this check can make on its own.

  Those trees are covered instead by this check's project-wide test
  (`test/nest/credo/no_drain_loops_test.exs`), which walks every `.ex`/`.exs`
  in the repo and runs `drain_loops/1` over each one. Between the two, the rule
  is enforced everywhere — and the test raises on a file it cannot parse rather
  than skipping it.

  ## Blind spot

  Source-level `receive` nodes only. A drain loop produced by a macro expansion
  (the `receive` never appears in the source) is invisible to a source-based
  check — the same limit every Credo check has.
  """
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Do not drain the mailbox: a `receive` whose catch-all clause discards the
      non-match and re-receives.

      Wait on the specific event you want, or make the receive selective — the
      runtime skips non-matching messages for a receive with only explicit
      clauses, so nothing has to be discarded by hand.
      """
    ]

  @doc false
  def run(%SourceFile{} = source_file, _params) do
    case Credo.Code.ast(source_file) do
      {:ok, ast} ->
        ast
        |> drain_loops()
        |> Enum.map(&issue_for(source_file, &1))

      {:error, error} ->
        # A gate must not silently skip a file it cannot read. Credo's own
        # syntax-error reporting is a separate concern; failing here keeps this
        # check from reporting "clean" for a file it never actually analysed.
        raise "NoDrainLoops could not parse #{source_file.filename}: #{inspect(error)}"
    end
  end

  @doc """
  The line number of every drain loop in `ast`. Public so the check's own test
  can exercise it against parsed source without a `SourceFile`.
  """
  @spec drain_loops(Macro.t()) :: [pos_integer()]
  def drain_loops(ast) do
    {_ast, lines} = walk(ast, nil, [])
    Enum.reverse(lines)
  end

  # Carry the name of the lexically enclosing function so a catch-all's body can
  # be tested for a self-recursive call to it.
  defp walk({kind, _meta, [head, body]} = node, _fun, acc) when kind in [:def, :defp] do
    {_body, acc} = walk(body, def_name(head), acc)
    {node, acc}
  end

  defp walk({:receive, meta, [args]} = node, fun, acc) do
    clauses = args |> Keyword.get(:do, []) |> List.wrap()

    acc =
      if Enum.any?(clauses, &drain_clause?(&1, fun)), do: [meta[:line] | acc], else: acc

    {_args, acc} = walk(args, fun, acc)
    {node, acc}
  end

  # Everything else: recurse into every child, keeping the enclosing name.
  defp walk(node, fun, acc) when is_tuple(node) do
    {_children, acc} =
      node
      |> Tuple.to_list()
      |> Enum.reduce({node, acc}, fn child, {_n, a} -> walk(child, fun, a) end)

    {node, acc}
  end

  defp walk(list, fun, acc) when is_list(list) do
    {_children, acc} =
      Enum.reduce(list, {list, acc}, fn child, {_n, a} -> walk(child, fun, a) end)

    {list, acc}
  end

  defp walk(node, _fun, acc), do: {node, acc}

  # A catch-all clause whose body leads back into a receive.
  defp drain_clause?({:->, _meta, [patterns, body]}, fun) do
    catchall?(patterns) and leads_back?(body, fun)
  end

  defp drain_clause?(_other, _fun), do: false

  # A catch-all pattern list is a single bare variable or `_`: `{:x, _, nil}` /
  # `{:_other, _, nil}` are variables, a call has a list of args there, a tuple
  # is `{:{}, _, _}`, and a literal is not a 3-tuple.
  defp catchall?([{:_, _, _}]), do: true
  defp catchall?([{name, _, ctx}]) when is_atom(name) and is_atom(ctx), do: true
  defp catchall?(_patterns), do: false

  # "Leads back into a receive": a nested `receive`, or a local call to the
  # function that encloses this receive (the recursion that re-enters the loop).
  defp leads_back?(body, fun) do
    {_body, found} =
      Macro.prewalk(body, false, fn
        {:receive, _meta, _args} = node, _acc ->
          {node, true}

        {name, _meta, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, acc or (fun != nil and name == fun)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp def_name({name, _meta, _args}) when is_atom(name), do: name
  defp def_name(_head), do: nil

  defp issue_for(source_file, line) do
    format_issue(source_file,
      message:
        "Drain loop: a `receive` catch-all that re-receives. Wait on the specific " <>
          "event, or make the receive selective (only explicit clauses).",
      line_no: line
    )
  end
end
