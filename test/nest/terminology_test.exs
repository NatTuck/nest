defmodule Nest.TerminologyTest do
  @moduledoc """
  Words this project has decided not to use, checked where the mistake lives.

  `AGENTS.md` says a `/tmp` path has no second form: agents see one consistent
  view of the world from inside their sandbox, so a path is a path. The banned
  word keeps creeping back as a way of saying *which form* of a path — the
  host's or the sandbox's — so it is banned in the modules that own paths. It
  survives elsewhere in its other senses ("one wording for every refusal", "the
  errno notations"), which is why the check is scoped by file rather than
  global.

  The banned word is built by concatenation so this file does not contain it. A
  guard that has to exempt itself is a guard that can be weakened by exempting
  one more file.
  """

  use ExUnit.Case, async: true

  alias Nest.Test.SourceScan

  @root Path.expand("../..", __DIR__)

  # The modules that own a path: the sandbox and its backends, the scratch dir,
  # the tools that name paths, and the offload that files a result into one.
  @scoped [
    "lib/nest/sandbox/**/*.ex",
    "lib/nest/agents/agent/tmp_space.ex",
    "lib/nest/tools/shell_cmd.ex",
    "lib/nest/tools/shell_cmd/**/*.ex",
    "lib/nest/tools/shell_cmd_tool.ex",
    "lib/nest/tools/shell_jobs.ex",
    "lib/nest/tools/inspect_file.ex",
    "lib/nest/tools/file_tools.ex",
    "lib/nest/agents/agent/batch_sizer/overflow.ex",
    "lib/nest/agents/agent/batch_sizer/projected_size.ex",
    "lib/nest/messages/part.ex",
    "test/nest/sandbox/**/*.exs",
    "test/nest/tools_scratch_path_test.exs",
    "test/nest/sandbox_path_domain_test.exs",
    "test/nest/agents/agent/tmp_space_test.exs"
  ]

  @banned [
    {"spel" <> "ling", "say which path: the sandbox path, the host path, the scratch path"}
  ]

  test "the path modules do not use a banned word" do
    files =
      @scoped
      |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
      |> Enum.uniq()

    # A broken glob must not pass vacuously: an empty list makes the assertion
    # below green.
    assert length(files) > 20

    offenders =
      SourceScan.flat_map(files, fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, number} ->
          for {word, _say} <- @banned, String.contains?(line, word) do
            {Path.relative_to(file, @root), number}
          end
        end)
      end)

    assert offenders == [],
           ~s|these lines use a banned word. A path has no "spel"+"ling" — say which one it is: | <>
             inspect(offenders)
  end
end
