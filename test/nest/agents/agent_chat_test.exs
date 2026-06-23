defmodule Nest.Agents.AgentChatTest do
  @moduledoc """
  Agent chat tests: `chat/2`, delta handling, `chat/3` with mode,
  the Vocation struct in state, and system prompt composition.
  """
  use Nest.DataCase, async: false

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Test.TaskDrain
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)
    on_exit(fn -> TaskDrain.drain() end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  describe "chat/2" do
    test "broadcasts user message and LLM response via PubSub" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      assert_receive {:chat_message, {:user, %{index: 0, content: "[mode: chat]\nHello"}}},
                     100

      assert_receive {:chat_status, %{status: "streaming"}}, 100
      assert_receive {:chat_delta, _}, 100
      assert_receive {:chat_message, {:assistant, _}}, 100
      assert_receive {:chat_status, %{status: "idle"}}, 100
    end

    test "broadcasts status changes via PubSub" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      assert_receive {:chat_message, {:user, _}}, 100
      assert_receive {:chat_status, %{status: "streaming"}}, 100
      assert_receive {:chat_message, {:assistant, _}}, 100
      assert_receive {:chat_status, %{status: "idle"}}, 100
    end

    test "handles LLM error gracefully" do
      MockClient.set_error("Connection failed")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Hello")

          assert_receive {:chat_message, {:user, %{index: 0, content: "[mode: chat]\nHello"}}},
                         100

          assert_receive {:chat_error, _error}, 100
        end)

      assert log =~ "chat:error"
      assert log =~ "LLMRunner.handle_failed_response"
      assert log =~ "Connection failed"
    end

    test "LLM error path returns a RunState (Task body destructures successfully)" do
      MockClient.set_error("Connection failed")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Hello")

          assert_receive {:chat_message, {:user, %{index: 0, content: "[mode: chat]\nHello"}}},
                         100

          assert_receive {:chat_error, _error}, 100
        end)

      refute log =~ "MatchError"
      refute log =~ "no match of right hand side value"
    end

    test "accumulates delta content from streaming LLM response" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      assert_receive {:chat_message, {:user, _}}, 100

      # Accumulate deltas by content; known to be at least 1 for the
      # single set_response text. We match each as a known broadcast.
      assert_receive {:chat_delta, %{content: partial_text}}, 100

      # The assistant message broadcast carries the full accumulated
      # content as the externally visible result.
      assert_receive {:chat_message, {:assistant, %{content: full_text}}}, 100

      assert partial_text != ""
      assert full_text != ""
      assert String.contains?(full_text, partial_text) or partial_text == full_text
    end
  end

  describe "delta handling" do
    test "accumulates deltas with correct character counts" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      assert_receive {:chat_message, {:user, _}}, 100
      # At least one delta is expected for the single-text response.
      assert_receive {:chat_delta, %{chars_start: start, chars_end: end_pos}}, 100
      assert is_integer(start)
      assert is_integer(end_pos)
      assert end_pos > start
    end
  end

  describe "chat/3 with mode" do
    test "user message includes the resolved mode in metadata (vocation-less agent defaults to chat)" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Read foo", "build")

      # Vocation-less agent has no "build" mode, falls back to "chat"
      assert_receive {:chat_message,
                      {:user, %{content: "[mode: chat]\nRead foo", metadata: %{"mode" => "chat"}}}},
                     100
    end

    test "falls back to default mode when requested mode is unknown" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello", "nonexistent-mode")

      assert_receive {:chat_message,
                      {:user, %{content: "[mode: chat]\nHello", metadata: %{"mode" => "chat"}}}},
                     100
    end

    test "uses agent's current mode when no mode is passed" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      assert_receive {:chat_message,
                      {:user, %{content: "[mode: chat]\nHello", metadata: %{"mode" => "chat"}}}},
                     100
    end

    @tag :db_shared
    test "vocation with modes: requested mode is preserved when valid" do
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

      :ok = Agent.chat(pid, "Run", "build")

      assert_receive {:chat_message,
                      {:user, %{content: "[mode: build]\nRun", metadata: %{"mode" => "build"}}}},
                     100
    end

    @tag :db_shared
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

      # Default is the lexicographically first mode: "build"
      assert_receive {:chat_message,
                      {:user, %{content: "[mode: build]\nHello", metadata: %{"mode" => "build"}}}},
                     100
    end

    @tag :db_shared
    test "user messages carry the resolved mode in metadata" do
      valid_caps = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => []}
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

      assert_receive {:chat_message,
                      {:user,
                       %{content: "[mode: plan]\nPlan this", metadata: %{"mode" => "plan"}}}},
                     100

      assert_receive {:chat_status, %{status: "idle", currentMode: "plan"}}, 100
    end

    @tag :db_shared
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

    @tag :db_shared
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
      assert_receive {:chat_status, %{status: "idle", currentMode: "build"}}, 100
    end

    @tag :db_shared
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

      # The fallback to the vocation's default ("build", lex-first)
      # is externally visible on the user message's metadata.
      assert_receive {:chat_message,
                      {:user, %{content: "[mode: build]\nHi", metadata: %{"mode" => "build"}}}},
                     100
    end
  end

  describe "vocation in state" do
    @tag :db_shared
    test "state.vocation is populated on init when a vocation_id is provided" do
      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "StateVocation-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Test",
          tools: [],
          modes: %{
            "build" => %{"caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => []}}}
          }
        })

      {pid, _id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation.id})

      # No broadcast carries the full Vocation struct; the only way to
      # observe it is via the agent's process state. Kept as future
      # work: expose `state.vocation` via a GenServer call.
      state = :sys.get_state(pid)
      assert state.vocation != nil
      assert state.vocation.id == vocation.id
      assert state.vocation.name == vocation.name
    end

    test "state.vocation is nil when no vocation_id is provided" do
      {pid, _id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      state = :sys.get_state(pid)
      assert state.vocation == nil
    end
  end

  describe "system prompt composition" do
    # The system-prompt composition tests live in
    # `agent_system_prompt_composition_test.exs` (they were
    # extracted from this file when it crossed the 500-line credo
    # limit). See that file for the full coverage.
  end
end
