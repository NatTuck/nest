defmodule Nest.Agents.Agent.BatchPlanTest do
  @moduledoc """
  Pure unit tests for the `agents-batch` item/template helpers that have
  no side effects: `resolve_items/2`, `template_ok/1`, and `render/3`.
  The fork-join driver (`run/2`) is covered end-to-end in
  `agents_batch_test.exs` (it spawns real sub-agents through the
  coordinator).
  """
  use ExUnit.Case, async: true

  import Nest.Test.TmpCleanup

  alias Nest.Agents.Agent.BatchPlan
  alias Nest.Messages.ToolCall
  alias Nest.Sandbox.Mounts

  setup do
    # A workspace outside /tmp: the scratch dir is bound at /tmp, so a
    # /tmp-rooted workspace is rejected.
    dir =
      Path.join([
        File.cwd!(),
        "_build",
        "tmp",
        "nest_batch_plan_test_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> rm_tmp!(dir, "nest_batch_plan_test_") end)
    %{tmp: dir}
  end

  # `resolve_items/2` only reads `:caps` / `:mounts` on the glob branch; the
  # items branch ignores the ctx. A bare map is enough for the items cases.
  @ctx %{caps: %{}, mounts: Mounts.new(nil, nil)}

  describe "resolve_items/2" do
    test "a non-empty items list (no glob) resolves to that list" do
      assert {:ok, ["a", "b"]} = BatchPlan.resolve_items(%{"items" => ["a", "b"]}, @ctx)
    end

    test "both items and glob is rejected" do
      assert {:error, msg} =
               BatchPlan.resolve_items(%{"items" => ["a"], "glob" => "x/*.txt"}, @ctx)

      assert msg =~ "exactly one"
    end

    test "an empty items list is rejected" do
      assert {:error, msg} = BatchPlan.resolve_items(%{"items" => []}, @ctx)
      assert msg =~ "non-empty"
    end

    test "a blank item is rejected rather than spawned and never run" do
      # `""` is legal at the schema level and would spawn a child with no
      # instruction: never tracked, never run, burning the whole per-item
      # timeout. Dropping it silently would change the item count and the slot
      # indices, so the whole call is the error.
      assert {:error, msg} = BatchPlan.resolve_items(%{"items" => ["a", ""]}, @ctx)
      assert msg =~ "`items[1]` is blank"

      assert {:error, msg} = BatchPlan.resolve_items(%{"items" => ["   "]}, @ctx)
      assert msg =~ "`items[0]` is blank"

      # Blank is reported as blank, not as over the length bound: the two checks
      # are ordered, and a message that named the wrong one would send the model
      # after the wrong fix.
      refute msg =~ "bytes"
    end

    test "an item that is neither a string nor an integer is rejected" do
      assert {:error, msg} = BatchPlan.resolve_items(%{"items" => ["a", %{"x" => 1}]}, @ctx)
      assert msg =~ "`items[1]` is %{\"x\" => 1}"
    end

    test "an integer item is accepted (assignment ids)" do
      assert {:ok, [1, "a"]} = BatchPlan.resolve_items(%{"items" => [1, "a"]}, @ctx)
    end

    test "neither items nor glob is rejected" do
      assert {:error, msg} = BatchPlan.resolve_items(%{}, @ctx)
      assert msg =~ "one of"
    end

    test "a glob with no workspace is a resolve error", %{tmp: dir} do
      # `dir` is unused beyond establishing the glob is non-empty; the
      # relative pattern with a `nil` workspace is the error under test.
      _ = dir
      assert {:error, msg} = BatchPlan.resolve_items(%{"glob" => "*.txt"}, @ctx)
      assert msg =~ "No workspace configured"
    end

    test "a glob resolving to files returns them (sorted)", %{tmp: dir} do
      root = Nest.FSPath.canonical(dir)
      File.mkdir_p!(Path.join(root, "w"))

      for rel <- ["w/z.txt", "w/a.txt"] do
        File.write!(Path.join(root, rel), "x")
      end

      caps = %{"net" => false, "fs" => %{"read" => ["/"], "write" => []}}
      ctx = %{caps: caps, mounts: Mounts.new(root, nil)}
      expected = [Path.join(root, "w/a.txt"), Path.join(root, "w/z.txt")]

      assert {:ok, ^expected} = BatchPlan.resolve_items(%{"glob" => "w/*.txt"}, ctx)
    end

    test "a glob matching nothing is a whole-call error", %{tmp: dir} do
      root = Nest.FSPath.canonical(dir)
      caps = %{"net" => false, "fs" => %{"read" => ["/"], "write" => []}}
      ctx = %{caps: caps, mounts: Mounts.new(root, nil)}

      assert {:error, msg} = BatchPlan.resolve_items(%{"glob" => "w/*.xyz"}, ctx)
      assert msg =~ "matched no readable files"
    end
  end

  describe "template_ok/1" do
    test "an empty template is allowed (each item is the instruction)" do
      assert {:ok, ""} = BatchPlan.template_ok("")
    end

    test "a template with a {item} placeholder is allowed" do
      assert {:ok, "sum {item}"} = BatchPlan.template_ok("sum {item}")
    end

    test "a template with only an {index} placeholder is allowed" do
      assert {:ok, "step {index}"} = BatchPlan.template_ok("step {index}")
    end

    test "a template that is not a string is treated as absent, not raised on" do
      # `Map.get(args, "template", "")` is `nil` for a JSON `null`, and the
      # template check used to raise on it.
      assert {:ok, ""} = BatchPlan.template_ok(nil)
    end

    test "a template with no placeholder is rejected" do
      assert {:error, msg} = BatchPlan.template_ok("no placeholder here")
      assert msg =~ "must contain"
    end
  end

  describe "slot_to_string/1" do
    test "a slot a child never filled says so instead of going out as null or empty" do
      # `nil` is unreachable from `assemble/3` (every item is spawned, and every
      # spawned child's outcome is consumed or times out before the finish
      # guard), and `assemble_stopped/3` maps it to its own marker first. Both
      # are here so neither can leak as JSON `null` / an empty string.
      assert BatchPlan.slot_to_string(nil) == "[error: no result]"

      assert BatchPlan.slot_to_string("") ==
               "[error: finished its turn without producing any text]"

      assert BatchPlan.slot_to_string("done") == "done"
    end
  end

  describe "assemble_stopped/3" do
    test "a stopped batch reports the slots it filled, in item order" do
      ctx = %{context_limit: 100_000, messages: []}
      tc = %ToolCall{arguments: %{}}

      # The slot alpha filled is not discarded with the batch; the slot the stop
      # never reached says why it is empty.
      assert Jason.decode!(BatchPlan.assemble_stopped(ctx, tc, ["alpha-done", nil])) ==
               ["alpha-done", "[error: not run: the batch stopped]"]

      # The whole-batch twin keeps its own marker for the same nil.
      assert Jason.decode!(BatchPlan.assemble(ctx, tc, ["alpha-done", nil])) ==
               ["alpha-done", "[error: no result]"]
    end
  end

  describe "render/3" do
    test "an empty template renders the item verbatim" do
      assert BatchPlan.render("", 0, "the raw item") == "the raw item"
    end

    test "substitutes {item} and {index}" do
      assert BatchPlan.render("idx {index}: {item}", 3, "hello") == "idx 3: hello"
    end

    test "replaces every occurrence of a placeholder" do
      assert BatchPlan.render("{item} vs {item}", 0, "x") == "x vs x"
    end
  end

  describe "names_for_items/3" do
    test "derives names from parameter items, suffixing repeated items by occurrence" do
      assert BatchPlan.names_for_items([1, 12, 8, 1, "goat"], "zoo", true) ==
               ["zoo-1-1", "zoo-12", "zoo-8", "zoo-1-2", "zoo-goat"]
    end

    test "slugifies parameter items and omits the prefix when blank" do
      # Not a path: `a/b` would (rightly) contribute just `b` now.
      assert BatchPlan.names_for_items(["Foo Bar", "a.b", "x_y"], "", true) ==
               ["foo-bar", "a-b", "x-y"]
    end

    test "a slug that sanitizes to empty falls back to item-<n>" do
      assert BatchPlan.names_for_items(["!!!", "@@@"], "p", true) == ["p-item-1", "p-item-2"]
    end

    test "names instruction items by position, because no slug of a sentence is a name" do
      # Issue #104: a batch whose items are instructions used to name each child
      # after a 64-character slice of the instruction, which read as a truncated
      # sentence in the sidebar. The slot order is what the aggregate comes back
      # in, so the position is the honest name.
      assert BatchPlan.names_for_items(
               ["Review the parser for crashes", "Review the lexer for crashes"],
               "rev",
               false
             ) == ["rev-item-1", "rev-item-2"]

      assert BatchPlan.names_for_items(["one", "two"], "", false) == ["item-1", "item-2"]
    end

    test "a long parameter is cut to 32 characters, and the cut is trimmed" do
      # The fixture's slug is 31 `a`s plus `-b`, so the 32-character cut lands
      # *on* the separator and leaves a trailing dash unless the post-cut trim
      # removes it. (A long *path* cannot test this any more: it contributes its
      # basename, so there is nothing to cut.)
      [name] = BatchPlan.names_for_items([String.duplicate("a", 31) <> " b"], "", true)

      assert name == String.duplicate("a", 31)
    end
  end

  describe "params?/2" do
    test "an item is a parameter when the call has a template or a glob, and not otherwise" do
      items = %{"items" => ["review the parser", "review the lexer"]}

      refute BatchPlan.params?(items, "")

      assert BatchPlan.params?(items, "Review {item} for crashes.")
      assert BatchPlan.params?(%{"glob" => "lib/**/*.ex"}, "")

      # A model that is not using the parameter sends `null` for it. `null` is
      # neither absent nor `""`, and reading it as "a glob" switched the naming
      # rule off for a call that had no glob at all.
      refute BatchPlan.params?(Map.put(items, "glob", nil), "")
    end
  end

  describe "the item bound" do
    test "an item at the cap is accepted and one character over is refused with the remedy" do
      at_cap = String.duplicate("a", 256)
      over = String.duplicate("a", 257)

      assert {:ok, [^at_cap]} = BatchPlan.resolve_items(%{"items" => [at_cap]}, @ctx)

      assert {:error, message} = BatchPlan.resolve_items(%{"items" => [over]}, @ctx)

      assert message =~ "257 characters"
      assert message =~ "at most 256"
      # The remedy, so the model can correct the call rather than retry it.
      assert message =~ "template"
      assert message =~ "agents-spawn"
    end
  end
end
