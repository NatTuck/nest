defmodule Nest.Agents.Agent.BatchLoopTest do
  @moduledoc """
  Pure unit tests for the `agents-batch` item/template helpers that have
  no side effects: `resolve_items/2`, `template_ok/1`, and `render/3`.
  The fork-join driver (`run/2`) is covered end-to-end in
  `agents_batch_test.exs` (it spawns real sub-agents through the
  coordinator).
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.BatchLoop

  setup do
    dir =
      Path.join(System.tmp_dir!(), "nest_batch_loop_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{tmp: dir}
  end

  # `resolve_items/2` only reads `:caps` / `:workspace_path` on the
  # glob branch; the items branch ignores the ctx. A bare map is enough
  # for the items cases.
  @ctx %{caps: %{}, workspace_path: nil}

  describe "resolve_items/2" do
    test "a non-empty items list (no glob) resolves to that list" do
      assert {:ok, ["a", "b"]} = BatchLoop.resolve_items(%{"items" => ["a", "b"]}, @ctx)
    end

    test "both items and glob is rejected" do
      assert {:error, msg} =
               BatchLoop.resolve_items(%{"items" => ["a"], "glob" => "x/*.txt"}, @ctx)

      assert msg =~ "exactly one"
    end

    test "an empty items list is rejected" do
      assert {:error, msg} = BatchLoop.resolve_items(%{"items" => []}, @ctx)
      assert msg =~ "non-empty"
    end

    test "neither items nor glob is rejected" do
      assert {:error, msg} = BatchLoop.resolve_items(%{}, @ctx)
      assert msg =~ "one of"
    end

    test "a glob with no workspace is a resolve error", %{tmp: dir} do
      # `dir` is unused beyond establishing the glob is non-empty; the
      # relative pattern with a `nil` workspace is the error under test.
      _ = dir
      assert {:error, msg} = BatchLoop.resolve_items(%{"glob" => "*.txt"}, @ctx)
      assert msg =~ "No workspace configured"
    end

    test "a glob resolving to files returns them (sorted)", %{tmp: dir} do
      root = Nest.FSPath.canonical(dir)
      File.mkdir_p!(Path.join(root, "w"))

      for rel <- ["w/z.txt", "w/a.txt"] do
        File.write!(Path.join(root, rel), "x")
      end

      caps = %{"net" => false, "fs" => %{"read" => ["/"], "write" => []}}
      ctx = %{caps: caps, workspace_path: root}
      expected = [Path.join(root, "w/a.txt"), Path.join(root, "w/z.txt")]

      assert {:ok, ^expected} = BatchLoop.resolve_items(%{"glob" => "w/*.txt"}, ctx)
    end

    test "a glob matching nothing is a whole-call error", %{tmp: dir} do
      root = Nest.FSPath.canonical(dir)
      caps = %{"net" => false, "fs" => %{"read" => ["/"], "write" => []}}
      ctx = %{caps: caps, workspace_path: root}

      assert {:error, msg} = BatchLoop.resolve_items(%{"glob" => "w/*.xyz"}, ctx)
      assert msg =~ "matched no readable files"
    end
  end

  describe "template_ok/1" do
    test "an empty template is allowed (each item is the instruction)" do
      assert {:ok, ""} = BatchLoop.template_ok("")
    end

    test "a template with a {item} placeholder is allowed" do
      assert {:ok, "sum {item}"} = BatchLoop.template_ok("sum {item}")
    end

    test "a template with only an {index} placeholder is allowed" do
      assert {:ok, "step {index}"} = BatchLoop.template_ok("step {index}")
    end

    test "a template with no placeholder is rejected" do
      assert {:error, msg} = BatchLoop.template_ok("no placeholder here")
      assert msg =~ "must contain"
    end
  end

  describe "render/3" do
    test "an empty template renders the item verbatim" do
      assert BatchLoop.render("", 0, "the raw item") == "the raw item"
    end

    test "substitutes {item} and {index}" do
      assert BatchLoop.render("idx {index}: {item}", 3, "hello") == "idx 3: hello"
    end

    test "replaces every occurrence of a placeholder" do
      assert BatchLoop.render("{item} vs {item}", 0, "x") == "x vs x"
    end
  end
end
