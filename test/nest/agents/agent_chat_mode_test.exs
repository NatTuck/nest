defmodule Nest.Agents.AgentChatModeTest do
  @moduledoc """
  Tests for `Agent.chat/3` with explicit mode resolution.
  Extracted from `Nest.Agents.AgentChatTest` when that file
  crossed the 500-line credo limit. See that file for the
  chat-streaming coverage.
  """
  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
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

  describe "chat/3 with mode" do
    test "user message includes the resolved mode in metadata (vocation-less agent defaults to chat)" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Read foo", "build")

      # Vocation-less agent has no "build" mode, falls back to "chat"
      assert_receive {:chat_message,
                      {:user,
                       %{
                         parts: [%Part.Text{text: "[mode: chat]\nRead foo"}],
                         metadata: %{"mode" => "chat"}
                       }}},
                     100
    end

    test "falls back to default mode when requested mode is unknown" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello", "nonexistent-mode")

      assert_receive {:chat_message,
                      {:user,
                       %{
                         parts: [%Part.Text{text: "[mode: chat]\nHello"}],
                         metadata: %{"mode" => "chat"}
                       }}},
                     100
    end

    test "uses agent's current mode when no mode is passed" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      assert_receive {:chat_message,
                      {:user,
                       %{
                         parts: [%Part.Text{text: "[mode: chat]\nHello"}],
                         metadata: %{"mode" => "chat"}
                       }}},
                     100
    end

    test "vocation with modes: requested mode is preserved when valid" do
      valid_caps = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
      }

      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "TestVocation-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Test",
          tools: [],
          modes: %{
            "build" => %{"caps" => valid_caps},
            "plan" => %{"caps" => valid_caps}
          }
        })

      {pid, agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation.id
        })

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Run", "build")

      assert_receive {:chat_status, %{status: "idle"}}, 500

      assert_received {:chat_message,
                       {:user,
                        %{
                          parts: [%Part.Text{text: "[mode: build]\nRun"}],
                          metadata: %{"mode" => "build"}
                        }}}
    end

    test "vocation with modes: unknown mode falls back to the vocation's default" do
      valid_caps = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => []}
      }

      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "TestVocation-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Test",
          tools: [],
          modes: %{
            "build" => %{"caps" => valid_caps},
            "plan" => %{"caps" => valid_caps}
          }
        })

      {pid, agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation.id
        })

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello", "nonexistent")

      assert_receive {:chat_status, %{status: "idle"}}, 500

      # Default is the lexicographically first mode: "build"
      assert_received {:chat_message,
                       {:user,
                        %{
                          parts: [%Part.Text{text: "[mode: build]\nHello"}],
                          metadata: %{"mode" => "build"}
                        }}}
    end

    test "user messages carry the resolved mode in metadata" do
      valid_caps = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
      }

      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "StickyMode-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Test",
          tools: [],
          modes: %{
            "build" => %{"caps" => valid_caps},
            "plan" => %{"caps" => valid_caps}
          }
        })

      {pid, agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation.id})

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      # The externally visible signals of the mode are the user
      # message's `metadata.mode` field AND the `currentMode` on
      # each `chat:status` payload. The agent now persists
      # `state.mode` between chats ("sticky mode"), and broadcasts
      # it on every status push so the client can keep the
      # dropdown in sync.
      :ok = Agent.chat(pid, "Plan this", "plan")

      assert_receive {:chat_status, %{status: "idle", currentMode: "plan"}}, 500

      assert_received {:chat_message,
                       {:user,
                        %{
                          parts: [%Part.Text{text: "[mode: plan]\nPlan this"}],
                          metadata: %{"mode" => "plan"}
                        }}}
    end

    test "state.mode is updated to the resolved mode after a chat (sticky mode)" do
      valid_caps = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => []}
      }

      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "StickyState-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Test",
          tools: [],
          modes: %{
            "build" => %{"caps" => valid_caps},
            "plan" => %{"caps" => valid_caps}
          }
        })

      {pid, _agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation.id})

      # Initial state: vocation default (lex-first: "build").
      state = :sys.get_state(pid)
      assert state.mode == "build"

      # Send a chat with mode "plan". The agent's state.mode
      # should update to "plan".
      :ok = Agent.chat(pid, "Plan this", "plan")
      state = :sys.get_state(pid)
      assert state.mode == "plan"

      # The next chat without an explicit mode arg uses the
      # updated state.mode — confirms sticky mode is wired
      # through handle_chat's `mode = requested_mode || state.mode`
      # fallback.
      :ok = Agent.chat(pid, "And another")
      state = :sys.get_state(pid)
      assert state.mode == "plan"
    end

    test "state.mode falls back to vocation default when the requested mode is unknown" do
      valid_caps = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => []}
      }

      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "StickyFallback-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Test",
          tools: [],
          modes: %{
            "build" => %{"caps" => valid_caps},
            "plan" => %{"caps" => valid_caps}
          }
        })

      {pid, agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation.id})

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello", "nonexistent")

      # The fallback (vocation default, lex-first: "build") is
      # written to state.mode.
      state = :sys.get_state(pid)
      assert state.mode == "build"

      # And reflected in the chat:status broadcast.
      assert_receive {:chat_status, %{status: "idle", currentMode: "build"}}, 500
    end

    test "user message metadata falls back to vocation's default mode" do
      valid_caps = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => []}
      }

      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "InvalidMode-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Test",
          tools: [],
          modes: %{
            "build" => %{"caps" => valid_caps},
            "plan" => %{"caps" => valid_caps}
          }
        })

      {pid, agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation.id})

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hi", "nonexistent")

      assert_receive {:chat_status, %{status: "idle"}}, 500

      # The fallback to the vocation's default ("build", lex-first)
      # is externally visible on the user message's metadata.
      assert_received {:chat_message,
                       {:user,
                        %{
                          parts: [%Part.Text{text: "[mode: build]\nHi"}],
                          metadata: %{"mode" => "build"}
                        }}}
    end
  end
end
