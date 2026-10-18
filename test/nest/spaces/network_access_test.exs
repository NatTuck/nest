defmodule Nest.Spaces.NetworkAccessTest do
  @moduledoc """
  Network access as a space property: the migration's derivation, the resolver,
  and the setter that makes it editable.
  """

  # `async: false` on purpose: the derivation tests below re-create the
  # `vocations.modes` column that stage 4a drops, and `ALTER TABLE` takes ACCESS
  # EXCLUSIVE on `vocations`. Under `async: true` that would block every
  # concurrently running test that touches a vocation while this one waits on
  # `agents`/`spaces` — a lock-ordering deadlock, not a theoretical one. ExUnit
  # runs `async: false` modules serially, so nothing else is in flight here.
  # The lock is taken against the **shared** `nest_test`, so it would also block
  # another worktree's suite on the same database; the `flock` convention (one
  # suite at a time) is the assumption that makes that safe.
  use Nest.DataCase, async: false

  alias Nest.Agents.AgentTestHelpers
  alias Nest.Persistence
  alias Nest.Repo
  alias Nest.Spaces
  alias Nest.Spaces.Space
  alias Nest.Vocations

  # `priv/repo/migrations/*.exs` are scripts, not compiled into the app, so the
  # derivation's SQL is only reachable after loading the file. The JSONB walk and
  # the root-agent join are the risky part of the migration, and it has already
  # run in the test database, so this is the only way to exercise them.
  setup_all do
    Code.require_file("priv/repo/migrations/20261016162000_add_network_access_to_spaces.exs")
    :ok
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A space with a root agent whose vocation has the modes given, with the column
  # deliberately set to the *opposite* of what the derivation should produce, so
  # the statement's effect is observable.
  defp space_with_root_agent(modes) do
    {:ok, space} =
      Spaces.create_space(nil, %{
        workspace_path: AgentTestHelpers.default_test_workspace(),
        name: unique("net")
      })

    {:ok, _} = Repo.update(Ecto.Changeset.change(space, network_access: false))

    {:ok, vocation} =
      Vocations.create_vocation(%{
        name: unique("net-vocation"),
        description: "network access fixture",
        system_prompt: "fixture",
        tools: []
      })

    # `Nest.Vocations.Vocation` does not declare `:modes` any more — stage 4a
    # dropped the column — so the value this fixture is *about* is written
    # directly. The column itself is put back by the `setup` in the describe
    # below: this is the schema the stage-1 migration ran against.
    # The map goes in as-is. `Jason.encode!` plus `$1::jsonb` would be a *jsonb
    # string* rather than an object — Postgrex infers `jsonb` from the cast and
    # encodes the binary as a JSON string — and `jsonb_each` on that raises the
    # very error this fixture exists to exercise.
    Repo.query!("UPDATE vocations SET modes = $1 WHERE id = $2", [modes, vocation.id])

    {:ok, _row} =
      Persistence.insert_agent(%{
        space_id: space.id,
        name: "#{space.slug}-root",
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vocation.id
      })

    space.id
  end

  defp mode_with_net(net) do
    %{
      "description" => "mode",
      "caps" => %{"net" => net, "fs" => %{"read" => ["/"], "write" => []}}
    }
  end

  # The migration is a script, so it is only loaded at runtime (see `setup_all`)
  # and the compiler cannot see it. A *dynamic* call — the module name built at
  # runtime — is what keeps that from being a compile-time warning.
  defp derivation_sql do
    Module.concat([Nest.Repo.Migrations, AddNetworkAccessToSpaces]).network_access_sql()
  end

  defp derive! do
    Repo.query!(derivation_sql())
    :ok
  end

  describe "the migration's derivation" do
    # The stage-1 migration's SQL does `jsonb_each(v.modes)`, and `vocations.modes`
    # is dropped by stage 4a, so the tests below put it back for the length of one
    # test. Postgres has transactional DDL and the sandbox wraps each test in a
    # transaction, so the rollback removes it again: no `on_exit`, no cleanup — and
    # the migration's own `up/0` keeps the schema it always had, because it runs in
    # migration order, *before* the drop, on every database that has not seen it.
    setup do
      # `IF NOT EXISTS`: until stage 4a's drop has been applied to the database the
      # test runs against, the column is still there and this is a no-op. Once it
      # has been applied, this adds it and the transaction's rollback removes it
      # again.
      Repo.query!("ALTER TABLE vocations ADD COLUMN IF NOT EXISTS modes jsonb")

      # The migration's SQL is `CROSS JOIN LATERAL jsonb_each(v.modes)`, and a
      # LATERAL join is evaluated *before* the `WHERE` that keeps only the space's
      # own root agent — so it walks every agent×vocation pair in the table, not
      # just the one under test, and `jsonb_each(NULL)` is an error. Every vocation
      # had a `modes` map when the migration ran; a vocation created since has
      # none, so the NULLs are given an empty object for the length of the test.
      Repo.query!("UPDATE vocations SET modes = '{}'::jsonb WHERE modes IS NULL")
      :ok
    end

    test "true when any mode of the root agent's vocation enables the network" do
      space_id =
        space_with_root_agent(%{"plan" => mode_with_net(false), "act" => mode_with_net(true)})

      derive!()
      assert Spaces.network_access(space_id) == true
    end

    test "false when every mode of the root agent's vocation disables it" do
      space_id = space_with_root_agent(%{"plan" => mode_with_net(false)})

      derive!()
      assert Spaces.network_access(space_id) == false
    end

    test "false for a space with no root agent" do
      {:ok, space} =
        Spaces.create_space(nil, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: unique("net-orphan")
        })

      {:ok, _} = Repo.update(Ecto.Changeset.change(space, network_access: true))

      derive!()
      assert Spaces.network_access(space.id) == false
    end

    test "false for a root agent with no modes" do
      space_id = space_with_root_agent(%{})

      derive!()
      assert Spaces.network_access(space_id) == false
    end

    test "is a pure function of the tables: running it twice changes nothing" do
      enabled = space_with_root_agent(%{"act" => mode_with_net(true)})
      disabled = space_with_root_agent(%{"plan" => mode_with_net(false)})

      derive!()
      first = {Spaces.network_access(enabled), Spaces.network_access(disabled)}

      derive!()
      assert {Spaces.network_access(enabled), Spaces.network_access(disabled)} == first
      assert first == {true, false}
    end
  end

  describe "network_access/1" do
    test "resolves the space's value" do
      {:ok, space} =
        Spaces.create_space(nil, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: unique("net-read"),
          network_access: false
        })

      assert Spaces.network_access(space.id) == false
    end

    test "defaults to true for a new space, and for a missing row" do
      {:ok, space} =
        Spaces.create_space(nil, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: unique("net-default")
        })

      assert space.network_access == true
      assert Spaces.network_access(space.id) == true
      assert Spaces.network_access(-1) == true
    end
  end

  describe "update_environment/2" do
    test "turns it off and back on" do
      {:ok, space} =
        Spaces.create_space(nil, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: unique("net-set")
        })

      assert {:ok, %Space{network_access: false}} =
               Spaces.update_environment(space.id, %{network_access: false})

      assert Spaces.network_access(space.id) == false

      assert {:ok, %Space{network_access: true}} =
               Spaces.update_environment(space.id, %{network_access: true})

      assert Spaces.network_access(space.id) == true
    end

    test "refuses a missing space" do
      assert {:error, :not_found} = Spaces.update_environment(-1, %{network_access: false})
    end

    test "leaves the space's other properties alone" do
      {:ok, space} =
        Spaces.create_space(nil, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: unique("net-keep"),
          sandbox_backend: "none"
        })

      assert {:ok, updated} = Spaces.update_environment(space.id, %{network_access: false})

      assert updated.sandbox_backend == "none"
      assert updated.name == space.name
    end

    test "releases the space's sandbox environment, so the new value is built" do
      # A container's network is fixed when it is created (`--network none`), so
      # the next command has to build one with the new value — which means the
      # change has to release the container, exactly as an archive or a delete
      # does. What that asks the daemon is asserted against a fake in
      # `Nest.Sandbox.Backend.DockerTest`, because the test environment installs
      # an inert runner rather than talking to a daemon (`config/test.exs`); what
      # is asserted here is that the hook is on the path and does not interfere,
      # and that a space whose backend keeps nothing is unaffected.
      {:ok, docker} =
        Spaces.create_space(nil, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: unique("net-release"),
          sandbox_backend: "docker"
        })

      assert {:ok, %Space{network_access: false}} =
               Spaces.update_environment(docker.id, %{network_access: false})

      assert {:ok, %Space{network_access: true}} =
               Spaces.update_environment(docker.id, %{network_access: true})

      {:ok, plain} =
        Spaces.create_space(nil, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: unique("net-release-plain")
        })

      assert {:ok, %Space{network_access: false}} =
               Spaces.update_environment(plain.id, %{network_access: false})
    end
  end
end
