defmodule Nest.AgentsAutoNameTest do
  @moduledoc """
  Tests the no-name path of `Agents.create_agent/2` — when the
  caller doesn't pass a name, the function delegates to
  `Supervisor.generate_unique_name/0` which produces an
  adjective-animal pair (e.g. "clever-raven") that doesn't
  collide with any agent in the supervisor's `Registry` or
  the DB.

  Lives in its own `async: false` file because the auto-name
  check reads `Registry.list()` + `Persistence.list_agent_names()`,
  both of which are per-BEAM / per-transaction. Running
  concurrently with other tests' agents (or their on_exit
  cleanups) creates a race window where the generator could
  return a name that collides with a parallel test's
  agent. Serialized here so the path is deterministically
  exercised.
  """
  use Nest.DataCase, async: false

  import ExUnit.Callbacks
  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor

  setup :verify_on_exit!

  setup do
    # `Agents.create_agent/2` → `Agent.pre_spawn/1` inserts an
    # `agents` row with `vocation_id` FK. The test pid resolves
    # a real `vocation_id` (inserting the row in its own
    # sandboxed transaction); each `Agents.create_agent/2` call
    # below passes it explicitly.
    Process.put(:test_vocation_id, AgentTestHelpers.vocation_id_for_test())
    on_exit(fn -> Process.delete(:test_vocation_id) end)

    {:ok, _space_id} = AgentTestHelpers.create_test_space()

    # No `await_models_refresh/0` needed: this file's tests
    # either pass `%{provider: "model-studio"}` without a `:name`
    # (deliberately starting the agent in `:model_missing` to
    # verify the auto-name path) or use `qwen3.5-plus` (a
    # static-config entry, returned immediately by `Models.list/0`
    # from `state.static_config.models`).

    :ok
  end

  defp vid, do: Process.get(:test_vocation_id)

  describe "create_agent/2 with no name supplied" do
    test "auto-generates a unique adjective-animal name" do
      # Pass a model with provider but no `:name` (the model's
      # `:name` is the LLM identifier, not the agent's registry
      # key). `Agents.create_agent/2` falls back to
      # `Supervisor.generate_unique_name/0`. The model's `:name`
      # is omitted on purpose — leaving it nil forces the agent
      # into `:model_missing` state and exercises the diagnostic
      # log below; the test's actual assertion is the
      # auto-generated name.
      log =
        capture_log(fn ->
          {:ok, name} =
            Agents.create_agent(
              AgentTestHelpers.current_space_id(),
              %{provider: "model-studio"},
              vocation_id: vid()
            )

          # Auto-generated name test — direct `Agents.create_agent/2`
          # is intentional (the helper always passes `name:` and
          # would never exercise the no-name fallback). Register
          # cleanup so the BEAM pid doesn't outlive the test.
          AgentTestHelpers.ensure_cleanup(name)

          assert is_binary(name)
          assert Regex.match?(~r/^[a-z]+-[a-z]+$/, name)
          assert {:ok, _pid} = Supervisor.get_agent(AgentTestHelpers.current_space_id(), name)
        end)

      assert log =~ "could not resolve model"
    end

    test "auto-generated names are unique across consecutive calls" do
      # `capture_log/1` swallows the per-agent "could not
      # resolve model" warnings (each test agent has no model
      # `name:` — only the static-config lookup-name-key —
      # so `Agent.init/1` logs once per agent). The unique-
      # name assertions below are unrelated to those logs.
      _ =
        capture_log(fn ->
          {:ok, name1} =
            Agents.create_agent(
              AgentTestHelpers.current_space_id(),
              %{provider: "model-studio"},
              vocation_id: vid()
            )

          AgentTestHelpers.ensure_cleanup(name1)

          {:ok, name2} =
            Agents.create_agent(
              AgentTestHelpers.current_space_id(),
              %{provider: "model-studio"},
              vocation_id: vid()
            )

          AgentTestHelpers.ensure_cleanup(name2)

          assert name1 != name2
          assert Regex.match?(~r/^[a-z]+-[a-z]+$/, name1)
          assert Regex.match?(~r/^[a-z]+-[a-z]+$/, name2)
        end)
    end

    test "auto-generated name can be used to look up the agent via get_info/1" do
      # Use a model with a name so the agent's :idle startup
      # path succeeds; we pass the agent's name via `name:` opt
      # (auto-generator path not exercised here — this test
      # is about get_info lookup with an auto-name prefix).
      prefix = "auto-name-test-"
      name = prefix <> Integer.to_string(System.unique_integer([:positive]))

      {:ok, _name} =
        Agents.create_agent(
          AgentTestHelpers.current_space_id(),
          %{name: "qwen3.5-plus", provider: "model-studio"},
          name: name,
          vocation_id: vid()
        )

      AgentTestHelpers.ensure_cleanup(name)

      assert {:ok, info} = Agents.get_info(AgentTestHelpers.current_space_id(), name)
      assert info.name == name
      assert info.status == :idle
      assert model_name(info.model) == "qwen3.5-plus"
    end

    test "an explicit :name opt overrides the auto-generator" do
      explicit = "my-explicit-name"

      {:ok, name} =
        Agents.create_agent(
          AgentTestHelpers.current_space_id(),
          %{name: "qwen3.5-plus", provider: "model-studio"},
          name: explicit,
          vocation_id: vid()
        )

      AgentTestHelpers.ensure_cleanup(name)

      assert name == explicit
    end
  end

  # The `model` field on `info` arrives as string keys for
  # agents loaded from the JSONB column (via `Persistence.
  # build_attrs_for_start/1` → `state.model`) and as atom keys
  # when the caller passes atom-keyed attrs directly. Both
  # shapes are valid; tests use this accessor to assert
  # without coupling to the source shape.
  defp model_name(model), do: model[:name] || model["name"]
end
