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
  alias Nest.Tokens.Estimator

  setup do
    dir = Path.join(System.tmp_dir!(), "nest-tmp-overflow-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    on_exit(fn ->
      if String.contains?(dir, "nest-tmp-overflow"), do: File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  describe "no-budget paths" do
    test "head_text/3 and truncate_to_fit/3 return the caller's marker, never empty" do
      # No budget at all, a budget too small for even the first line, and
      # empty content: each returns the caller's elision marker verbatim
      # instead of "" (or a truncated head).
      marker = "[content elided: see /tmp/x.txt]"

      assert Overflow.head_text("content", 0, marker) == marker
      assert Overflow.head_text("a line far too long for a 1-token budget", 1, marker) == marker
      assert Overflow.head_text("", 100, marker) == marker
      assert Overflow.truncate_to_fit("content", 0, marker) == marker
    end

    test "head_text/3 returns the leading whole lines that fit the budget" do
      # The marker goes unused here: every line fits, so nothing is dropped.
      assert Overflow.head_text("first\nsecond\nthird\n", 100, "unused") ==
               "first\nsecond\nthird"
    end
  end

  describe "substitute/5" do
    test "names the scratch file even when the budget leaves no room", %{dir: dir} do
      content = "line one\nline two\n"
      ctx = %{tmp_path: dir}

      # `0` hits the no-budget clause; `1` has a budget but can't fit even
      # the pointer line. Both must name the file rather than return "".
      for budget <- [0, 1] do
        out = Overflow.substitute(content, ctx, "Command output", budget, "exec")

        assert out =~ "elided"
        assert out =~ dir
        assert String.valid?(out)
      end
    end

    test "keeps the pointer and a head when there is room", %{dir: dir} do
      out =
        Overflow.substitute(
          String.duplicate("a line of content\n", 200),
          %{tmp_path: dir},
          "Command output",
          200,
          "exec"
        )

      assert out =~ "saved to"
      assert out =~ dir
      assert out =~ "line of content"
      assert Estimator.estimate(out) <= 200
    end

    test "says so when no scratch file could be written" do
      out = Overflow.substitute("line one", %{}, "Command output", 0, "exec")

      assert out =~ "elided"
      assert out =~ "could not be written"
      refute out =~ "saved to"
    end
  end
end
