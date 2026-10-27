defmodule Nest.Spaces.ContextWarningsTest do
  @moduledoc """
  `spaces.context_warnings`: the setting that turns the runtime's 25/50/75%
  context-usage notices on (issue #176).

  Off by default, because a notice that arrives before compaction can also read
  as "stop now". Its own file rather than a section of
  `test/nest/spaces/network_access_test.exs` for the same reason it is its own
  module: it is not part of the sandbox environment, so none of that file's
  migration-derivation or `update_environment/2` machinery applies.
  """

  use Nest.DataCase, async: true

  alias Nest.Agents.AgentTestHelpers
  alias Nest.Spaces
  alias Nest.Spaces.ContextWarnings

  defp fresh(space), do: Spaces.get_space(space.id)

  defp create_space(attrs \\ %{}) do
    params =
      Map.merge(
        %{
          name: "warnings-#{System.unique_integer([:positive])}",
          workspace_path: AgentTestHelpers.default_test_workspace()
        },
        attrs
      )

    {:ok, space} = Spaces.create_space(nil, params)
    space
  end

  describe "the column's default" do
    test "a new space has the notices off, and the start path's read agrees" do
      space = create_space()

      assert space.context_warnings == false
      assert Spaces.environment(space.id).context_warnings == false
    end

    test "a space created with the setting on keeps it" do
      space = create_space(%{context_warnings: true})

      assert space.context_warnings == true
      assert Spaces.environment(space.id).context_warnings == true
    end

    test "a blank value is the default, not a constraint error" do
      # The New Space form sends a boolean; a client that sends a blank instead
      # must not get a NOT NULL violation out of `cast/4`.
      assert create_space(%{context_warnings: ""}).context_warnings == false
    end
  end

  describe "ContextWarnings.set/2" do
    test "turns the setting on and off, and the read follows" do
      space = create_space()

      assert {:ok, %{context_warnings: true}} = ContextWarnings.set(space, true)
      assert Spaces.environment(space.id).context_warnings == true

      # From a re-read row: `change/2` compares against the value the caller
      # holds, so the writer is given the row it is writing (the channel passes
      # the one its environment edit just returned).
      assert {:ok, %{context_warnings: false}} = ContextWarnings.set(fresh(space), false)
      assert Spaces.environment(space.id).context_warnings == false
    end

    test "setting a value the row already holds is not an error" do
      # A dialog save always sends the toggle, whether or not it moved, so the
      # no-op has to be a success: `Ecto.Changeset.change/2` records no change
      # for it and `Repo.update/1` sends no query.
      space = create_space(%{context_warnings: true})

      assert {:ok, %{context_warnings: true}} = ContextWarnings.set(space, true)
      assert Spaces.get_space(space.id).context_warnings == true
    end
  end
end
