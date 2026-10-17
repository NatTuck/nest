defmodule Nest.Agents.Agent.InitPrepareTest do
  @moduledoc """
  `Init.prepare/1`: the caller-side composition of the expensive part of an
  agent's initial state.

  Composing the system prompt is not free, and it used to happen only inside
  `init/1`, with the agent supervisor blocked for the whole of it. `prepare/1`
  moves the work into the caller and carries the result on the attrs as
  `:prepared`, which `build_state/2` and `PreSpawn` both reuse.

  Composition takes no mode and touches no sandbox: `AGENTS.md` is read on the
  host (issue #132), so the bytes no longer depend on the agent's mode at all.
  The composition test below therefore compares a prepared composition against
  an unprepared one on the one thing that is still at stake — the bytes, with
  the workspace's `AGENTS.md` present in both.

  Composition also no longer *creates* the agent's scratch directory. It used to,
  incidentally: `TmpSpace.prompt_mounts/5` only names the directory, but the
  `AGENTS.md` read went through `ShellCmd`, which calls
  `Mounts.ensure_scratch!/1`. A scratch path that could not be made therefore
  raised `File.Error` out of whichever caller was composing — the supervisor,
  which mapped it to `{:error, {:prepare_failed, exception}}`. With a host read
  the directory is made where `TmpSpace`'s own doc says it should be: by
  `create/3`, in `init/1`. The last test here pins that move.
  """

  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Persistence
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
    test "a prepared composition matches an unprepared one, bytes for bytes", %{
      space_id: space_id,
      vocation: vocation
    } do
      workspace = AgentTestHelpers.default_test_workspace()
      File.write!(Path.join(workspace, "AGENTS.md"), "# Project rules\n\nAlways use pnpm.\n")

      attrs = agent_attrs(space_id, vocation, %{workspace_path: workspace, mode: "plan"})
      on_exit(fn -> TmpSpace.cleanup(space_id, attrs.name, attrs.sandbox_backend) end)

      unprepared_text = attrs |> Init.build_active_state(client_config()) |> system_text()

      prepared_text =
        attrs |> Init.prepare() |> Init.build_active_state(client_config()) |> system_text()

      # Both compositions really composed — the workspace's `AGENTS.md` is in
      # each — and the prepared result is what the unprepared one would have
      # produced.
      assert unprepared_text =~ "Always use pnpm."
      assert prepared_text =~ "Always use pnpm."
      assert prepared_text == unprepared_text

      # And the prepared one reused the caller's work rather than composing
      # again: `build_active_state/2` reads the `:prepared` attrs key.
      assert %{prepared: prepared} = Init.prepare(attrs)
      assert is_tuple(prepared)
    end
  end

  # Composing no longer creates the scratch directory — that was an accident of
  # the `AGENTS.md` read going through `ShellCmd` — so a scratch path that cannot
  # be made now fails where `TmpSpace`'s own doc says it should: in `init/1`, as
  # the start's own error, rather than as a raise out of a caller that is merely
  # composing a prompt.
  describe "a scratch directory that cannot be made" do
    test "surfaces from the child's init, not out of the composing caller", %{
      space_id: space_id,
      vocation: vocation
    } do
      attrs =
        agent_attrs(space_id, vocation, %{
          name: "prepare-fail-#{System.unique_integer([:positive])}",
          workspace_path: AgentTestHelpers.default_test_workspace()
        })

      {:ok, _row} = Persistence.insert_agent(attrs)

      # A *file* where the scratch directory goes: `File.dir?` is false and
      # `File.mkdir_p!` raises `File.Error{reason: :eexist}`.
      scratch = TmpSpace.agent_dir(space_id, attrs.name, attrs.sandbox_backend)
      File.mkdir_p!(Path.dirname(scratch))
      File.write!(scratch, "")
      on_exit(fn -> File.rm(scratch) end)

      # Composition does not need the directory, so it succeeds...
      assert %{prepared: prepared} = Init.prepare(attrs)
      assert is_tuple(prepared)

      # ...and the failure lands in `init/1`, which `DynamicSupervisor.start_child/2`
      # turns into `{:error, {exception, stacktrace}}` — the shape the supervisor
      # already forwards to its callers. Nothing rescues it and nothing logs it.
      assert {:error, {%File.Error{}, _stacktrace}} =
               Supervisor.fetch_or_start_agent(space_id, %{name: attrs.name})
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
