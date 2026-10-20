defmodule Nest.Agents.Agent.BatchSizer.OverflowTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.BatchSizer.Overflow`.

  Pins the "never produce an empty result" rule. When there is no budget
  for any of the content (or the content itself is empty), `head_text/3`
  and `truncate_to_fit/3` return an explicit marker — never `""` — and
  `substitute/5` composes that marker with a pointer naming the scratch
  file, so a substituted result always says that content was elided and
  where the full text went.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.Sandbox
  alias Nest.Sandbox.Mounts
  alias Nest.Tokens.Estimator

  setup do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "nest-tmp-overflow-#{unique}")
    dir = Path.join([root, "space-1", "agent-#{unique}"])

    File.mkdir_p!(dir)

    on_exit(fn ->
      if String.contains?(root, "nest-tmp-overflow"), do: File.rm_rf!(root)
    end)

    {:ok, dir: dir}
  end

  test "head_text/3 and truncate_to_fit/3 never return an empty string" do
    marker = "[content elided: see /tmp/x.txt]"

    # No budget at all, a budget too small for even the first line, and
    # empty content: each returns the caller's elision marker verbatim
    # instead of "" (or a truncated head).
    assert Overflow.head_text("content", 0, marker) == marker
    assert Overflow.head_text("a line far too long for a 1-token budget", 1, marker) == marker
    assert Overflow.head_text("", 100, marker) == marker
    assert Overflow.truncate_to_fit("content", 0, marker) == marker

    # The one clause that does return content: leading whole lines, joined
    # and trailing-trimmed. The marker goes unused because every line fits,
    # so nothing was dropped.
    assert Overflow.head_text("first\nsecond\nthird\n", 100, "unused") ==
             "first\nsecond\nthird"
  end

  describe "substitute/5" do
    test "names the scratch file even when the budget leaves no room", %{dir: dir} do
      # A budget of `1` has room for neither the content nor even the header
      # line, so the result must be the marker naming the file rather than
      # "". (The `0` no-budget clause of `truncate_to_fit/3` is pinned by the
      # test above.)
      out =
        Overflow.substitute(
          "line one\nline two\n",
          %{mounts: Mounts.new(nil, dir)},
          "Command output",
          1,
          "exec"
        )

      assert out =~ "elided"
      assert out =~ Sandbox.sandbox_tmp_path(dir)
    end

    test "keeps the pointer and a head when there is room", %{dir: dir} do
      out =
        Overflow.substitute(
          String.duplicate("a line of content\n", 200),
          %{mounts: Mounts.new(nil, dir)},
          "Command output",
          200,
          "exec"
        )

      # The pointer is the sandbox spelling, never the host scratch dir, and
      # the body keeps a head of the content — all within the budget.
      assert out =~ Sandbox.sandbox_tmp_path(dir)
      refute out =~ dir
      assert out =~ "line of content"
      assert Estimator.estimate(out) <= 200
    end

    test "says so when no scratch file could be written" do
      out = Overflow.substitute("line one", %{}, "Command output", 0, "exec")

      assert out =~ "elided"
      assert out =~ "could not be written"
    end
  end
end
