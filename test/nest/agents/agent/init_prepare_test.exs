defmodule Nest.Agents.Agent.InitPrepareTest do
  @moduledoc """
  `Init.prepare/1`: the caller-side composition of the expensive part of an
  agent's initial state.

  Composing the system prompt runs the sandbox (`AGENTS.md` is read through it),
  and that used to happen only inside `init/1`, with the agent supervisor
  blocked for the whole of it. `prepare/1` moves the work into the caller and
  carries the result on the attrs as `:prepared`, which `build_state/2` and
  `PreSpawn` both reuse.

  The prompt depends on the agent's mode for exactly one thing — the caps the
  `AGENTS.md` read is authorized with — so the composition test below compares a
  prepared composition against an unprepared one on both counts: the same bytes,
  and the same caps on the read.

  What this file does *not* pin is the ordering at the call sites: it prepares
  attrs that already carry their mode, so it cannot see a caller that prepared
  before the row's mode was derived (the bytes match either way, because both
  modes currently grant `fs.read: ["/"]`). That needs a test that goes through
  `PreSpawn.pre_spawn/1` with a blueprint whose `default_mode` is `"plan"` and
  asserts the caps of the read. Until it exists the ordering is held only by
  `Init.prepare/1`'s docs.

  What it does pin, in "the supervisor's rescue", is the *other* half of the
  caller-side move: a composition that raises (composing creates the scratch
  directory, so a path that cannot be made raises `File.Error` out of the
  caller) reaches a channel caller as `{:error, {:prepare_failed, exception}}`
  and is logged, rather than escaping `Supervisor.fetch_or_start_agent/2`.
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Modes
  alias Nest.Persistence
  alias Nest.Sandbox
  alias Nest.Spaces
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    {:ok, space_id} = AgentTestHelpers.create_test_space()

    {:ok, vocation} =
      Vocations.create_vocation(%{
        name: "InitPrepare-#{System.unique_integer([:positive])}",
        description: "Vocation for the prepare/1 tests",
        system_prompt: "Base prompt.",
        tools: ["context"]
      })

    %{space_id: space_id, vocation: vocation}
  end

  describe "prepare/1" do
    test "it is a passthrough for attrs it can compose and for attrs it cannot", %{
      space_id: space_id,
      vocation: vocation
    } do
      prepared = {"already composed", "plan", ["context"], vocation, :llm_metrics}
      attrs = Map.put(agent_attrs(space_id, vocation), :prepared, prepared)

      # The exact term survives: a second composition would replace it with a
      # freshly composed one and would also run the sandbox again.
      assert Init.prepare(attrs) == attrs

      # And attrs missing what `build_vocation_pipeline/2` needs are left alone
      # rather than composed with a hole in them, so `init/1`'s fallback still
      # covers them.
      unable =
        space_id
        |> agent_attrs(vocation)
        |> Map.drop([:sandbox_backend, :network_access])

      assert Init.prepare(unable) == unable
    end
  end

  describe "prompt composition" do
    test "a prepared composition matches an unprepared one, bytes and caps", %{
      space_id: space_id,
      vocation: vocation
    } do
      workspace = AgentTestHelpers.default_test_workspace()
      File.write!(Path.join(workspace, "AGENTS.md"), "# Project rules\n\nAlways use pnpm.\n")

      # `plan`, so the caps the read is authorized with are distinguishable from
      # `Modes.default()`'s: `plan` may not write the workspace.
      attrs = agent_attrs(space_id, vocation, %{workspace_path: workspace, mode: "plan"})
      on_exit(fn -> TmpSpace.cleanup(space_id, attrs.name, attrs.sandbox_backend) end)

      test_pid = self()

      # The one sandbox read a composition does is the `AGENTS.md` read, so
      # stubbing it records the caps it was authorized with while still serving
      # the real file's bytes: the workspace is bound at its own path, so the
      # sandbox-domain path is the host path.
      stub(Sandbox, :read, fn path, caps, _mounts ->
        send(test_pid, {:agents_md_read, path, caps})
        File.read(path)
      end)

      unprepared_text = attrs |> Init.build_active_state(client_config()) |> system_text()

      prepared_text =
        attrs |> Init.prepare() |> Init.build_active_state(client_config()) |> system_text()

      assert unprepared_text =~ "Always use pnpm."
      assert prepared_text == unprepared_text

      # Both compositions read `AGENTS.md`, each with the caps of the mode the
      # attrs carry — and the prepared one reads it once, not twice.
      plan_caps = Modes.caps("plan")

      assert_received {:agents_md_read, path, ^plan_caps}
      assert Path.basename(path) == "AGENTS.md"
      assert_received {:agents_md_read, _path, ^plan_caps}
      refute_received {:agents_md_read, _path, _other_caps}
    end
  end

  # Composing creates the scratch directory on demand (the `AGENTS.md` read
  # stages a command, and `Mounts.ensure_scratch!/1` makes the directory it
  # stages into), so a scratch path that cannot be made raises `File.Error` out
  # of the *composing caller*. That caller is the supervisor, which maps it back
  # to the `{:error, term()}` its callers are specced for and logs it.
  describe "the supervisor's rescue" do
    test "a composition that cannot make the scratch is {:error, {:prepare_failed, _}}, logged",
         %{space_id: space_id, vocation: vocation} do
      name = "prepare-fail-#{System.unique_integer([:positive])}"

      {:ok, _row} =
        Persistence.insert_agent(%{
          space_id: space_id,
          name: name,
          model: %{name: "qwen3.5-plus", provider: "model-studio"},
          vocation_id: vocation.id,
          # A workspace, so the composition does read `AGENTS.md` through the
          # sandbox — without one `agents_md_section/2` is empty and no command
          # (so no scratch directory) is ever needed.
          workspace_path: AgentTestHelpers.default_test_workspace()
        })

      # A *file* where the scratch directory goes: `File.dir?` is false and
      # `File.mkdir_p!` raises `File.Error{reason: :eexist}`.
      scratch = TmpSpace.agent_dir(space_id, name, Spaces.sandbox_backend(space_id))
      File.mkdir_p!(Path.dirname(scratch))
      File.write!(scratch, "")
      on_exit(fn -> File.rm(scratch) end)

      # Asserted inside the capture: `Logger.error` is synchronous, so the
      # line is guaranteed to have been emitted by the time the call returns.
      log =
        capture_log(fn ->
          assert {:error, {:prepare_failed, %File.Error{}}} =
                   Supervisor.fetch_or_start_agent(space_id, %{name: name})
        end)

      assert log =~ "Could not prepare"
    end
  end

  # Everything `Init.prepare/1` needs to compose, and everything
  # `Init.build_active_state/2` needs to build the state from the result.
  defp agent_attrs(space_id, vocation, overrides \\ %{}) do
    Map.merge(
      %{
        name: "prepare-#{System.unique_integer([:positive])}",
        space_id: space_id,
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vocation.id,
        vocation: vocation,
        workspace_path: nil,
        depth: 0,
        mode: "plan",
        sandbox_backend: "bwrap",
        network_access: false
      },
      overrides
    )
  end

  defp system_text(state) do
    [{:system, system} | _rest] = state.chat_state.messages
    Enum.map_join(system.parts, "\n", & &1.text)
  end

  defp client_config do
    {:ok, config} = Config.create_client_config(%{name: "qwen3.5-plus"})
    config
  end
end
