defmodule Nest.ProjectStructureTest do
  @moduledoc """
  Tests to verify project structure constraints.

  These tests ensure that JavaScript dependencies are kept in the correct
  location (./assets/) and not accidentally created in the project root.
  """
  use ExUnit.Case, async: true

  @project_root Path.expand("../..", __DIR__)

  describe "project structure" do
    test "node_modules should not exist in project root" do
      node_modules_path = Path.join(@project_root, "node_modules")

      assert not File.dir?(node_modules_path),
             "node_modules directory found in project root. " <>
               "JavaScript dependencies must be in ./assets/node_modules"
    end

    test "package.json should not exist in project root" do
      package_json_path = Path.join(@project_root, "package.json")

      assert not File.exists?(package_json_path),
             "package.json found in project root. " <>
               "JavaScript dependencies must be managed in ./assets/"
    end

    test "pnpm-lock.yaml should not exist in project root" do
      pnpm_lock_path = Path.join(@project_root, "pnpm-lock.yaml")

      assert not File.exists?(pnpm_lock_path),
             "pnpm-lock.yaml found in project root. " <>
               "JavaScript lock file must be in ./assets/"
    end
  end
end
