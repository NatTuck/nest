defmodule Nest.ProjectStructureTest do
  @moduledoc """
  Tests to verify project structure constraints.

  These tests ensure that JavaScript dependencies are kept in the correct
  location (./assets/) and not accidentally created in the project root.
  """
  use ExUnit.Case, async: true

  @project_root Path.expand("../..", __DIR__)

  describe "project structure" do
    test "JavaScript artifacts should not exist in the project root" do
      node_modules_path = Path.join(@project_root, "node_modules")

      refute File.dir?(node_modules_path),
             "node_modules directory found in project root. " <>
               "JavaScript dependencies must be in ./assets/node_modules"

      package_json_path = Path.join(@project_root, "package.json")

      refute File.exists?(package_json_path),
             "package.json found in project root. " <>
               "JavaScript dependencies must be managed in ./assets/"

      pnpm_lock_path = Path.join(@project_root, "pnpm-lock.yaml")

      refute File.exists?(pnpm_lock_path),
             "pnpm-lock.yaml found in project root. " <>
               "JavaScript lock file must be in ./assets/"
    end
  end
end
