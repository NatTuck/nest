defmodule Nest.Agents.AgentSystemPromptCompositionTest do
  @moduledoc """
  Tests for the system-prompt composition in
  `Nest.Agents.Agent.SystemPrompt` (the workspace line, the universal modes
  section, the AGENTS.md section, etc.). Extracted from
  `agent_chat_test.exs` so the chat-flow file stays under the
  500-line credo limit.
  """
  use Nest.DataCase, async: true

  import Mimic

  import Nest.Test.TmpCleanup

  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.LLM.MockClient
  alias Nest.Sandbox.Mounts
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  describe "vocation system_prompt composition" do
    test "vocation system_prompt gets the universal modes section and a [Workspace] section" do
      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "TestSysPrompt-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Base prompt.",
          tools: ["shell"]
        })

      workspace = new_ws("test-workspace")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation.id,
          workspace_path: workspace
        })

      # The system prompt isn't on any broadcast; only the agent's
      # process state has it. Kept on the get_system_prompt GenServer
      # call. Future work: include it on the chat:status payload.
      system_prompt = get_system_prompt(pid)

      assert system_prompt =~ "Base prompt."
      assert system_prompt =~ "\n\n[Available modes]\n\n"

      # The modes are universal constants now, so the section is the same bytes
      # for every vocation — including this one, whose stored `modes` map is dead
      # data (`Nest.Modes.catalog/2`).
      assert system_prompt =~ "**`plan`**"
      assert system_prompt =~ "**`act`**"
      assert system_prompt =~ "shown on every message you receive"
      # The space's sandbox enforces `plan`, so the one space-specific sentence
      # in the modes section says the restriction is real. (The *network* is not
      # a mode's — it is the space's, and the tool sections below state it.)
      assert system_prompt =~ "is enforced by the sandbox"
      refute system_prompt =~ "cannot enforce"
      # The vocation's own per-mode description is no longer rendered anywhere:
      # the capability/posture content lives in the universal text now.
      refute system_prompt =~ "You're clear to edit the project in the workspace."

      assert system_prompt =~ "\n\nWorkspace and tool working directory: #{workspace}"

      # The network is a space property, so the tool sections state it. This
      # space is a bwrap space with the column's `true` default, so the setting
      # is a real permission rather than one the sandbox cannot enforce.
      assert system_prompt =~ "Network access is enabled for this space"

      # The identity line is composed by `PreSpawn` from the attrs the start
      # path built, so this pins that path's argument order: a transposed
      # `depth`/`mode` renders the mode where the depth belongs.
      assert system_prompt =~ "at spawn depth 0 of #{Config.configured_max_depth()}"
      # `compact` is rendered next to the modes, with
      # `Vocations.compact_description/0` as the body. The `[mode: compact]`
      # prefix lives only in the per-call suffix at runtime, not in the initial
      # prompt.
      assert system_prompt =~ "- compact: We are out of context"
      assert system_prompt =~ "summary alone."
      refute system_prompt =~ "[mode: compact]"
    end

    test "no workspace line when the mounts carry no workspace" do
      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "TestNoWorkspace-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Chat only.",
          tools: ["shell"]
        })

      # An agent always has its *space's* workspace now — every space has one,
      # so there is no per-agent way to reach this state. It is the composer's
      # own no-workspace clause, which a space row with no path would still
      # produce, so the composer is driven directly.
      system_prompt = compose_for(vocation, "bwrap", true)

      assert system_prompt =~ "Chat only."
      refute system_prompt =~ "Workspace and tool working directory"
    end

    test "a tool-less vocation gets no tool sections or caps, but keeps compact guidance" do
      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "TestNoTools-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Tool-less.",
          tools: []
        })

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation.id,
          workspace_path: new_ws("test-notools")
        })

      system_prompt = get_system_prompt(pid)

      assert system_prompt =~ "Tool-less."
      # No tools, so nothing for a mode to restrict: no modes section at all —
      # not even its prose. The `[Available modes]` marker stays, because the
      # compaction contract below it is what the runtime's `[mode: compact]`
      # suffix refers to.
      assert system_prompt =~ "\n\n[Available modes]\n\n"
      refute system_prompt =~ "**`plan`**"
      refute system_prompt =~ "**`act`**"
      refute system_prompt =~ "shown on every message you receive"
      # ... and the compaction contract survives anyway: a tool-less agent still
      # compacts.
      assert system_prompt =~ Vocations.compact_description()
      refute system_prompt =~ "Workspace and tool working directory"
      refute system_prompt =~ "Tool call budget"
      # The scratch directory is reached with `file-*` / `shell-cmd`, so a
      # tool-less vocation must not be told about one either (see
      # `SystemPrompt.tool_sections/3`).
      refute system_prompt =~ "Your own scratch directory"
      refute system_prompt =~ "errors in tool calls"
      # The network sentence is tool-gated too: a tool-less agent has no command
      # that could reach the network.
      refute system_prompt =~ "Network access"
      refute system_prompt =~ ~s(Read only "/")
    end

    test "compact-mode body lives once in the [Available modes] list" do
      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "TestCompactPar-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Base.",
          tools: []
        })

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation.id,
          workspace_path: new_ws("test-compact")
        })

      system_prompt = get_system_prompt(pid)

      # The compaction contract lives in the [Available modes] line
      # for `compact`, not as a standalone trailing paragraph. The
      # canonical wording is held by Vocations.compact_description/0.
      assert system_prompt =~ Vocations.compact_description()
      assert system_prompt =~ "Include incomplete tasks"
      assert system_prompt =~ "decisions made"
      assert system_prompt =~ "essential file paths"

      # The `[mode: compact]` prefix itself must NOT appear in the
      # initial system prompt — it lives only in the per-call suffix
      # the compactor appends at runtime.
      refute system_prompt =~ "[mode: compact]"
    end
  end

  describe "context-limit section" do
    test "configured context limit shows the confident value with its source" do
      # qwen3.5-plus has a configured context_limit in
      # priv/config.toml (512000). The system prompt should
      # render the "resolved from config" line, not the
      # "default" caveat.
      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "TestCtxCfg-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "x",
          tools: []
        })

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation.id
        })

      system_prompt = get_system_prompt(pid)

      assert system_prompt =~ "Context limit:"
      assert system_prompt =~ "tokens"
      assert system_prompt =~ "resolved from config"
      # The reserve/working-budget narrative should appear in the
      # prompt. qwen3.5-plus has a 512_000-token window; the
      # reserve is 20% = 102_400, leaving a 409_600 working budget.
      assert system_prompt =~ "102400"
      assert system_prompt =~ "reserved for compaction"
      assert system_prompt =~ "working token budget"
      assert system_prompt =~ "409600"
      # The prompt mentions the compaction guidance either in the
      # context-limit suffix (compaction tooling reference) or
      # in the [mode: compact] section.
      assert system_prompt =~ "compact"
      refute system_prompt =~ "default"
      refute system_prompt =~ "may differ"
    end

    test "falls back to the 128k default when no config and no Models cache hit" do
      # MiniMax-M2.5 exists in the test config but has no
      # `context-limit` set, so `configured_context_limit/1`
      # returns nil. The Models GenServer's cache only knows
      # about models from the mocked `/models` responses;
      # without a hit there, the context-limit resolution falls
      # back to the 128k `:default` floor, and the prompt still
      # renders a context-limit section (sourced from `default`).
      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "TestCtxDef-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "x",
          tools: []
        })

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "MiniMax-M2.5"},
          vocation_id: vocation.id
        })

      system_prompt = get_system_prompt(pid)

      assert system_prompt =~ "Context limit: 128000 tokens"
      assert system_prompt =~ "resolved from default"
      refute system_prompt =~ "may differ"
    end
  end

  describe "the space's network access" do
    # The network is the *space's*, not a mode's, so it is stated in the
    # tool-gated sections. Composed directly rather than through a started agent
    # because the `"none"` case is what the sentence has to get right and no
    # start path here builds a `"none"` space.
    test "states the setting, and that a `none` space cannot enforce it" do
      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "TestNetwork-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Base.",
          tools: ["shell"]
        })

      # An enforcing backend states the setting as a permission or a rule.
      assert compose_for(vocation, "bwrap", true) =~ "Network access is enabled for this space"
      assert compose_for(vocation, "bwrap", false) =~ "Network access is disabled for this space"
      refute compose_for(vocation, "bwrap", true) =~ "cannot enforce"

      # A `"none"` space has no sandbox, so it names the setting *and* says it
      # cannot be enforced — it must not claim a restriction that is not there.
      for {value, word} <- [{true, "enabled"}, {false, "disabled"}] do
        prompt = compose_for(vocation, "none", value)

        assert prompt =~ "Network access is #{word} for this space"
        assert prompt =~ "no sandbox to enforce it"
      end
    end
  end

  describe "a `\"none\"` space's scratch" do
    # A `"none"` space has no sandbox, so the agent's `/tmp` is the host's own and
    # nothing Nest does isolates or sweeps it. Its prompt says so and suggests a
    # directory named after the space. Every other backend's prompt is unchanged:
    # the system message is prefix-cache-visible, so its bytes must not move.
    test "states the caveat and the space-named suggestion" do
      mounts = Mounts.new(nil, nil, "none", 7, true, "clever-otter")

      prompt = compose_with(tool_vocation("NoneScratch"), mounts)

      assert prompt =~ "no sandbox, so `/tmp` is this host's own"
      assert prompt =~ "only your own scratch directory is cleaned up"
      assert prompt =~ "use `/tmp/nest/clever-otter/`"
    end

    test "states the caveat without inventing a path when the space name is unknown" do
      mounts = Mounts.new(nil, nil, "none", nil, true, nil)

      prompt = compose_with(tool_vocation("NoneNoName"), mounts)

      assert prompt =~ "no sandbox, so `/tmp` is this host's own"
      refute prompt =~ "/tmp/nest/"
    end

    test "leaves a bwrap agent's scratch section byte-identical" do
      mounts = Mounts.new(nil, nil, "bwrap", 7, true, nil)

      prompt = compose_with(tool_vocation("BwrapScratch"), mounts)

      assert prompt =~ "Your own scratch directory is `/tmp/agent/`"
      # The bytes right after the scratch sentence belong to the next section, so
      # anything appended to this one would break the adjacency.
      assert prompt =~ "under your own directory.\n\n\nNetwork access is enabled for this space"
      refute prompt =~ "no sandbox, so `/tmp` is this host's own"
      refute prompt =~ "/tmp/nest/"
    end
  end

  describe "the model section" do
    # `file-read`'s description states the image-input capability
    # unconditionally — the same text for every agent — so this section is the
    # only place an agent is told whether *its own* model has it. The verdict is
    # `Nest.Models.MultiModal.input_support/2`'s, which `file-read`'s media gate
    # reads too, so the two cannot disagree.
    test "states the model and what the catalog says it accepts" do
      stub_catalog([
        %{"name" => "vision-model", "provider" => "p", "multi_modal" => %{"input" => ["image"]}},
        %{"name" => "text-model", "provider" => "p", "multi_modal" => %{"input" => []}},
        %{"name" => "unknown-model", "provider" => "p", "multi_modal" => nil}
      ])

      vocation = tool_vocation("ModelSection")
      mounts = Mounts.new(nil, nil)

      assert compose_with(vocation, mounts, "vision-model") =~
               ~s(Your model is "vision-model". It accepts image input: `file-read` on a png, ) <>
                 "jpeg, gif or webp attaches the image to the conversation and you see it."

      assert compose_with(vocation, mounts, "text-model") =~
               ~s(Your model is "text-model". It declares text-only input, so `file-read` refuses an image.)

      assert compose_with(vocation, mounts, "unknown-model") =~
               ~s(Your model is "unknown-model". Nothing declares whether it accepts image input; ) <>
                 "`file-read` refuses an image with the reason if it cannot."

      # No model name → no section at all, rather than one naming nothing. The
      # callers that pass `nil` are the ones with no model to state (a vocation
      # prompt rendered for a row with no model), not agents that lost one.
      refute compose_with(vocation, mounts, nil) =~ "Your model is"
    end

    test "a tool-less vocation gets it too, right after the identity line" do
      # Identity, not a tool reference: an agent with nothing to call still has a
      # model, and the sentence is about what the model accepts, not about a tool
      # it may or may not have.
      stub_catalog([
        %{"name" => "text-model", "provider" => "p", "multi_modal" => %{"input" => []}}
      ])

      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "ModelNoTools-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Tool-less.",
          tools: []
        })

      prompt = compose_with(vocation, Mounts.new(nil, nil), "text-model")

      assert prompt =~ ~s(Your model is "text-model".)
      # Directly after the identity line, and with no tool section in between:
      # the tool-gated sections are absent for this vocation, so the model
      # sentence is followed by the context limit.
      assert prompt =~ "That may change when cloned.\n\n\nYour model is \"text-model\"."
      refute prompt =~ "Your own scratch directory"
      refute prompt =~ "Tool call budget"
    end
  end

  # Compose the prompt for a tool-capable vocation on `backend`, with the
  # space's network setting: no workspace and no scratch, so no section here
  # reads a file and the mounts only decide the network and enforcement
  # sentences.
  defp compose_for(vocation, backend, network_access) do
    compose_with(vocation, Mounts.new(nil, nil, backend, nil, network_access))
  end

  defp compose_with(vocation, mounts, model \\ nil) do
    {prompt, _tools, _vocation} =
      SystemPrompt.compose_vocation_config(vocation, mounts, {nil, nil}, "agent", 0, model)

    prompt
  end

  # A tool-capable vocation, so the tool-gated sections (the scratch sentence
  # among them) are rendered at all.
  defp tool_vocation(label) do
    {:ok, vocation} =
      Vocations.create_vocation(%{
        name: "#{label}-#{System.unique_integer([:positive])}",
        description: "Scratch caveat test",
        system_prompt: "Base.",
        tools: ["shell"]
      })

    vocation
  end

  # The merged catalog, as `Nest.Models.list/0` returns it. Stubbed wherever the
  # model section is under test: the section's verdict is a catalog lookup, and
  # the real catalog in the test environment is the checked-in `test/data`
  # config.
  defp stub_catalog(models), do: Mimic.stub(Nest.Models, :list, fn -> models end)

  # A real workspace directory outside /tmp: the scratch dir is bound at /tmp,
  # so a /tmp-rooted workspace is rejected, and a non-existent one too.
  defp new_ws(label) do
    dir =
      Path.join([
        File.cwd!(),
        "_build",
        "tmp",
        "#{label}-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> rm_tmp!(dir, label) end)
    dir
  end
end
