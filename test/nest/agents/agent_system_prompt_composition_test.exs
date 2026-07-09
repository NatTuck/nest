defmodule Nest.Agents.AgentSystemPromptCompositionTest do
  @moduledoc """
  Tests for the system-prompt composition in
  `Nest.Agents.Agent.ChatPipeline` (the workspace line, the
  mode catalog, the AGENTS.md section, etc.). Extracted from
  `agent_chat_test.exs` so the chat-flow file stays under the
  500-line credo limit.
  """
  use Nest.DataCase, async: true

  import Mimic

  alias Nest.LLM.MockClient
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
    test "vocation system_prompt gets the mode catalog and a [Workspace] section" do
      valid_caps = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => []}
      }

      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "TestSysPrompt-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Base prompt.",
          tools: [],
          modes: %{
            "build" => %{
              "description" => "You're clear to edit the project in the workspace.",
              "caps" => valid_caps
            }
          }
        })

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation.id,
          workspace_path: "/tmp/test-workspace-#{System.unique_integer([:positive])}"
        })

      # The system prompt isn't on any broadcast; only the agent's
      # process state has it. Kept on the get_system_prompt GenServer
      # call. Future work: include it on the chat:status payload.
      system_prompt = get_system_prompt(pid)

      assert system_prompt =~ "Base prompt."
      assert system_prompt =~ "\n\n[Available modes]\n\n"
      assert system_prompt =~ ~s(- build: Read only "/")
      assert system_prompt =~ "Network disabled"
      assert system_prompt =~ "You're clear to edit the project in the workspace."
      assert system_prompt =~ "\n\nWorkspace and tool working directory: /tmp/test-workspace-"
      # `compact` is rendered into the catalog alongside the
      # user-configured modes, with `Vocations.compact_description/0`
      # as the body. The `[mode: compact]` prefix lives only in
      # the per-call suffix at runtime, not in the initial prompt.
      assert system_prompt =~ ~r/^- compact: We are out of context.*summary alone\.\.$/m
    end

    test "no workspace line when workspace_path is nil" do
      valid_caps = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => []}
      }

      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "TestNoWorkspace-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Chat only.",
          tools: [],
          modes: %{
            "chat" => %{
              "description" => "General conversation.",
              "caps" => valid_caps
            }
          }
        })

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation.id
        })

      system_prompt = get_system_prompt(pid)

      assert system_prompt =~ "Chat only."
      refute system_prompt =~ "Workspace and tool working directory"
    end

    test "compact-mode body lives once in the [Available modes] list" do
      valid_caps = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => []}
      }

      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "TestCompactPar-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Base.",
          tools: [],
          modes: %{
            "chat" => %{
              "description" => "Just chatting.",
              "caps" => valid_caps
            }
          }
        })

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation.id,
          workspace_path: "/tmp/test-compact-#{System.unique_integer([:positive])}"
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
      valid_caps = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => []}
      }

      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "TestCtxCfg-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "x",
          tools: [],
          modes: %{"chat" => %{"description" => "Chat", "caps" => valid_caps}}
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

    test "no context limit (no configured value and no Models cache hit) omits the section" do
      # MiniMax-M2.5 exists in the test config but has no
      # `context-limit` set, so `configured_context_limit/1`
      # returns nil. The Models GenServer's cache only
      # knows about models from the mocked `/models` responses;
      # without a hit there, the context-limit section is
      # entirely omitted from the prompt (no `:default`
      # placeholder, no async probe).
      valid_caps = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => []}
      }

      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "TestCtxDef-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "x",
          tools: [],
          modes: %{"chat" => %{"description" => "Chat", "caps" => valid_caps}}
        })

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "MiniMax-M2.5"},
          vocation_id: vocation.id
        })

      system_prompt = get_system_prompt(pid)

      refute system_prompt =~ "Context limit:"
      refute system_prompt =~ "default"
      refute system_prompt =~ "may differ"
    end
  end
end
