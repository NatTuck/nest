defmodule Nest.Agents.Agent.BatchSizer.OverflowTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.BatchSizer.Overflow`.

  `substitute/5` is the one shape an oversized result takes: a pointer naming
  the scratch file, its size, and a fixed-size preview showing the head and tail
  of the content with an explicit elision marker between them (or the whole
  content when head + tail cover it). It never echoes the caller's arguments
  (they are already in the `tool_use` part next door) and never depends on the
  budget, which is what lets `substitute_size/0` price it for the preflight.

  A write that fails is `:error`, not a marker and not a quiet inline copy: the
  caller turns it into a clear error, because a result too large to inline and
  impossible to file has to say so.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.Sandbox
  alias Nest.Sandbox.Mounts
  alias Nest.TextFixtures
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

  defp ctx(dir), do: %{mounts: Mounts.new(nil, dir)}

  # The pointer's header is deterministic for a fixed id, so a test can pin the
  # whole substitute literally. `substitute/5` names the file "<prefix>-<id>.txt".
  defp header(content, dir, id \\ "t") do
    path = Path.join(Sandbox.sandbox_tmp_path(dir), "exec-#{id}.txt")
    "Output of shell-cmd (#{Estimator.estimate(content)} tokens) saved to #{path}."
  end

  defp preview(out, content, dir),
    do: String.replace_prefix(out, header(content, dir) <> "\n\n", "")

  defp numbered_lines(n) do
    Enum.map_join(1..n, "\n", fn i ->
      "line #{String.pad_leading(Integer.to_string(i), 3, "0")}"
    end)
  end

  test "head_text/3 never returns an empty string" do
    marker = "[content elided: see /tmp/x.txt]"

    # No budget at all, a budget too small for even the first line, and empty
    # content: each returns the caller's marker instead of "".
    assert Overflow.head_text("content", 0, marker) == marker
    assert Overflow.head_text("a line far too long for a 1-token budget", 1, marker) == marker
    assert Overflow.head_text("", 100, marker) == marker

    # Leading whole lines, joined and trailing-trimmed. The marker goes unused
    # because every line fits, so nothing was dropped.
    assert Overflow.head_text("first\nsecond\nthird\n", 100, "unused") ==
             "first\nsecond\nthird"
  end

  test "tail_text/3 takes trailing whole lines and mirrors head_text/3's no_room contract" do
    marker = "[content elided: see /tmp/x.txt]"

    assert Overflow.tail_text("content", 0, marker) == marker
    assert Overflow.tail_text("a line far too long for a 1-token budget", 1, marker) == marker
    assert Overflow.tail_text("", 100, marker) == marker

    # Every line fits, so the whole content comes back trailing-trimmed.
    assert Overflow.tail_text("first\nsecond\nthird\n", 100, "unused") ==
             "first\nsecond\nthird"

    # A budget that fits only the last line takes just that line, never mid-line.
    assert Overflow.tail_text("first\nsecond\nthird", 15, "unused") == "third"
  end

  describe "substitute/5" do
    test "writes the content and returns a pointer + preview, or :error when it cannot", %{
      dir: dir
    } do
      content = String.duplicate("a line of content\n", 400)

      assert {:ok, out} =
               Overflow.substitute(
                 content,
                 %{mounts: Mounts.new(nil, dir)},
                 "Output of shell-cmd",
                 "exec"
               )

      # The pointer names the sandbox path, never the host scratch dir, and
      # says how big the full content is.
      assert out =~ Sandbox.sandbox_tmp_path(dir)
      refute out =~ dir
      assert out =~ "Output of shell-cmd"
      assert out =~ "#{Estimator.estimate(content)} tokens"

      # The preview is bounded by the fixed preview size, not by any caller
      # budget: the substitute is the same size whatever room is left — and
      # `substitute_size/0` must never be below a real one, because the
      # preflight reserves exactly that per call and under-reserving is what
      # lets a batch overflow.
      assert out =~ "line of content"
      assert out =~ "lines elided — read the file"
      assert Estimator.estimate(out) <= Overflow.substitute_size()

      # A write that fails is its own answer — not a marker, and not a quiet
      # inline copy of the content.
      assert Overflow.substitute(content, %{}, "Output of shell-cmd", "exec") == :error
    end

    test "shows head + elision marker + tail, K being the hidden line count", %{dir: dir} do
      content = numbered_lines(400)

      assert {:ok, out} =
               Overflow.substitute(content, ctx(dir), "Output of shell-cmd", "exec", "t")

      # Head is the first 8 whole lines, tail the last 4, and the marker states
      # the 388 lines between them (400 - 8 - 4). Pinned literally so the wording
      # and the count cannot drift.
      assert preview(out, content, dir) ==
               "line 001\nline 002\nline 003\nline 004\nline 005\nline 006\nline 007\nline 008\n" <>
                 "… [388 lines elided — read the file] …\n" <>
                 "line 397\nline 398\nline 399\nline 400"

      # The elided middle really is absent — K is the hidden line count of the
      # final text, not a number unrelated to what was shown.
      refute out =~ "line 009"
      refute out =~ "line 396"
    end

    test "shows the whole content with no marker when head + tail cover it", %{dir: dir} do
      content = "alpha\nbeta\ngamma"

      assert {:ok, out} =
               Overflow.substitute(content, ctx(dir), "Output of shell-cmd", "exec", "t")

      # Zero added overhead: the substitute is exactly the header plus the whole
      # content, with no marker and nothing elided.
      assert out == header(content, dir) <> "\n\n" <> content
      refute out =~ "elided"
    end

    test "head and tail never overlap or double-count on short content", %{dir: dir} do
      # Eight lines the head budget cannot cover alone, but head + tail together
      # do: the whole content is shown once, with no marker and no repeated line.
      content = Enum.map_join(1..8, "\n", fn _ -> "word word word word word word" end)

      assert Overflow.head_text(content, 120, "") != content

      assert {:ok, out} =
               Overflow.substitute(content, ctx(dir), "Output of shell-cmd", "exec", "t")

      assert out == header(content, dir) <> "\n\n" <> content
      refute out =~ "elided"
    end

    test "a single long line falls back to char head + chars-elided marker + char tail", %{
      dir: dir
    } do
      content = String.duplicate("abcdefghij", 500)

      assert {:ok, out} =
               Overflow.substitute(content, ctx(dir), "Output of shell-cmd", "exec", "t")

      pv = preview(out, content, dir)

      # The char path is one line: head, marker and tail with no newline between.
      refute pv =~ "\n"

      [head, rest] = String.split(pv, "… [", parts: 2)
      [count, tail] = String.split(rest, " chars elided — read the file] …", parts: 2)
      j = String.to_integer(count)

      # J is the hidden char count of the final text, and the head/tail are the
      # content's own prefix and suffix — an honest indicator, not a silent cut.
      assert j == String.length(content) - String.length(head) - String.length(tail)
      assert j > 0
      assert String.starts_with?(content, head)
      assert String.ends_with?(content, tail)
      assert pv =~ "… [#{j} chars elided — read the file] …"
    end

    test "losing only trailing whitespace is not labelled as elision", %{dir: dir} do
      content = "hello\n\n   \n"

      assert {:ok, out} =
               Overflow.substitute(content, ctx(dir), "Output of shell-cmd", "exec", "t")

      assert out == header(content, dir) <> "\n\n" <> "hello"
      refute out =~ "elided"

      # A large body whose only loss is trailing whitespace shows the same
      # preview as the trimmed body: the whitespace adds no elision count.
      body = numbered_lines(400)
      padded = body <> "\n\n  \n"

      assert {:ok, plain} =
               Overflow.substitute(body, ctx(dir), "Output of shell-cmd", "exec", "t")

      assert {:ok, with_ws} =
               Overflow.substitute(padded, ctx(dir), "Output of shell-cmd", "exec", "t")

      assert preview(with_ws, padded, dir) == preview(plain, body, dir)
      assert preview(with_ws, padded, dir) =~ "… [388 lines elided — read the file] …"
    end

    test "empty content yields the header alone", %{dir: dir} do
      assert {:ok, out} = Overflow.substitute("", ctx(dir), "Output of shell-cmd", "exec", "t")

      assert out == header("", dir)
      refute out =~ "\n\n"
    end

    test "substitute_size/0 is a budget-independent upper bound covering the widest marker", %{
      dir: dir
    } do
      # A deterministic spread of shapes and sizes — the range of contents a
      # caller would offload under different budgets. `substitute/5` takes no
      # budget, so each yields the same substitute whatever room is left, and
      # the fixed projection must cover every one of them.
      shapes = [
        numbered_lines(1),
        numbered_lines(2),
        numbered_lines(8),
        numbered_lines(50),
        numbered_lines(400),
        numbered_lines(1000),
        TextFixtures.big_text(40_000),
        String.duplicate("abcdefghij", 500),
        Base.encode64(:binary.copy(<<1, 2, 3>>, 1500)),
        String.duplicate("function(a,b){return a+b*2}", 200),
        String.duplicate("héllo wörld — naïve café ☃ ", 500),
        String.duplicate("0123456789", 500),
        String.duplicate("a ", 3000),
        "alpha\nbeta\ngamma",
        "",
        "hello\n\n  \n"
      ]

      bound = Overflow.substitute_size()

      for content <- shapes do
        assert {:ok, out} =
                 Overflow.substitute(content, ctx(dir), "Output of shell-cmd", "exec", "t")

        assert Estimator.estimate(out) <= bound
      end

      # The projection reserves the widest marker (a bounded 10-digit count) on
      # top of the header and both preview halves (head 120 + tail 60 tokens),
      # so it cannot under-price the marker or either half.
      widest = "… [9999999999 chars elided — read the file] …"
      hdr = "Output of shell-cmd (1000000 tokens) saved to /tmp/a/exec-0000000000000000.txt."
      assert bound >= Estimator.estimate(hdr) + 120 + 60 + Estimator.estimate(widest)
    end
  end
end
