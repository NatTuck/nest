defmodule Nest.Spaces.NetworkAccessTest do
  @moduledoc """
  Network access as a space property: the migration's derivation, the resolver,
  and the setter that makes it editable.
  """

  use Nest.DataCase, async: true

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
    {:ok, space} = Spaces.create_space(nil, %{name: unique("net")})
    {:ok, _} = Repo.update(Ecto.Changeset.change(space, network_access: false))

    {:ok, vocation} =
      Vocations.create_vocation(%{
        name: unique("net-vocation"),
        description: "network access fixture",
        system_prompt: "fixture",
        tools: [],
        modes: modes
      })

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
      {:ok, space} = Spaces.create_space(nil, %{name: unique("net-orphan")})
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
      {:ok, space} = Spaces.create_space(nil, %{name: unique("net-read"), network_access: false})

      assert Spaces.network_access(space.id) == false
    end

    test "defaults to true for a new space, and for a missing row" do
      {:ok, space} = Spaces.create_space(nil, %{name: unique("net-default")})

      assert space.network_access == true
      assert Spaces.network_access(space.id) == true
      assert Spaces.network_access(-1) == true
    end
  end

  describe "set_network_access/2" do
    test "turns it off and back on" do
      {:ok, space} = Spaces.create_space(nil, %{name: unique("net-set")})

      assert {:ok, %Space{network_access: false}} = Spaces.set_network_access(space.id, false)
      assert Spaces.network_access(space.id) == false

      assert {:ok, %Space{network_access: true}} = Spaces.set_network_access(space.id, true)
      assert Spaces.network_access(space.id) == true
    end

    test "refuses a missing space" do
      assert {:error, :not_found} = Spaces.set_network_access(-1, false)
    end

    test "leaves the space's other properties alone" do
      {:ok, space} =
        Spaces.create_space(nil, %{name: unique("net-keep"), sandbox_backend: "none"})

      assert {:ok, updated} = Spaces.set_network_access(space.id, false)

      assert updated.sandbox_backend == "none"
      assert updated.name == space.name
    end
  end
end
