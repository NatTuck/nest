defmodule Nest.Tools.GroupsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.Tools.Groups

  describe "expand/1" do
    test "expands each group to its tools in canonical order" do
      assert Groups.expand(["file"]) == ~w(file-read file-write file-edit file-inspect)
      assert Groups.expand(["shell"]) == ~w(shell-cmd shell-list shell-wait shell-kill)
      assert Groups.expand(["context"]) == ~w(context-check context-compact)

      assert Groups.expand(["agents"]) ==
               ~w(agents-spawn agents-query agents-send agents-wait agents-list agents-archive agents-batch models-list)
    end

    test "orders groups canonically regardless of input order and dedupes" do
      assert Groups.expand(["agents", "file", "agents"]) ==
               Groups.expand(["file", "agents"])
    end

    test "returns [] for an empty list" do
      assert Groups.expand([]) == []
    end

    test "warns about and drops unknown groups" do
      log =
        capture_log(fn ->
          assert Groups.expand(["file", "bogus", "nonsense"]) ==
                   ~w(file-read file-write file-edit file-inspect)
        end)

      assert log =~ "Unknown tool group \"bogus\""
      assert log =~ "Unknown tool group \"nonsense\""
    end
  end

  describe "group?/1 and tools_for/1" do
    test "recognizes the known groups" do
      assert Enum.all?(Groups.all(), &Groups.group?/1)
      refute Groups.group?("bogus")
    end

    test "unknown groups have no tools" do
      assert Groups.tools_for("bogus") == []
    end
  end
end
