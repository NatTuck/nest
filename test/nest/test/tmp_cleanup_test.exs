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

  test "removes a path that contains the marker", %{dir: dir} do
    File.write!(Path.join(dir, "f"), "x")

    assert :ok = rm_tmp!(dir, "nest_tmp_cleanup_test_")
    refute File.exists?(dir)
  end

  test "refuses a path without the marker, or an empty marker", %{dir: dir} do
    assert_raise ArgumentError, ~r/refusing to rm_rf/, fn ->
      rm_tmp!(dir, "nope_")
    end

    assert_raise ArgumentError, ~r/non-empty/, fn ->
      rm_tmp!(dir, "")
    end

    assert File.dir?(dir)
  end
end
