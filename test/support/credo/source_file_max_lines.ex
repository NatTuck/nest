defmodule Nest.Credo.Check.SourceFileMaxLines do
  @moduledoc """
  Flags source files that exceed `max_lines` lines (default 500).

  Long files are hard to navigate and often indicate that a module
  has accumulated too many concerns. Split them up.
  """
  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    param_defaults: [max_lines: 500],
    explanations: [
      check: """
      Source files should not exceed the configured `max_lines`.

      Long files are hard to navigate and often indicate that a
      module has accumulated too many concerns. Prefer splitting
      them into smaller, focused modules.
      """,
      params: [
        max_lines: "The maximum number of lines a source file may have."
      ]
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    max_lines = Params.get(params, :max_lines, 500)
    line_count = line_count(source_file)

    if line_count > max_lines do
      [issue_for(source_file, line_count, max_lines)]
    else
      []
    end
  end

  defp line_count(%SourceFile{} = source_file) do
    case Credo.SourceFile.lines(source_file) do
      nil -> 0
      lines when is_list(lines) -> length(lines)
    end
  end

  defp issue_for(source_file, count, max) do
    format_issue(source_file,
      message: "Source file has #{count} lines (max: #{max})."
    )
  end
end
