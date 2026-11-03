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

    test "labels a cut preview with the lines it shows and the lines there are", %{dir: dir} do
      # 300 lines of ~81 tokens each. The head budget is ~192 tokens (4× the
      # header), so two lines fit and the third cannot: the counts below are
      # stable whatever the scratch file's random name does to the header's
      # estimate (measured over 50 names: 184..216 tokens of head budget, and
      # 2 lines = 162, 3 = 243).
      content = long_content(300)

      out =
        Overflow.substitute(
          content,
          %{mounts: Mounts.new(nil, dir)},
          "Command output of 'mix test'",
          100_000,
          "exec"
        )

      [header, body] = String.split(out, "\n\n")
      [path] = Regex.run(~r{/tmp/[^\s]+\.txt}, header)

      # The shipped words, with the exact counts. A short preview that says
      # nothing about the other 298 lines is what this fixes.
      assert header ==
               "Command output of 'mix test' (#{Estimator.estimate(content)} tokens) " <>
                 "saved to #{path}. Below: first 2 of 300 lines."

      # And the count is the body's own: two whole lines, the first two of the
      # content.
      assert body == long_line(1) <> "\n" <> long_line(2)
    end

    test "leaves a preview that fits entirely unlabelled", %{dir: dir} do
      # The blank-tail shape is the one that can catch a wrong condition: a
      # trailing newline ends the last line for `line_count/1`, while
      # `head_text/3` trims the body's trailing newlines, so a condition on the
      # counts alone (`shown < total`) labels content whose only "cut" is
      # trailing whitespace. The three-line shape alone cannot see that.
      for content <- ["one\ntwo\nthree\n", "one\ntwo\nthree\n\n", "one\ntwo\nthree\n\n\n"] do
        out =
          Overflow.substitute(
            content,
            %{mounts: Mounts.new(nil, dir)},
            "Command output",
            100_000,
            "exec"
          )

        # Nothing was cut, so nothing is claimed — and the result gains no tokens
        # for a clause it does not need.
        refute out =~ "Below:", "#{inspect(content)} was labelled"
        assert String.split(out, "\n\n") |> List.last() == String.trim_trailing(content)
      end
    end

    test "the no-room case is the marker, with no clause", %{dir: dir} do
      # One line far bigger than the head budget: nothing fits below the header,
      # so the body is the elision marker. There is no clause because there are
      # no preview lines to count — "first 0 of 1 lines" would attach a count to
      # a body that is not a preview, and the marker already says the content was
      # elided and where it is.
      out =
        Overflow.substitute(
          String.duplicate("x", 5_000),
          %{mounts: Mounts.new(nil, dir)},
          "Command output",
          100_000,
          "exec"
        )

      refute out =~ "Below:"
      assert out =~ "content elided"
      assert out =~ Sandbox.sandbox_tmp_path(dir)

      # A budget too small for anything at all is the marker alone, still
      # unlabelled.
      tiny =
        Overflow.substitute(
          String.duplicate("x", 5_000),
          %{mounts: Mounts.new(nil, dir)},
          "Command output",
          1,
          "exec"
        )

      [tiny_path] = Regex.run(~r{/tmp/[^\s]+\.txt}, tiny)
      assert tiny == "[content elided: see #{tiny_path}]"
    end

    test "the clause fits every budget that can hold the result at all", %{dir: dir} do
      # The clause is part of the header line, so its cost is reserved before the
      # preview is sized: it is never the thing that pushes a result over. The
      # floor is the marker itself — a budget below the marker's own cost cannot
      # hold any result, and the "never an empty result" rule wins there (which
      # the existing budget-1 test pins).
      content = long_content(300)

      for budget <- [60, 80, 100, 150, 200, 300, 500, 1_000, 2_000, 5_000, 20_000] do
        out =
          Overflow.substitute(
            content,
            %{mounts: Mounts.new(nil, dir)},
            "Command output",
            budget,
            "exec"
          )

        assert Estimator.estimate(out) <= budget,
               "budget #{budget} overflowed (#{Estimator.estimate(out)}): #{inspect(out)}"

        # Whatever the budget leaves, the label describes what is there.
        case Regex.run(~r/Below: first (\d+) of 300 lines/, out) do
          [_, shown] ->
            body = out |> String.split("\n\n") |> List.last()
            assert length(String.split(body, "\n")) == String.to_integer(shown)

          nil ->
            # No label, and exactly three shapes, each asserted whole: the marker
            # alone (not even the header fits), the header alone (the header fits
            # and the marker does not), or the header and the marker (both fit,
            # no preview line does). All three name the file; none claims a
            # count. (An `out =~ path` assertion here would pass for all three
            # and so distinguish nothing.)
            [path] = Regex.run(~r{/tmp/[^\s]+\.txt}, out)
            saved = "Command output (#{Estimator.estimate(content)} tokens) saved to #{path}."

            assert out in [
                     "[content elided: see #{path}]",
                     saved,
                     saved <> "\n\n[content elided: see #{path}]"
                   ]
        end
      end

      # Below the marker's own cost the "never an empty result" rule wins: the
      # marker is returned even though it does not fit, which is the one place
      # the budget bound cannot hold (and is pre-existing — the budget-1 test
      # above pins it).
      sub_marker =
        Overflow.substitute(
          content,
          %{mounts: Mounts.new(nil, dir)},
          "Command output",
          1,
          "exec"
        )

      assert sub_marker =~ "content elided"
      refute sub_marker =~ "Below:"
    end
  end

  # 300 lines of ~81 tokens each: big enough that the head budget's few-token
  # jitter (the scratch file's random name) cannot change how many fit.
  defp long_content(count), do: Enum.map_join(1..count, "\n", &long_line/1) <> "\n"

  defp long_line(n) do
    "line #{n}: " <>
      String.trim_trailing(String.duplicate("the quick brown fox jumps over the lazy dog ", 6))
  end
end
