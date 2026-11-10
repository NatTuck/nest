defmodule Nest.Agents.Agent.BatchSizer.OverflowTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.BatchSizer.Overflow`.

  `substitute/5` is the one shape an oversized result takes: a pointer naming
  the scratch file, its size, and a fixed-size preview of the content. It never
  echoes the caller's arguments (they are already in the `tool_use` part next
  door) and never depends on the budget, which is what lets
  `substitute_size/0` price it for the preflight.

  A write that fails is `:error`, not a marker and not a quiet inline copy: the
  caller turns it into a clear error, because a result too large to inline and
  impossible to file has to say so.
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
      assert Estimator.estimate(out) <= Overflow.substitute_size()

      # A write that fails is its own answer — not a marker, and not a quiet
      # inline copy of the content.
      assert Overflow.substitute(content, %{}, "Output of shell-cmd", "exec") == :error
    end

    test "names the file and nothing else when the content has no lines", %{dir: dir} do
      # A single line longer than the whole preview: the preview is cut by
      # characters rather than dropped, so a minified blob still shows its head.
      assert {:ok, out} =
               Overflow.substitute(
                 String.duplicate("x", 5_000),
                 %{mounts: Mounts.new(nil, dir)},
                 "Output of shell-cmd",
                 "exec"
               )

      assert out =~ "xxxx"
      assert Estimator.estimate(out) <= Overflow.substitute_size() + 10
    end
  end
end
