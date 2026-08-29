defmodule Nest.Credo.Check.SourceFileMaxLines do
  @moduledoc """
  Flags source files that exceed the configured line limits.

  Two limits (defaults: `max_lines` 500 code lines, `max_total_lines`
  700 total lines):

    * **Code lines** — every line that is not blank, not a full-line
      `#` comment, and not a doc annotation (`@moduledoc` / `@doc` /
      `@typedoc`, including their `\"\"\"` heredoc bodies). Other
      multi-line strings (regular heredocs, multiline sigils) DO count.
    * **Total lines** — every line in the file (blanks, comments, docs,
      all included).

  Long files are hard to navigate and often indicate that a module has
  accumulated too many concerns. Split them up.

  The check is self-contained (no host-app module dependencies) because
  Credo loads custom checks in an isolated runtime context.
  """
  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    param_defaults: [max_lines: 500, max_total_lines: 700],
    explanations: [
      check: """
      Source files should not exceed the configured line limits.

      Long files are hard to navigate and often indicate that a
      module has accumulated too many concerns. Prefer splitting
      them into smaller, focused modules.
      """,
      params: [
        max_lines: "The maximum number of code lines a source file may have.",
        max_total_lines: "The maximum number of total lines a source file may have."
      ]
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    max_code = Params.get(params, :max_lines, 500)
    max_total = Params.get(params, :max_total_lines, 700)
    lines = (Credo.SourceFile.lines(source_file) || []) |> Enum.map(&elem(&1, 1))
    counts = count(lines)

    []
    |> maybe_issue(source_file, counts.code, max_code, :code)
    |> maybe_issue(source_file, counts.total, max_total, :total)
  end

  defp maybe_issue(issues, source_file, count, max, kind) do
    if count > max do
      [issue_for(source_file, count, max, kind) | issues]
    else
      issues
    end
  end

  defp issue_for(source_file, count, max, kind) do
    label = if kind == :code, do: "code lines", else: "total lines"

    format_issue(source_file,
      message: "Source file has #{count} #{label} (max: #{max})."
    )
  end

  @doc false
  def count(lines) do
    lines = drop_trailing_empty(lines)
    %{code: code_line_count(lines), total: length(lines)}
  end

  # A file that ends in a newline splits into a trailing empty element;
  # drop it so `total` matches editor/wc line counts.
  defp drop_trailing_empty(lines) do
    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  defp code_line_count(lines) do
    {count, _heredoc} =
      Enum.reduce(lines, {0, nil}, fn line, acc -> step_line(line, acc) end)

    count
  end

  defp step_line(line, {count, nil}) do
    cond do
      blank?(line) or comment?(line) -> {count, nil}
      doc_annotation?(line) -> open_doc(line, count)
      true -> open_string(line, count)
    end
  end

  defp step_line(line, {count, {kind, delim} = heredoc}) do
    closed = String.contains?(line, delim)
    add = if kind == :str, do: 1, else: 0
    {count + add, if(closed, do: nil, else: heredoc)}
  end

  defp open_doc(line, count) do
    case heredoc_opener(line) do
      nil -> {count, nil}
      delim -> {count, {:doc, delim}}
    end
  end

  defp open_string(line, count) do
    case heredoc_opener(line) do
      nil -> {count + 1, nil}
      delim -> {count + 1, {:str, delim}}
    end
  end

  defp blank?(line), do: String.trim(line) == ""

  defp comment?(line), do: String.starts_with?(String.trim_leading(line), "#")

  defp doc_annotation?(line) do
    t = String.trim_leading(line)

    Enum.any?(["@moduledoc", "@typedoc", "@doc"], fn attr ->
      t == attr or String.starts_with?(t, attr <> " ")
    end)
  end

  defp heredoc_opener(line) do
    cond do
      String.contains?(line, ~S(""")) -> ~S(""")
      String.contains?(line, ~S(''')) -> ~S(''')
      true -> nil
    end
  end
end
