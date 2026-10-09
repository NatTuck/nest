defmodule Nest.Agents.AgentChatModeTest do
  @moduledoc """
  Tests for `Agent.chat/3` with explicit mode resolution.
  Extracted from `Nest.Agents.AgentChatTest` when that file
  crossed the 500-line credo limit. See that file for the
  chat-streaming coverage.
  """
  use Nest.DataCase, async: true

  import Mimic

  # `Agent.chat/2` is a `GenServer.cast`, so a fence placed after it covers the
  # *whole* turn: here a mocked LLM call, a real tool execution and a second
  # mocked LLM call. 500 ms is not a bound for that under load — a whole mocked
  # turn measured p50 18.7 ms / max 34.3 ms across 40 samples in the full
  # suite, but p50 926 ms / max 1534 ms (39 of 40 over 500 ms) under 48 CPU
  # burners. 2000 ms is ~100x the in-suite median and stays under ExUnit's 5 s
  # per-test timeout, so a genuinely stuck turn still fails — as a stuck turn,
  # not as a flake. (Measured on the spawn turn in `sub_agent_tools_test.exs`;
  # the turns in this file are the same class.)
  @turn_fence_ms 2_000

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine

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
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "Read foo", "build")

      # Vocation-less agent has no "build" mode, falls back to "chat"
      assert_receive {:chat_message,
                      {:user,
                       %{
                         parts: [%Part.Text{text: "[mode: chat]\nRead foo"}],
                         metadata: %{"mode" => "chat"}
                       }}},
                     500

      await_idle(pid)
    end

    test "falls back to default mode when requested mode is unknown" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "Hello", "nonexistent-mode")

      assert_receive {:chat_message,
                      {:user,
                       %{
                         parts: [%Part.Text{text: "[mode: chat]\nHello"}],
                         metadata: %{"mode" => "chat"}
                       }}},
                     500

      await_idle(pid)
    end

    test "uses agent's current mode when no mode is passed" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "Hello")

      assert_receive {:chat_message,
                      {:user,
                       %{
                         parts: [%Part.Text{text: "[mode: chat]\nHello"}],
                         metadata: %{"mode" => "chat"}
                       }}},
                     500

      await_idle(pid)
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

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation.id
        })

      :ok = Agent.chat(pid, "Run", "build")

      assert_receive {:chat_message,
                      {:user,
                       %{
                         parts: [%Part.Text{text: "[mode: build]\nRun"}],
                         metadata: %{"mode" => "build"}
                       }}},
                     500

      await_idle(pid)
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

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation.id
        })

      :ok = Agent.chat(pid, "Hello", "nonexistent")

      assert_receive {:chat_message,
                      {:user,
                       %{
                         parts: [%Part.Text{text: "[mode: build]\nHello"}],
                         metadata: %{"mode" => "build"}
                       }}},
                     500

      await_idle(pid)
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

      {pid, _agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation.id})

      # The externally visible signals of the mode are the user
      # message's `metadata.mode` field AND the `currentMode` on
      # each `chat:status` payload. The agent now persists
      # `state.live.mode` between chats ("sticky mode"), and broadcasts
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

    test "state.live.mode is updated to the resolved mode after a chat (sticky mode)" do
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
      assert state.live.mode == "build"

      # Send a chat with mode "plan". The agent's state.live.mode
      # should update to "plan".
      :ok = Agent.chat(pid, "Plan this", "plan")
      await_idle(pid)
      state = :sys.get_state(pid)
      assert state.live.mode == "plan"

      # The next chat without an explicit mode arg uses the
      # updated state.live.mode — confirms sticky mode is wired
      # through handle_chat's `mode = requested_mode || state.live.mode`
      # fallback.
      :ok = Agent.chat(pid, "And another")
      await_idle(pid)
      state = :sys.get_state(pid)
      assert state.live.mode == "plan"
    end

    test "state.live.mode falls back to vocation default when the requested mode is unknown" do
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

      {pid, _agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation.id})

      :ok = Agent.chat(pid, "Hello", "nonexistent")

      # The fallback (vocation default, lex-first: "build") is
      # written to state.live.mode.
      state = :sys.get_state(pid)
      assert state.live.mode == "build"

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

      {pid, _agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation.id})

      :ok = Agent.chat(pid, "Hi", "nonexistent")

      assert_receive {:chat_message,
                      {:user,
                       %{
                         parts: [%Part.Text{text: "[mode: build]\nHi"}],
                         metadata: %{"mode" => "build"}
                       }}},
                     500

      await_idle(pid)
    end
  end

  # Wait until the agent has settled to `:idle`, on the machine's own status
  # rather than the `chat:status` broadcast: a missed or reordered broadcast can
  # never be the reason this fails, and the condition waited on is exactly the
  # one the test-teardown invariant checks. See `@turn_fence_ms` for the budget.
  defp await_idle(pid) do
    assert Eventually.eventually(
             fn -> Machine.status_for(:sys.get_state(pid).live.machine) == :idle end,
             timeout: @turn_fence_ms
           )
  end
end
