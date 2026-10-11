defmodule Nest.Test.TmpCleanupTest do
  use ExUnit.Case, async: true

  import Nest.Test.TmpCleanup

  setup do
    dir =
      Path.join(System.tmp_dir!(), "nest_tmp_cleanup_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> rm_tmp!(dir, "nest_tmp_cleanup_test_") end)
    {:ok, dir: dir}
  end

  test "removes a path that contains the marker and sits under a temp root", %{dir: dir} do
    File.write!(Path.join(dir, "f"), "x")

    assert :ok = rm_tmp!(dir, "nest_tmp_cleanup_test_")
    refute File.exists?(dir)
  end

  test "removes a path under the project-relative _build/tmp root" do
    dir =
      Path.join([
        File.cwd!(),
        "_build",
        "tmp",
        "nest_tmp_cleanup_test_build_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> rm_tmp!(dir, "nest_tmp_cleanup_test_build_") end)

    assert :ok = rm_tmp!(dir, "nest_tmp_cleanup_test_build_")
    refute File.exists?(dir)
  end

  test "refuses a path without the marker, or an empty marker", %{dir: dir} do
    assert_raise ArgumentError, ~r/does not contain the expected temp marker/, fn ->
      rm_tmp!(dir, "nope_")
    end

    assert_raise ArgumentError, ~r/non-empty/, fn ->
      rm_tmp!(dir, "")
    end

    assert File.dir?(dir)
  end

  test "refuses a path outside the permitted temp roots, even with a valid marker" do
    outside =
      Path.join(
        File.cwd!(),
        "nest_tmp_cleanup_test_outside_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(outside)

    # `outside` is deliberately not under a permitted temp root, so the helper
    # cannot remove it; guard the direct `rm_rf` with the marker instead.
    on_exit(fn ->
      if String.contains?(outside, "nest_tmp_cleanup_test_outside"), do: File.rm_rf(outside)
    end)

    assert_raise ArgumentError, ~r/not under a permitted temp root/, fn ->
      rm_tmp!(outside, "nest_tmp_cleanup_test_")
    end

    # The refusal must leave the path it refused to remove untouched.
    assert File.dir?(outside)
  end
end
