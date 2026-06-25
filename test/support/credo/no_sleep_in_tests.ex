defmodule Nest.Credo.Check.NoSleepInTests do
  @moduledoc """
  Flags any `Process.sleep/1` or `:timer.sleep/1` call in test files.

  Polling with sleeps is racy and slow. Tests should use
  `assert_receive/2`, `refute_receive/2`, or a dedicated event-based
  waiting helper. Process.sleep is a code smell in a test suite.

  Applies only to files under the top-level `test/` directory. Production
  code in `lib/` is exempt — long-running workers may legitimately need
  to sleep. The `lib/nest/test/` directory contains test-mode
  infrastructure, but it's not under the test runner and is exempt.

  Exempted: `test/support/eventually.ex` (the `eventually/2` macro is
  a general polling primitive used by a small number of tests that
  wait for state changes which have no PubSub event).
  """
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Tests must not use `Process.sleep/1` or `:timer.sleep/1`.

      Use `assert_receive/2`, `refute_receive/2`, or an event-based
      waiting helper instead. Polling with sleeps is racy (the timing
      assumption is fragile) and slow (every test that uses it
      contributes a fixed delay to the suite's wall time).
      """
    ]

  @doc false
  def run(%SourceFile{filename: filename} = source_file, _params) do
    if test_file?(filename) and not exempted?(filename) do
      case Credo.Code.ast(source_file) do
        {:ok, ast} ->
          ast
          |> find_sleep_calls()
          |> Enum.map(&issue_for(source_file, &1))

        _ ->
          []
      end
    else
      []
    end
  end

  # The `filename` is the path relative to the project root. Test
  # files start with `test/`. Files in `lib/nest/test/` are test-mode
  # infrastructure but not under the test runner — exempt.
  defp test_file?("test/" <> _), do: true
  defp test_file?(_), do: false

  # The `eventually/2` macro is the only sanctioned polling primitive
  # in the test suite — it's used by tests that wait for state changes
  # with no corresponding PubSub event. See `notes/eventually.md` (TODO)
  # for the full rationale.
  defp exempted?("test/support/eventually.ex"), do: true
  defp exempted?(_), do: false

  # Walk the AST collecting the line of every `Process.sleep/1` or
  # `:timer.sleep/1` call. The remote-call shape can be either:
  #   {{:., _, [:Process, :sleep]}, meta, [_arg]}              # :Process as atom
  #   {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, meta, [_arg]}  # Process as alias
  #   {{:., _, [:timer, :sleep]}, meta, [_arg]}                # :timer as atom
  defp find_sleep_calls(ast) do
    {_ast, lines} =
      Macro.prewalk(
        ast,
        [],
        fn
          node = {{:., _, [module, :sleep]}, meta, [_arg]}, acc ->
            if sleep_module?(module), do: {node, [meta[:line] | acc]}, else: {node, acc}

          node, acc ->
            {node, acc}
        end
      )

    Enum.reverse(lines)
  end

  # `Process` may be a literal atom `:Process` (already-expanded AST)
  # or a `{:__aliases__, _, [:Process]}` tuple (parsed source).
  defp sleep_module?(:Process), do: true
  defp sleep_module?(:timer), do: true
  defp sleep_module?({:__aliases__, _, [:Process]}), do: true
  defp sleep_module?(_), do: false

  defp issue_for(source_file, line) do
    format_issue(source_file,
      message:
        "Process.sleep/1 is forbidden in tests (use assert_receive / refute_receive instead).",
      line_no: line
    )
  end
end
