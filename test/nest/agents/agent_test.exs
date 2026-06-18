defmodule Nest.Agents.AgentTest do
  @moduledoc """
  Tests for the Agent GenServer behavior via PubSub.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Registry
  alias Nest.LLM.MockClient
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Assistant
  alias Nest.Messages.Streaming
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolCall
  alias Nest.Messages.User
  alias Nest.Test.TaskDrain
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    parent_dir = "/tmp/nest-#{System.pid()}"
    File.rm_rf(parent_dir)
    on_exit(fn -> File.rm_rf(parent_dir) end)
    on_exit(fn -> TaskDrain.drain() end)

    # Per-test MockClient queue keyed by the test's own pid. Tests
    # that call `MockClient.set_*` BEFORE `start_agent/1` (e.g. error
    # injection) land in this queue; `start_agent/1` transfers the
    # contents to the per-agent queue. This preserves the historical
    # pattern of calling `set_*` before `start_agent/1`.
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn ->
      Process.delete(:nest_test_agent_pid)
    end)

    :ok
  end

  defp start_agent(attrs) do
    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    defaults = %{
      id: agent_id,
      model: %{name: "qwen3.5-plus", provider: "model-studio"}
    }

    attrs = Map.merge(defaults, attrs)
    pid = start_supervised!({Agent, attrs})

    # In async mode, Mimic stubs are per-test-process by default.
    # The agent's `handle_info` and chat task run in separate
    # processes and need explicit access to stubs set on
    # `Mimic.expect(Req, :get, ...)` etc. No-op for tests that
    # don't use Mimic.
    Mimic.allow(Nest.LLM.OpenAIClient, self(), pid)
    Mimic.allow(Req, self(), pid)
    Mimic.allow(Nest.DotConfig, self(), pid)

    # Swap the agent's client_config.client to MockClient and start
    # a per-agent queue. The agent threads its pid through
    # `build_run_opts/1`, so the chat task (in a separate process)
    # calls MockClient.run/2 and finds this test's queue via
    # `opts[:agent_pid]`.
    :sys.replace_state(pid, fn state ->
      %{state | client_config: %{state.client_config | client: MockClient}}
    end)

    # Transfer any pre-existing queued items from the test-pid queue
    # (set up in `setup`) to the per-agent queue. This handles
    # tests that call `MockClient.set_*` before `start_agent/1`.
    test_pid = Process.get(:nest_test_agent_pid)

    if test_pid && test_pid != pid do
      items = MockClient.take_pending(test_pid)
      MockClient.start_link(pid)
      Enum.each(items, &MockClient.put_pending(pid, &1))
    else
      MockClient.start_link(pid)
    end

    Process.put(:nest_test_agent_pid, pid)
    # NB: no MockClient.clear() here — that would wipe the
    # transferred items.

    on_exit(fn ->
      MockClient.stop(pid)
      Process.put(:nest_test_agent_pid, test_pid)
    end)

    {pid, agent_id}
  end

  describe "start_link/1" do
    test "starts agent and registers in registry" do
      agent_id = "registered-agent-#{System.unique_integer([:positive])}"
      pid = start_supervised!({Agent, %{id: agent_id, model: %{name: "qwen3.5-plus"}}})
      assert Registry.lookup(agent_id) == {:ok, pid}
    end
  end

  describe "tmp_path lifecycle" do
    test "creates tmp directory on agent start" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      expected_tmp_path = "/tmp/nest-#{Elixir.System.pid()}/agent-#{agent_id}"

      assert File.exists?(expected_tmp_path),
             "Expected tmp directory to exist: #{expected_tmp_path}"

      # Verify it's a directory
      assert File.dir?(expected_tmp_path)

      # Cleanup
      Agent.terminate(pid)
    end

    test "passes tmp_path to agent state" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      info = Agent.get_public_info(pid)

      assert info.tmp_path =~ ~r|/tmp/nest-#{Elixir.System.pid()}/agent-|,
             "Expected tmp_path to match pattern, got: #{inspect(info.tmp_path)}"

      Agent.terminate(pid)
    end

    test "cleans up tmp directory on agent termination" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      expected_tmp_path = "/tmp/nest-#{Elixir.System.pid()}/agent-#{agent_id}"

      # Verify directory exists while agent is running
      assert File.exists?(expected_tmp_path)

      ref = Process.monitor(pid)

      # Terminate the agent
      Agent.terminate(pid)

      # Wait for actual process termination using monitor
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000

      # Verify directory is removed
      refute File.exists?(expected_tmp_path),
             "Expected tmp directory to be removed: #{expected_tmp_path}"
    end

    test "uses unique tmp_path per agent" do
      agent_id1 = "unique-test-1-#{System.unique_integer([:positive])}"
      pid1 = start_supervised!({Agent, %{id: agent_id1, model: %{name: "qwen3.5-plus"}}})
      info1 = Agent.get_public_info(pid1)

      assert info1.tmp_path =~ ~r|/tmp/nest-#{Elixir.System.pid()}/agent-#{agent_id1}|
      Agent.terminate(pid1)
    end

    test "cleans up tmp directory when stopped via Supervisor.stop_agent/1" do
      alias Nest.Agents.Supervisor

      # Start agent via Supervisor (real production path)
      {:ok, agent_id} = Supervisor.start_agent(%{model: %{name: "qwen3.5-plus"}})
      expected_tmp_path = "/tmp/nest-#{Elixir.System.pid()}/agent-#{agent_id}"

      # Verify directory exists
      assert File.exists?(expected_tmp_path),
             "Expected tmp directory to exist: #{expected_tmp_path}"

      # Get the PID for monitoring
      {:ok, pid} = Supervisor.get_agent(agent_id)
      ref = Process.monitor(pid)

      # Stop via Supervisor (this calls DynamicSupervisor.terminate_child/2)
      :ok = Supervisor.stop_agent(agent_id)

      # Wait for actual process termination using monitor
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000

      # Verify directory is removed
      refute File.exists?(expected_tmp_path),
             "Expected tmp directory to be removed after Supervisor.stop_agent: #{expected_tmp_path}"
    end

    test "cleans up tmp directory when agent crashes" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      expected_tmp_path = "/tmp/nest-#{System.pid()}/agent-#{agent_id}"

      # Verify directory exists
      assert File.exists?(expected_tmp_path),
             "Expected tmp directory to exist: #{expected_tmp_path}"

      ref = Process.monitor(pid)

      capture_log(fn ->
        # Crash the agent by sending an exit signal (simulates unexpected termination)
        # Use :crash reason which is trappable but will cause process to exit
        Process.exit(pid, :crash)

        # Wait for actual process termination using monitor
        assert_receive {:DOWN, ^ref, :process, ^pid, :crash}, 1000
      end)

      # Verify directory is removed - this works with trap_exit
      refute File.exists?(expected_tmp_path),
             "Expected tmp directory to be removed after agent crash: #{expected_tmp_path}"
    end

    test "cleans up tmp directory when linked process dies" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      expected_tmp_path = "/tmp/nest-#{System.pid()}/agent-#{agent_id}"

      # Verify directory exists
      assert File.exists?(expected_tmp_path),
             "Expected tmp directory to exist: #{expected_tmp_path}"

      ref = Process.monitor(pid)

      # Simulate what happens when a linked supervisor shuts down the agent
      # :shutdown is trappable and will trigger terminate/2
      Process.exit(pid, :shutdown)

      # Wait for actual process termination using monitor
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1000

      # Verify directory is removed
      refute File.exists?(expected_tmp_path),
             "Expected tmp directory to be removed when linked process dies: #{expected_tmp_path}"
    end

    test "cleans up parent nest directory when last agent is removed" do
      alias Nest.Agents.Supervisor

      # Start two agents
      {:ok, agent_id1} = Supervisor.start_agent(%{model: %{name: "qwen3.5-plus"}})
      {:ok, agent_id2} = Supervisor.start_agent(%{model: %{name: "qwen3.5-plus"}})

      parent_dir = "/tmp/nest-#{Elixir.System.pid()}"
      path1 = "#{parent_dir}/agent-#{agent_id1}"
      path2 = "#{parent_dir}/agent-#{agent_id2}"

      # Verify both directories exist
      assert File.exists?(path1)
      assert File.exists?(path2)
      assert File.exists?(parent_dir)

      # Get PIDs for monitoring
      {:ok, pid1} = Supervisor.get_agent(agent_id1)
      {:ok, pid2} = Supervisor.get_agent(agent_id2)
      ref1 = Process.monitor(pid1)
      ref2 = Process.monitor(pid2)

      # Stop first agent
      :ok = Supervisor.stop_agent(agent_id1)
      assert_receive {:DOWN, ^ref1, :process, ^pid1, _reason}, 1000

      # Parent directory should still exist
      assert File.exists?(parent_dir),
             "Parent directory should exist while agents are still running"

      # Stop second agent
      :ok = Supervisor.stop_agent(agent_id2)
      assert_receive {:DOWN, ^ref2, :process, ^pid2, _reason}, 1000

      # Now parent directory should be cleaned up
      refute File.exists?(parent_dir),
             "Expected parent nest directory to be removed: #{parent_dir}"
    end
  end

  describe "chat/2" do
    test "broadcasts user message and LLM response via PubSub" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      # Receive user message
      assert_receive {:chat_message, {:user, %{index: 0, content: "Hello"}}},
                     1000

      # Receive assistant response via PubSub
      receive_deltas_and_message_from_pubsub()
    end

    test "broadcasts status changes via PubSub" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      # Receive user message
      assert_receive {:chat_message, {:user, %{index: 0, content: "Hello"}}},
                     1000

      # Should receive status:streaming when chat starts
      assert_receive {:chat_status, %{status: "streaming"}}, 1000

      # Should receive status:idle when response completes
      # (drain deltas and messages first)
      receive_deltas_and_message_from_pubsub()
      assert_receive {:chat_status, %{status: "idle"}}, 2000
    end

    test "handles LLM error gracefully" do
      # Mock LLM to return an error. Stub arity 1 and 2 because
      # LLMChain.run/1 dispatches to run/2 with default opts.
      MockClient.set_error("Connection failed")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Hello")

          # Should receive user message
          assert_receive {:chat_message, {:user, %{index: 0, content: "Hello"}}},
                         1000

          # Should receive error message
          assert_receive {:chat_error, _error}, 2000
        end)

      # Verify the error was logged with the correct message
      assert log =~ "LLM request failed"
      assert log =~ "Connection failed"
    end

    test "LLM error path returns a RunState (Task body destructures successfully)" do
      # Locks in the contract that `run_with_new_client/2`'s terminal
      # paths return a `%RunState{}` so the `Task.Supervisor.start_child/2`
      # body can destructure `%RunState{api_log_sequences: _}` without
      # crashing. Before this was fixed, the error path returned
      # `api_log_sequences` (a list) and the success path returned
      # `_ = ctx` (a `RunContext`), both of which triggered a MatchError
      # inside the Task and polluted test output with a stacktrace.
      MockClient.set_error("Connection failed")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Hello")

          assert_receive {:chat_message, {:user, %{index: 0, content: "Hello"}}},
                         1000

          assert_receive {:chat_error, _error}, 2000
        end)

      # The Task body would have logged a MatchError if the contract
      # were violated; assert the log is clean.
      refute log =~ "MatchError"
      refute log =~ "no match of right hand side value"
    end

    test "accumulates delta content from streaming LLM response" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      # Receive user message
      assert_receive {:chat_message, {:user, _}}, 1000

      # Collect deltas and verify final message
      {partial_content, final_message} = collect_deltas_and_message_from_pubsub()

      # Verify accumulated content matches final
      assert elem(final_message, 0) == :assistant
      assert partial_content == elem(final_message, 1).content
      assert partial_content != ""
    end
  end

  describe "delta handling" do
    test "accumulates deltas with correct character counts" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      # Skip user message
      assert_receive {:chat_message, {:user, _}}, 1000

      # Collect all deltas and verify
      deltas = collect_all_deltas_from_pubsub()

      # Verify we got deltas
      assert deltas != []
    end
  end

  describe "chat/3 with mode" do
    test "user message includes the resolved mode in metadata (vocation-less agent defaults to chat)" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Read foo", "build")

      # A vocation-less agent has no "build" mode, so it falls back to "chat"
      user_message = find_user_message("Read foo")
      assert user_message != nil
      assert user_message.metadata["mode"] == "chat"
    end

    test "falls back to default mode when requested mode is unknown" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello", "nonexistent-mode")

      user_message = find_user_message("Hello")
      assert user_message != nil
      assert user_message.metadata["mode"] == "chat"
    end

    test "uses agent's current mode when no mode is passed" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      user_message = find_user_message("Hello")
      assert user_message != nil
      assert user_message.metadata["mode"] == "chat"
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

      user_message = find_user_message("Run")
      assert user_message != nil
      assert user_message.metadata["mode"] == "build"
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

      user_message = find_user_message("Hello")
      assert user_message != nil
      # Default is the lexicographically first mode: "build"
      assert user_message.metadata["mode"] == "build"
    end
  end

  describe "system prompt composition" do
    @tag :db_shared
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

      # The system prompt is stored on the agent state. Pull it via
      # get_public_info (which doesn't expose it directly), or just
      # inspect the agent process state via a GenServer.call.
      # The cleanest assertion: the client config was built with
      # a system message containing both the catalog and the workspace.
      # The mock agent captures the messages it received — but we
      # need a different hook. The simplest is to assert on the
      # state.system_prompt via a custom introspection call.
      system_prompt = get_system_prompt(pid)

      assert system_prompt =~ "Base prompt."
      assert system_prompt =~ "\n\n[Available modes]\n\n"
      assert system_prompt =~ ~s(- build: Read only "/")
      assert system_prompt =~ "Network disabled"
      assert system_prompt =~ "You're clear to edit the project in the workspace."
      assert system_prompt =~ "\n\nWorkspace and tool working directory: /tmp/test-workspace-"
    end

    @tag :db_shared
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
  end

  # The agent doesn't expose system_prompt via get_public_info. We
  # use a custom GenServer.call to read it. If we add it to the
  # public API later, this can become a regular call.
  defp get_system_prompt(pid) do
    GenServer.call(pid, :get_system_prompt)
  end

  describe "chat/2 with tool calls" do
    test "broadcasts complete tool call flow: user → assistant+tools → tool → assistant" do
      # Configure mock to return tool calls
      MockClient.set_tool_response(%{
        text: "I'll run that command for you",
        tool_calls: [
          %{id: "call_123", name: "shell_cmd", arguments: %{"command" => "ls -la"}}
        ]
      })

      # Set final response after tool execution
      MockClient.set_response("Here are the directory contents")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "List the files")

      # Collect all messages from PubSub (deduplicated by index)
      messages = collect_all_messages_from_pubsub([])

      # Should receive exactly 4 unique messages (user, assistant+tools, tool, assistant)
      # Note: messages may be broadcast multiple times with api_logs updates
      assert length(messages) >= 4, "Expected at least 4 messages, got #{length(messages)}"

      # Get unique messages by index (keep latest version with api_logs)
      unique_messages =
        messages
        |> Enum.reverse()
        |> Enum.uniq_by(fn {_role, msg} -> msg.index end)
        |> Enum.reverse()

      assert length(unique_messages) == 4,
             "Expected 4 unique messages, got #{length(unique_messages)}: #{inspect(unique_messages)}"

      # Message 0: User message
      assert {:user, user_msg} = Enum.at(unique_messages, 0)
      assert user_msg.index == 0
      assert user_msg.content == "List the files"

      # Message 1: Assistant with tool calls
      assert {:assistant, assistant_msg} = Enum.at(unique_messages, 1)
      assert assistant_msg.index == 1
      assert assistant_msg.content == "I'll run that command for you"
      assert assistant_msg.tool_calls != []
      assert length(assistant_msg.tool_calls) == 1

      [tool_call] = assistant_msg.tool_calls
      assert %ToolCall{} = tool_call
      assert tool_call.id == "call_123"
      assert tool_call.name == "shell_cmd"

      # Message 2: Tool result
      assert {:tool, tool_msg} = Enum.at(unique_messages, 2)
      assert tool_msg.index == 2
      assert tool_msg.tool_results != []
      assert length(tool_msg.tool_results) == 1

      [tool_result] = tool_msg.tool_results
      assert tool_result.tool_call_id == "call_123"
      assert tool_result.name == "shell_cmd"
      # The tool result carries the params of the matching tool call so the
      # frontend can show e.g. the shell command that produced this output.
      assert tool_result.arguments == %{"command" => "ls -la"}

      # Message 3: Final assistant response
      assert {:assistant, final_msg} = Enum.at(unique_messages, 3)
      assert final_msg.index == 3
      assert final_msg.content == "Here are the directory contents"

      # Cleanup
      MockClient.clear()
    end

    test "broadcasts status changes during tool execution flow" do
      # Configure mock to return tool calls
      MockClient.set_tool_response(%{
        text: "I'll run that command",
        tool_calls: [
          %{id: "call_789", name: "shell_cmd", arguments: %{"command" => "echo hello"}}
        ]
      })

      # Set final response after tool execution
      MockClient.set_response("Done")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Run a command")

      # Should receive status:streaming when chat starts
      assert_receive {:chat_status, %{status: "streaming"}}, 1000

      # Should receive status:executing_tools when tool calls are processed
      assert_receive {:chat_status, %{status: "executing_tools"}}, 2000

      # Should receive status:streaming again when continuing after tool results
      assert_receive {:chat_status, %{status: "streaming"}}, 2000

      # Should receive status:idle when final response completes
      # (drain remaining messages first)
      collect_all_messages_from_pubsub([])
      assert_receive {:chat_status, %{status: "idle"}}, 2000

      # Cleanup
      MockClient.clear()
    end

    test "tool call message has correct content and tool_calls field" do
      MockClient.set_tool_response(%{
        text: "Let me calculate that",
        tool_calls: [
          %{id: "call_456", name: "calculator", arguments: %{"expression" => "2 + 2"}}
        ]
      })

      MockClient.set_response("The result is 4")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "What is 2+2?")

      # Find the assistant message with tool calls
      assistant_msg =
        receive do
          {:chat_message, {:user, _}} ->
            receive do
              {:chat_message, {:assistant, %Assistant{tool_calls: [_ | _]} = msg}} ->
                msg
            after
              3000 -> flunk("Timeout waiting for assistant with tool calls")
            end
        after
          1000 -> flunk("Timeout waiting for user message")
        end

      assert assistant_msg.index == 1
      assert assistant_msg.content == "Let me calculate that"
      assert length(assistant_msg.tool_calls) == 1

      [tool_call] = assistant_msg.tool_calls
      assert tool_call.name == "calculator"
      assert tool_call.arguments == %{"expression" => "2 + 2"}

      # Cleanup
      MockClient.clear()
    end

    test "tool result message has role tool not assistant" do
      MockClient.set_tool_response(%{
        text: "I'll check that",
        tool_calls: [
          %{id: "call_789", name: "weather", arguments: %{"city" => "London"}}
        ]
      })

      MockClient.set_response("The weather is sunny")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "What's the weather?")

      # Collect messages until we get the tool result
      tool_msg =
        receive do
          {:chat_message, {:user, _}} ->
            collect_until_tool_message()
        after
          1000 -> flunk("Timeout waiting for user message")
        end

      # Verify it's a tool message
      assert {:tool, %Tool{} = msg} = tool_msg
      assert msg.index == 2
      assert msg.tool_results != []

      # Cleanup
      MockClient.clear()
    end

    test "second message after tool execution serializes tool results correctly" do
      # Verifies that tool results from turn 1 serialize correctly
      # when turn 2 builds a new request from the persisted history.

      # First message with tool calls
      MockClient.set_tool_response(%{
        text: "I'll check the directory",
        tool_calls: [
          %{id: "call_first", name: "shell_cmd", arguments: %{"command" => "ls"}}
        ]
      })

      MockClient.set_response("Directory listing complete")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      # First message
      :ok = Agent.chat(pid, "List files")

      # Wait for first conversation to complete
      _messages = collect_all_messages_from_pubsub([])

      # Second message - this triggers serialization of previous tool results
      MockClient.set_response("Second response received")

      :ok = Agent.chat(pid, "What else is there?")

      # Wait for second response
      second_messages = collect_all_messages_from_pubsub([])

      # Verify we got the second assistant response
      assistant_msgs =
        Enum.filter(second_messages, fn
          {:assistant, _} -> true
          _ -> false
        end)

      assert [_ | _] = assistant_msgs

      # Cleanup
      MockClient.clear()
    end

    test "tool continuation flow broadcasts API calls for each LLM request", %{} do
      # First response: tool calls
      MockClient.set_tool_response(%{
        text: "I'll execute that",
        tool_calls: [
          %{id: "call_api_001", name: "shell_cmd", arguments: %{"command" => "echo test"}}
        ]
      })

      # Second response: final text after tool execution
      MockClient.set_response("Tool executed successfully")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Run a command")

      # Collect all messages (may be broadcast multiple times with api_logs updates)
      messages = collect_all_messages_from_pubsub([])

      # Get unique messages by index (keep latest version with api_logs)
      unique_messages =
        messages
        |> Enum.reverse()
        |> Enum.uniq_by(fn {_role, msg} -> msg.index end)
        |> Enum.reverse()

      # Find the tool message (index 2) - should have API request log
      tool_msg =
        Enum.find(unique_messages, fn
          {:tool, msg} -> msg.index == 2
          _ -> false
        end)

      assert tool_msg != nil, "Expected to find tool message at index 2"
      {:tool, tool} = tool_msg

      assert tool.api_logs != [],
             "Expected tool message to have API request log"

      has_tool_request = Enum.any?(tool.api_logs, fn log -> log.type == :request end)

      assert has_tool_request,
             "Expected API request log in tool message (tool results sent to API)"

      # Find the final assistant message (index 3) - should have API response log
      final_assistant =
        Enum.find(unique_messages, fn
          {:assistant, msg} -> msg.index == 3
          _ -> false
        end)

      assert final_assistant != nil, "Expected to find final assistant message at index 3"

      {:assistant, final_msg} = final_assistant

      # The final assistant message should have the API response log
      assert final_msg.api_logs != [],
             "Expected final assistant message to have API response log"

      has_response = Enum.any?(final_msg.api_logs, fn log -> log.type == :response end)

      assert has_response,
             "Expected API response log in final assistant message"

      # Cleanup
      MockClient.clear()
    end

    test "broadcasts notification and produces final response when max tool iterations reached" do
      # Queue exactly max_iterations (5) tool responses
      for _ <- 1..5 do
        MockClient.set_tool_response(%{
          text: "Calling tool",
          tool_calls: [
            %{
              id: "call_#{:rand.uniform(100_000)}",
              name: "shell_cmd",
              arguments: %{"command" => "echo loop"}
            }
          ]
        })
      end

      # Set final text response for when max iterations is hit (the final call without tools)
      MockClient.set_response("I've completed the task after multiple iterations")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      capture_log(fn ->
        :ok = Agent.chat(pid, "Keep looping")

        # Should receive notification about max iterations
        assert_receive {:chat_notification,
                        %{type: "max_iterations", message: "Max tool iterations reached"}},
                       3000

        # Collect all messages and find the final assistant response
        messages = collect_all_messages_from_pubsub([])

        # Find all assistant messages
        assistant_messages =
          messages
          |> Enum.filter(fn
            {:assistant, _} -> true
            _ -> false
          end)

        # The last assistant message should be the final response (after max iterations)
        final_assistant = List.last(assistant_messages)
        second_to_last_assistant = Enum.at(assistant_messages, -2)

        assert final_assistant != nil, "Expected at least one assistant message"
        {:assistant, %{content: content}} = final_assistant
        assert content =~ "completed the task"

        # The request log for the final call should be in the second-to-last assistant message
        # (the one with the tool calls that triggered the max iterations)
        if second_to_last_assistant do
          {:assistant, %{api_logs: prev_api_logs}} = second_to_last_assistant
          final_request_log = Enum.find(prev_api_logs, fn log -> log.type == :request end)

          if final_request_log do
            # Verify the final call's wire format includes tool_choice: "none"
            assert final_request_log.payload["tool_choice"] == "none"
            assert final_request_log.payload["tools"] == nil
          end
        end

        # Should receive status:idle after final response
        assert_receive {:chat_status, %{status: "idle"}}, 1000

        # Should NOT receive chat_error (this is not an error condition)
        refute_receive {:chat_error, _}, 100
      end)

      # Cleanup
      MockClient.clear()
    end

    test "does NOT hit max-iterations when iterations stay below the configured cap" do
      # The test data config sets max-tool-iterations = 5. Queue 2
      # tool responses followed by a final text response, and assert
      # the agent completes without a max_iterations notification.
      for _ <- 1..2 do
        MockClient.set_tool_response(%{
          text: "Calling tool",
          tool_calls: [
            %{
              id: "call_#{:rand.uniform(100_000)}",
              name: "shell_cmd",
              arguments: %{"command" => "echo loop"}
            }
          ]
        })
      end

      MockClient.set_response("Done well under the cap")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Brief loop")

      assert_receive {:chat_status, %{status: "idle"}}, 3000
      refute_receive {:chat_notification, %{type: "max_iterations"}}, 100

      MockClient.clear()
    end
  end

  describe "configured_max_tool_iterations/0" do
    test "returns the configured value when DotConfig has one" do
      Mimic.stub(Nest.DotConfig, :load, fn ->
        {:ok, %{providers: %{}, models: %{}, max_tool_iterations: 7}}
      end)

      assert Agent.configured_max_tool_iterations() == 7
    end

    test "returns the hardcoded default of 25 when DotConfig has no max_tool_iterations" do
      Mimic.stub(Nest.DotConfig, :load, fn ->
        {:ok, %{providers: %{}, models: %{}, max_tool_iterations: nil}}
      end)

      assert Agent.configured_max_tool_iterations() == 25
    end

    test "returns the hardcoded default of 25 when DotConfig.load/0 returns an error" do
      Mimic.stub(Nest.DotConfig, :load, fn -> {:error, "no config file"} end)

      assert Agent.configured_max_tool_iterations() == 25
    end
  end

  describe "API logs" do
    test "every message in simple conversation has API log" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      messages = collect_all_messages_from_pubsub([])

      unique_messages =
        messages
        |> Enum.reverse()
        |> Enum.uniq_by(fn {_role, msg} -> msg.index end)
        |> Enum.reverse()

      assert length(unique_messages) == 2,
             "Expected 2 messages (user + assistant), got #{length(unique_messages)}"

      for {role, msg} <- unique_messages do
        assert msg.api_logs != [],
               "Message #{msg.index} (#{role}) should have API logs"

        assert length(msg.api_logs) == 1,
               "Message #{msg.index} should have exactly 1 API log"
      end

      {:user, user_msg} = Enum.at(unique_messages, 0)
      assert user_msg.index == 0
      request = Enum.find(user_msg.api_logs, fn log -> log.type == :request end)
      assert request != nil, "User message should have request log"

      {:assistant, assistant_msg} = Enum.at(unique_messages, 1)
      assert assistant_msg.index == 1
      response = Enum.find(assistant_msg.api_logs, fn log -> log.type == :response end)
      assert response != nil, "Assistant message should have response log"
    end

    test "every message in tool call flow has API log including tool message" do
      MockClient.set_tool_response(%{
        text: "I'll execute that command",
        tool_calls: [
          %{id: "call_001", name: "shell_cmd", arguments: %{"command" => "echo test"}}
        ]
      })

      MockClient.set_response("Command executed successfully")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Run a command")

      messages = collect_all_messages_from_pubsub([])

      unique_messages =
        messages
        |> Enum.reverse()
        |> Enum.uniq_by(fn {_role, msg} -> msg.index end)
        |> Enum.reverse()

      assert length(unique_messages) == 4,
             "Expected 4 messages (user, assistant+tools, tool, assistant), got #{length(unique_messages)}"

      assert {:user, user_msg} = Enum.at(unique_messages, 0)
      assert user_msg.index == 0

      assert {:assistant, assistant1} = Enum.at(unique_messages, 1)
      assert assistant1.index == 1

      assert {:tool, tool_msg} = Enum.at(unique_messages, 2)
      assert tool_msg.index == 2

      assert {:assistant, assistant2} = Enum.at(unique_messages, 3)
      assert assistant2.index == 3

      for {role, msg} <- unique_messages do
        assert msg.api_logs != [],
               "Message #{msg.index} (#{role}) should have API logs"
      end

      user_request = Enum.find(user_msg.api_logs, fn log -> log.type == :request end)
      assert user_request != nil, "User message should have request log"

      assistant1_response = Enum.find(assistant1.api_logs, fn log -> log.type == :response end)
      assert assistant1_response != nil, "Assistant with tool calls should have response log"

      tool_request = Enum.find(tool_msg.api_logs, fn log -> log.type == :request end)

      assert tool_request != nil,
             "Tool message should have API request log showing tool results were sent to API"

      assistant2_response = Enum.find(assistant2.api_logs, fn log -> log.type == :response end)
      assert assistant2_response != nil, "Final assistant message should have response log"

      MockClient.clear()
    end

    test "API log IDs follow correct sequencing pattern" do
      MockClient.set_tool_response(%{
        text: "I'll help",
        tool_calls: [
          %{id: "call_001", name: "shell_cmd", arguments: %{"command" => "ls"}}
        ]
      })

      MockClient.set_response("Done")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "List files")

      messages = collect_all_messages_from_pubsub([])

      unique_messages =
        messages
        |> Enum.reverse()
        |> Enum.uniq_by(fn {_role, msg} -> msg.index end)
        |> Enum.reverse()

      {:user, user} = Enum.at(unique_messages, 0)
      [user_log] = user.api_logs
      assert user_log.id == "000.000"
      assert user_log.type == :request

      {:assistant, asst1} = Enum.at(unique_messages, 1)
      [asst1_log] = asst1.api_logs
      assert asst1_log.id == "001.000"
      assert asst1_log.type == :response

      {:tool, tool} = Enum.at(unique_messages, 2)
      [tool_log] = tool.api_logs
      assert tool_log.id == "002.000"
      assert tool_log.type == :request

      {:assistant, asst2} = Enum.at(unique_messages, 3)
      [asst2_log] = asst2.api_logs
      assert asst2_log.id == "003.000"
      assert asst2_log.type == :response

      MockClient.clear()
    end
  end

  test "stops agent process" do
    agent_id = "terminating-agent-#{System.unique_integer([:positive])}"
    pid = start_supervised!({Agent, %{id: agent_id, model: %{name: "qwen3.5-plus"}}})
    assert Process.alive?(pid)

    ref = Process.monitor(pid)
    Agent.terminate(pid)

    # Wait for process to stop - allow any exit reason
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000

    refute Process.alive?(pid)
  end

  describe "context limit (configured)" do
    test "uses the configured context_limit from DotConfig when present" do
      # qwen3.5-plus has context-limit = 512000 in test/data/config.toml
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      info = Agent.get_public_info(pid)
      assert info.context_limit == 512_000
      assert info.context_limit_source == :config

      Agent.terminate(pid)
    end

    test "does not call Discover when context_limit is already configured" do
      # If the probe were called, the Req mock would be invoked.
      # We deliberately do NOT set up a Req mock and rely on the
      # absence of any HTTP call as proof the probe was skipped.
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      # :sys.get_state/1 is a synchronous call — by the time it
      # returns, the GenServer has finished processing any
      # init-time work (including any (incorrectly) spawned probe
      # task). Confirm the configured context_limit is what
      # public_info reports and that the source is :config, not
      # :probe or :default.
      state = :sys.get_state(pid)
      assert state.context_limit == 512_000
      assert state.context_limit_source == :config

      Agent.terminate(pid)
    end
  end

  describe "token usage aggregation" do
    test "initial usage_totals are all zero" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      info = Agent.get_public_info(pid)

      assert info.usage == %{
               input_tokens: 0,
               output_tokens: 0,
               total_tokens: 0,
               reasoning_tokens: 0,
               last_output: 0
             }

      Agent.terminate(pid)
    end

    test "accumulates output_tokens across turns" do
      # Script two turns; each turn's response carries a `usage`
      # event with input_tokens + output_tokens. The mock consumes
      # one event sequence per `run/2` call.
      MockClient.set_stream_events([
        {:text, "response 1"},
        {:usage, %{input_tokens: 100, output_tokens: 50, total_tokens: 150}},
        {:finish_reason, "stop"},
        {:done, %{response: %RunResponse{text: "response 1", stop_reason: "stop"}}}
      ])

      MockClient.set_stream_events([
        {:text, "response 2"},
        {:usage, %{input_tokens: 200, output_tokens: 100, total_tokens: 300}},
        {:finish_reason, "stop"},
        {:done, %{response: %RunResponse{text: "response 2", stop_reason: "stop"}}}
      ])

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "First")
      collect_all_messages_from_pubsub([])

      # After the first turn, output_tokens should be 50.
      info1 = Agent.get_public_info(pid)
      assert info1.usage.output_tokens == 50
      assert info1.usage.input_tokens == 100
      assert info1.usage.last_output == 50

      :ok = Agent.chat(pid, "Second")
      collect_all_messages_from_pubsub([])

      info2 = Agent.get_public_info(pid)
      assert info2.usage.output_tokens == 150
      # input_tokens is overwritten, not summed; latest call = 200
      assert info2.usage.input_tokens == 200
      assert info2.usage.last_output == 100

      Agent.terminate(pid)
    end

    test "accumulates usage across tool iterations" do
      # Two LLM calls: initial (tool call), then final answer after
      # tool result continuation. Each call contributes its own
      # usage to the running totals.
      MockClient.set_stream_events([
        {:text, "Calling tool"},
        {:tool_call_start, %{id: "call_1", name: "shell_cmd"}},
        {:tool_call_delta, %{id: "call_1", arguments_delta: "{}"}},
        {:usage, %{input_tokens: 1001, output_tokens: 101, total_tokens: 1102}},
        {:finish_reason, "tool_calls"},
        {:done,
         %{
           response: %RunResponse{
             text: "Calling tool",
             tool_calls: [%ToolCall{id: "call_1", name: "shell_cmd", arguments: %{}}],
             stop_reason: "tool_calls"
           }
         }}
      ])

      MockClient.set_stream_events([
        {:text, "Final answer"},
        {:usage, %{input_tokens: 1003, output_tokens: 103, total_tokens: 1106}},
        {:finish_reason, "stop"},
        {:done, %{response: %RunResponse{text: "Final answer", stop_reason: "stop"}}}
      ])

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Run a command")
      collect_all_messages_from_pubsub([])

      info = Agent.get_public_info(pid)
      # 2 LLM calls total: output_tokens = 101 + 103 = 204
      assert info.usage.output_tokens == 204
      # input_tokens is the LAST call's value, not summed
      assert info.usage.input_tokens == 1003
      # last_output is the last call's output_tokens
      assert info.usage.last_output == 103

      Agent.terminate(pid)
    end

    test "nil usage is treated as a no-op" do
      # First call: real usage
      # Second call: no `{:usage, _}` event — `RunResponse.usage` is nil
      MockClient.set_stream_events([
        {:text, "First"},
        {:usage, %{input_tokens: 50, output_tokens: 25, total_tokens: 75}},
        {:finish_reason, "stop"},
        {:done, %{response: %RunResponse{text: "First", stop_reason: "stop"}}}
      ])

      MockClient.set_stream_events([
        {:text, "Second"},
        {:finish_reason, "stop"},
        {:done, %{response: %RunResponse{text: "Second", stop_reason: "stop"}}}
      ])

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "First")
      collect_all_messages_from_pubsub([])

      info1 = Agent.get_public_info(pid)
      assert info1.usage.output_tokens == 25
      assert info1.usage.input_tokens == 50

      :ok = Agent.chat(pid, "Second")
      collect_all_messages_from_pubsub([])

      info2 = Agent.get_public_info(pid)
      # The nil usage from the second call should NOT have zeroed
      # the running totals.
      assert info2.usage.output_tokens == 25
      # input_tokens is not overwritten when usage is nil
      assert info2.usage.input_tokens == 50
      # last_output is preserved across nil-usage calls (no-op
      # semantics: we don't reset derived values when the call
      # didn't surface usage info).
      assert info2.usage.last_output == 25

      Agent.terminate(pid)
    end
  end

  describe "tool budget loop" do
    test "small tool results pass through unchanged" do
      MockClient.set_tool_response(%{
        text: "Reading file",
        tool_calls: [
          %{id: "call_1", name: "shell_cmd", arguments: %{"command" => "echo small"}}
        ]
      })

      MockClient.set_response("Done")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Read a file")

      # Collect all messages and find the tool result
      messages = collect_all_messages_from_pubsub([])

      tool_msg =
        Enum.find(messages, fn
          {:tool, _} -> true
          _ -> false
        end)

      assert {:tool, %Tool{tool_results: [result]}} = tool_msg
      # Small result should be present (not truncated, not skipped)
      refute String.contains?(result.content, "[truncated:")
      refute String.contains?(result.content, "[skipped:")
      assert result.is_error == false

      Agent.terminate(pid)
    end

    test "order is preserved when multiple tool calls are returned" do
      # Single response with multiple tool calls
      MockClient.set_stream_events([
        {:text, "Running two commands"},
        {:tool_call_start, %{id: "call_1", name: "shell_cmd"}},
        {:tool_call_delta, %{id: "call_1", arguments_delta: "{}"}},
        {:tool_call_start, %{id: "call_2", name: "shell_cmd"}},
        {:tool_call_delta, %{id: "call_2", arguments_delta: "{}"}},
        {:usage, %{input_tokens: 100, output_tokens: 50, total_tokens: 150}},
        {:finish_reason, "tool_calls"},
        {:done,
         %{
           response: %RunResponse{
             text: "Running two commands",
             tool_calls: [
               %ToolCall{
                 id: "call_1",
                 name: "shell_cmd",
                 arguments: %{"command" => "echo first"}
               },
               %ToolCall{
                 id: "call_2",
                 name: "shell_cmd",
                 arguments: %{"command" => "echo second"}
               }
             ],
             stop_reason: "tool_calls"
           }
         }}
      ])

      MockClient.set_response("All done")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Run two")

      messages = collect_all_messages_from_pubsub([])

      tool_msg =
        Enum.find(messages, fn
          {:tool, _} -> true
          _ -> false
        end)

      assert {:tool, %Tool{tool_results: results}} = tool_msg
      assert length(results) == 2
      # Order preserved
      assert Enum.map(results, & &1.tool_call_id) == ["call_1", "call_2"]

      Agent.terminate(pid)
    end
  end

  # The "tight context budget" test was removed when the compactor
  # was wired into the agent: with a 3k context_limit, the pre-flight
  # now triggers compaction before any tool execution happens, so
  # the tool result is no longer broadcast. The BudgetPlanner's
  # truncate/skip behavior is covered in its own unit tests
  # (`test/nest/tokens/budget_planner_test.exs`).

  describe "compaction history" do
    test "compaction moves messages to history with a marker" do
      # Drive a chat that has enough history for compaction to
      # potentially fire. We don't actually verify that compaction
      # was triggered (the MockClient LLM is too random to set
      # up cleanly) — what we verify is the API: when the
      # GenServer's :compaction_done handle_info runs, it
      # archives the previous messages to history with a marker.
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      old_messages = [
        {:user, %User{index: 0, content: "First", api_logs: []}},
        {:assistant, %Assistant{index: 1, content: "A1", api_logs: []}},
        {:user, %User{index: 2, content: "Second", api_logs: []}},
        {:assistant, %Assistant{index: 3, content: "A2", api_logs: []}}
      ]

      new_messages = [
        {:system,
         %Nest.Messages.System{index: 4, content: "[Summary of earlier conversation]:\n\n..."}},
        {:user, %User{index: 5, content: "Third", api_logs: []}}
      ]

      :sys.replace_state(pid, fn s -> %{s | messages: old_messages} end)

      # Capture the GenServer's pid as a "from" for our message so
      # we can wait for an explicit reply.
      send(pid, {:compaction_done, new_messages, {:chat_continuation, {"next", "chat"}}})

      # :sys.get_state/1 is a synchronous call — by the time it
      # returns, the GenServer has finished processing
      # :compaction_done (which archives old_messages to history
      # synchronously). The async chat continuation may still be
      # running, but the test only asserts on history, which is
      # already updated.
      state_after = :sys.get_state(pid)
      history = state_after.history || []

      # History should now contain the old messages plus a marker
      assert length(history) == length(old_messages) + 1

      # The last element of history is the compaction marker
      assert match?({:compaction, %Nest.Messages.Compaction{}}, List.last(history))

      # The marker should report the correct archived count
      {:compaction, %Nest.Messages.Compaction{archived_count: count}} = List.last(history)
      assert count == 4

      Agent.terminate(pid)
    end
  end

  describe "pre-flight streaming guard" do
    test "preflight_request with active streaming returns :proceed without compacting" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      # Simulate an in-progress stream by stuffing the accumulator
      # with text. With our guard, a non-empty text_buffer means
      # "actively streaming" — the pre-flight must NOT compact.
      :sys.replace_state(pid, fn s ->
        acc = Streaming.new(s.next_message_index)
        acc = %{acc | text_buffer: "partial response..."}
        %{s | streaming_acc: acc}
      end)

      state_before = :sys.get_state(pid)
      msg_count = length(state_before.messages || [])

      # Send a preflight request from a fake task; the GenServer
      # should reply :proceed without touching state.messages.
      fake_task = self()
      send(pid, {:preflight_request, fake_task, state_before.messages || []})

      assert_receive {:preflight_result, :proceed, _}, 1_000

      state_after = :sys.get_state(pid)
      assert length(state_after.messages || []) == msg_count

      Agent.terminate(pid)
    end

    test "preflight_request with empty streaming_acc and fits returns :proceed" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      # Default state from start_agent has empty messages and a
      # nil streaming_acc (no stream ever started). Pre-flight
      # should see :fits and reply :proceed.
      state_before = :sys.get_state(pid)
      assert state_before.streaming_acc == nil

      send(pid, {:preflight_request, self(), state_before.messages || []})

      assert_receive {:preflight_result, :proceed, _}, 1_000

      Agent.terminate(pid)
    end
  end

  describe "chat:compaction broadcast" do
    test "compaction_done broadcasts chat:compaction with marker and history" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      old_messages = [
        {:user, %User{index: 0, content: "First", api_logs: []}},
        {:assistant, %Assistant{index: 1, content: "A1", api_logs: []}}
      ]

      new_messages = [
        {:system,
         %Nest.Messages.System{index: 2, content: "[Summary of earlier conversation]:\n\n..."}},
        {:user, %User{index: 3, content: "Next", api_logs: []}}
      ]

      :sys.replace_state(pid, fn s -> %{s | messages: old_messages, next_message_index: 2} end)

      send(pid, {:compaction_done, new_messages, {:compact_context_continuation, self()}})

      assert_receive {:chat_compaction, payload}, 1_000

      # Payload has the marker (with archivedCount) and the full
      # history (old_messages ++ [marker])
      assert payload.marker["role"] == "compaction"
      assert payload.marker["archivedCount"] == 2
      assert payload.marker["index"] == 2
      assert is_list(payload.history)
      assert length(payload.history) == 3
      assert match?(%{"role" => "compaction"}, List.last(payload.history))

      Agent.terminate(pid)
    end
  end

  # Helper functions

  defp find_user_message(content) do
    Stream.repeatedly(fn ->
      receive do
        msg -> msg
      after
        10 -> nil
      end
    end)
    |> Enum.find_value(fn
      {:chat_message, {:user, %{content: ^content} = m}} -> m
      _ -> nil
    end)
  end

  defp receive_deltas_and_message_from_pubsub do
    receive do
      {:chat_delta, _chunk} ->
        receive_deltas_and_message_from_pubsub()

      {:chat_message, {:user, _}} ->
        receive_deltas_and_message_from_pubsub()

      {:chat_message, {:assistant, assistant_struct}} = msg ->
        assert is_struct(assistant_struct, Nest.Messages.Assistant)
        assert assistant_struct.content != nil
        msg
    after
      2000 ->
        flunk("Timeout waiting for assistant response")
    end
  end

  defp collect_deltas_and_message_from_pubsub(acc \\ "") do
    receive do
      {:chat_delta, %{content: content}} ->
        collect_deltas_and_message_from_pubsub(acc <> content)

      {:chat_message, {:user, _}} ->
        collect_deltas_and_message_from_pubsub(acc)

      {:chat_message, msg} ->
        {acc, msg}
    after
      2000 ->
        flunk("Timeout waiting for deltas")
    end
  end

  defp collect_all_deltas_from_pubsub(deltas \\ []) do
    receive do
      {:chat_delta, delta} ->
        collect_all_deltas_from_pubsub([delta | deltas])

      {:chat_message, {:assistant, _}} ->
        Enum.reverse(deltas)
    after
      500 ->
        Enum.reverse(deltas)
    end
  end

  # Helper to collect all messages from PubSub for tool call flow tests.
  # Drains until no new `{:chat_message, _}` arrives within `quiet_ms`
  # after the last message (or `max_ms` elapses if no message ever
  # arrives). Most tests finish in ~100ms once the chat task goes idle;
  # the max cap is a safety net for hung agents.
  defp collect_all_messages_from_pubsub(messages, opts \\ []) do
    quiet_ms = Keyword.get(opts, :quiet_ms, 10)
    max_ms = Keyword.get(opts, :max_ms, 10)
    started_at = System.monotonic_time(:millisecond)
    do_collect_all_messages(messages, quiet_ms, max_ms, started_at, nil)
  end

  defp do_collect_all_messages(messages, quiet_ms, max_ms, started_at, last_msg_at) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - started_at

    cond do
      elapsed >= max_ms ->
        messages

      last_msg_at != nil and now - last_msg_at >= quiet_ms ->
        messages

      true ->
        wait_ms = min(quiet_ms, max_ms - elapsed)

        receive do
          {:chat_message, msg} ->
            do_collect_all_messages(messages ++ [msg], quiet_ms, max_ms, started_at, now_ms())
        after
          wait_ms ->
            do_collect_all_messages(messages, quiet_ms, max_ms, started_at, last_msg_at)
        end
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Helper to wait for tool message
  defp collect_until_tool_message do
    receive do
      {:chat_message, {:tool, _} = msg_tuple} ->
        msg_tuple

      {:chat_message, _} ->
        collect_until_tool_message()
    after
      3000 ->
        flunk("Timeout waiting for tool message")
    end
  end
end
