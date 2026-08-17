defmodule NestWeb.AgentChannelTest do
  @moduledoc """
  Core AgentChannel tests: join/3, init payload, message history,
  and the `chat:message` handler.
  """
  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  import Mimic

  alias Nest.Agents.AgentTestHelpers

  setup :verify_on_exit!

  describe "join/3" do
    test "joins agent channel and returns state with messageCount", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      assert socket.topic == "agent:#{space_id}:#{id}"
      assert_push "init", payload
      assert payload["name"] == id
      assert payload["model"]["name"] == "qwen3.5-plus"
      assert payload["messageCount"] == 1
      assert payload["status"] == "idle"
      # Init includes partial (nil when not streaming)
      assert Map.has_key?(payload, "partial")
      assert payload["partial"] == nil
      refute Map.has_key?(payload, "messages")
    end

    test "init includes modes, defaultMode, and currentMode", %{socket: _socket} do
      assert_push "init", payload
      # Vocation-less agent defaults to "chat"
      assert payload["modes"] == ["chat"]
      assert payload["defaultMode"] == "chat"
      assert payload["currentMode"] == "chat"
    end

    test "init includes contextLimit, contextLimitSource, and usage", %{socket: _socket} do
      assert_push "init", payload

      # qwen3.5-plus has a configured context-limit of 512_000
      # in test/data/config.toml.
      assert payload["contextLimit"] == 512_000
      assert payload["contextLimitSource"] == "config"
      # `context_input_tokens` is computed from the messages list
      # (real-valued `tokens` from prior LLM responses as a floor,
      # estimator for the suffix). For a fresh agent with just a
      # system prompt in the messages list, it's the system
      # prompt's estimated size — non-zero, so the chip displays
      # a meaningful fill rate from the moment the page loads.
      # The other usage fields stay at 0 (no LLM call has run).
      assert payload["usage"] == %{
               input_tokens: 0,
               cache_read_input_tokens: 0,
               cache_creation_input_tokens: 0,
               context_input_tokens: payload["usage"][:context_input_tokens],
               last_output: 0,
               output_tokens: 0,
               total_input_tokens: 0,
               total_cache_read_input_tokens: 0,
               total_cache_creation_input_tokens: 0,
               total_tokens: 0,
               reasoning_tokens: 0
             }

      assert payload["usage"][:context_input_tokens] > 0,
             "expected context_input_tokens > 0 (system prompt estimated size), got #{payload["usage"][:context_input_tokens]}"
    end

    test "init payload includes provider in the model map", %{socket: _socket} do
      assert_push "init", payload

      # The model map must carry both :name and :provider so the
      # frontend can render "provider: model-name" in the chat
      # header (assets/js/pages/ChatPage.jsx).
      assert payload["model"]["name"] == "qwen3.5-plus"
      assert payload["model"]["provider"] == "model-studio"
    end

    test "returns error for non-existent agent" do
      token = Process.get(:agent_test_token)
      {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})

      assert {:error, %{"reason" => "agent not found"}} =
               subscribe_and_join(
                 connected,
                 NestWeb.AgentChannel,
                 "agent:1:nonexistent"
               )
    end

    test "returns agent_unavailable (not a crash) for non-:not_found errors" do
      # `Agents.get_agent/1` propagates whatever
      # `Supervisor.get_agent/1` returns. To exercise the
      # non-`:not_found` branch, stub it to return a tuple
      # other than `:not_found`.
      #
      # The channel's catch-all path logs a `Logger.warning`
      # via `agent_channel.ex:47` — capture it and assert
      # it's the expected error path, not noise.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Nest.Agents
          |> expect(:get_agent, fn _space_id, _name ->
            {:error, %Nest.ChatModel.ModelNotFoundError{message: "x"}}
          end)

          token = Process.get(:agent_test_token)
          {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})

          assert {:error, %{"reason" => "agent_unavailable"}} =
                   subscribe_and_join(
                     connected,
                     NestWeb.AgentChannel,
                     "agent:1:any-missing"
                   )
        end)

      assert log =~ "agent:1:any-missing channel join failed"
    end

    test "returns space_archived when the space has been archived", %{user: user} do
      # Use a SEPARATE space (not the setup's, which the setup's
      # channel is already joined to) so archiving it doesn't tear
      # down the setup's socket. The guard rejects the archived
      # space before any agent lookup, so the agent name can be
      # arbitrary.
      {:ok, %Nest.Spaces.Space{id: space_id}} =
        Nest.Spaces.create_space(user.id, %{
          name: "arch-join-#{System.unique_integer([:positive])}"
        })

      assert :ok = Nest.Spaces.archive_space(space_id)

      token = Process.get(:agent_test_token)
      {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})

      assert {:error, %{"reason" => "space_archived"}} =
               subscribe_and_join(
                 connected,
                 NestWeb.AgentChannel,
                 "agent:#{space_id}:anything"
               )
    end

    test "receives a topic broadcast exactly once (no double subscription)", %{
      agent_id: id,
      space_id: space_id
    } do
      # Phoenix.Channel.Server.init_join/3 already subscribes the
      # channel process to the channel topic. `joined_join` must not
      # subscribe again — an explicit `Phoenix.PubSub.subscribe` would
      # register this process twice and, because Phoenix.PubSub does
      # not deduplicate, deliver every broadcast twice (doubling
      # streamed chat deltas). A single broadcast must be pushed once.
      topic = "agent:#{space_id}:#{id}"

      Phoenix.PubSub.broadcast(
        Nest.PubSub,
        topic,
        {:chat_delta,
         %{
           index: 1,
           content: "x",
           chars_start: 0,
           chars_end: 1,
           part_type: :text
         }}
      )

      assert_push "chat:delta", %{"content" => "x"}, 500
      refute_push "chat:delta", %{"content" => "x"}, 200
    end
  end

  describe "init event with message history" do
    test "init reports messageCount = 2 after one chat turn", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      # The setup's subscribe_and_join already pushed the *first*
      # channel's init (messageCount: 0) into this process's mailbox.
      # Consume it explicitly so the later `assert_push "init"`
      # after the rejoin matches the *new* channel's init, not the
      # stale one. Without this, the assertion sees the setup's
      # messageCount = 0 and the test would pass for the wrong reason.
      assert_push "init", _setup_init, 2000

      # Push one user message; the agent will respond, leaving 2 persisted messages.
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 2000

      assert_receive {:chat_status, %{status: "idle"}}, 500

      # Drop the first channel and wait for it to actually terminate
      # before rejoining. Monitor + :DOWN is the synchronous Erlang
      # primitive; GenServer.stop/2 is async and would race.
      channel_pid = socket.channel_pid
      monitor_ref = Process.monitor(channel_pid)
      Process.unlink(channel_pid)
      GenServer.stop(channel_pid, :normal)
      assert_receive {:DOWN, ^monitor_ref, :process, ^channel_pid, _}, 1000

      # Reconnect the socket — the dropped channel's pid is
      # gone, so we open a fresh connection with the same token.
      token = Process.get(:agent_test_token)
      {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})

      {:ok, _, _new_socket} =
        subscribe_and_join(connected, NestWeb.AgentChannel, "agent:#{space_id}:#{id}")

      assert_push "init", payload, 2000
      assert payload["messageCount"] == 3
    end
  end

  describe "handle_in(chat:message)" do
    test "sends message and returns ok", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for the user message to be broadcast so the LLM Task is
      # actively using the stub before the test exits.
      assert_push "chat:message", %{"role" => "user"}, 500

      assert_receive {:chat_status, %{status: "idle"}}, 500
    end

    test "accepts a mode field in the payload", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello", "mode" => "build"})
      assert_reply ref, :ok, %{}

      # The user message broadcast includes the mode (which gets stored
      # in the User struct's metadata).
      assert_push "chat:message", %{"role" => "user"}, 500

      assert_receive {:chat_status, %{status: "idle"}}, 500
    end

    test "omitting mode is allowed (defaults to chat)", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}
      assert_push "chat:message", %{"role" => "user"}, 500

      assert_receive {:chat_status, %{status: "idle"}}, 500
    end

    test "broadcasts user message with index", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Receive user message broadcast first
      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 500

      # Then receive streaming deltas
      assert_push "chat:delta", payload, 500
      assert is_integer(payload["index"])
      assert is_binary(payload["content"])
      assert is_integer(payload["charsStart"])
      assert is_integer(payload["charsEnd"])

      assert_receive {:chat_status, %{status: "idle"}}, 500
    end

    test "chat:status broadcast carries currentMode (sticky mode)", %{socket: socket} do
      # Sending a chat:message updates the agent's `state.live.mode`
      # to the resolved mode. The status push that transitions
      # to `idle` (the one that unlocks the input) carries the
      # new currentMode so the client can reset the dropdown.
      ref = push(socket, "chat:message", %{"content" => "Hello", "mode" => "chat"})
      assert_reply ref, :ok, %{}

      # The user message lands first, then the LLM streams and
      # finalizes with a chat:status: idle. Drain intermediate
      # broadcasts with `assert_push` and `assert_receive` and
      # then assert the final status carries `currentMode`.
      assert_push "chat:message", %{"role" => "user"}, 500

      # Drain the streaming path. We don't care about each
      # delta — just make sure the assistant message and the
      # idle status both arrive.
      assert_push "chat:message", %{"role" => "assistant"}, 500

      assert_push "chat:status", %{status: "idle", currentMode: "chat"}, 500
    end

    test "calls LLM and broadcasts response with deltas and index", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # User message is the first chat:message (broadcast by the
      # agent when the chat starts). Then deltas stream. The
      # final chat:message is the assistant. Each is a known
      # broadcast; we use non-blocking receive with `after 0`
      # to drain any extra deltas that landed between the
      # user message and the assistant.
      assert_push "chat:message", %{"role" => "user"}, 500

      # Each chat:delta is a known broadcast. The mock returns
      # one text event → one delta. Verify its shape.
      assert_push "chat:delta", delta, 500
      assert is_integer(delta["index"])
      assert is_binary(delta["content"])
      assert is_integer(delta["charsStart"])
      assert is_integer(delta["charsEnd"])
      assert delta["charsEnd"] > delta["charsStart"]

      assert_push "chat:message", %{"role" => "assistant", "index" => idx}, 500
      assert idx >= 0

      assert_receive {:chat_status, %{status: "idle"}}, 500
    end
  end

  describe "handle_in(chat:status)" do
    test "reply includes currentMode so the client can re-sync after a reconnect",
         %{socket: socket} do
      ref = push(socket, "chat:status", %{})
      assert_reply ref, :ok, payload

      # currentModel must be present so the client can re-sync
      # the dropdown on reconnect / re-fetch. For a vocation-less
      # agent the default is "chat".
      assert payload["currentMode"] == "chat"
    end
  end

  describe "handle_in(change_model)" do
    test "repairs an agent that is in :model_missing state", %{user: user} do
      # Stub the lookup for the broken model name so the agent
      # lands in :model_missing without polluting the suite.
      #
      # The model-probe failure fires a `Logger.error` from
      # `Agent.init/1` — capture it and assert it's the
      # expected error path, not noise.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          stub_ghost_model_config()

          # The `start_agent/1` helper handles Sandbox.allow +
          # Mimic.allow + on_exit `Supervisor.stop_agent/1`
          # cleanup. The Mimic stub above is set on the test
          # pid; `start_agent/1`'s `allow_mimic_stubs/1`
          # propagates it to the spawned agent pid before
          # `init/1` runs.
          {_pid, name} =
            AgentTestHelpers.start_agent(%{
              name: "ghost-agent-repair-#{System.unique_integer([:positive])}",
              model: %{name: "ghost-model"},
              vocation_id: AgentTestHelpers.vocation_id_for_test(),
              created_by_user_id: user.id
            })

          space_id = AgentTestHelpers.current_space_id()
          token = Process.get(:agent_test_token)
          {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})

          {:ok, _, socket} =
            subscribe_and_join(
              connected,
              NestWeb.AgentChannel,
              "agent:#{space_id}:#{name}"
            )

          # Subscribe to follow-up status pushes (the agent
          # broadcasts chat:status from the set_model handler).
          Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{space_id}:#{name}")

          ref =
            push(socket, "change_model", %{
              "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
            })

          assert_reply ref, :ok, %{}

          # The agent emits a chat:status broadcast carrying the
          # new model — the canonical wire signal for the JS to
          # drop the repair banner. The PubSub payload uses atom
          # keys (it doesn't transit through JSON encoding — JS
          # reads those maps via React's normal serialization).
          assert_receive {:chat_status, payload}, 500
          assert payload.status == "idle"
          assert payload.model["name"] == "qwen3.5-plus"
        end)

      assert log =~ "could not resolve model"
    end

    test "returns :invalid_payload when the model field is missing", %{user: user} do
      # Stub `Config.create_client_config/1` to reject the
      # `:model_missing` model name so `init/1` boots in
      # the recovery state. The change_model handler under
      # test doesn't care about the agent's status — it
      # pattern-matches purely on the request payload.
      #
      # `start_agent/1` registers the on_exit cleanup so
      # this agent pid doesn't leak into the singleton
      # `Nest.Agents.Supervisor` between tests.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          stub_ghost_model_config()

          {_pid, name} =
            AgentTestHelpers.start_agent(%{
              name: "invalid-payload-agent-#{System.unique_integer([:positive])}",
              model: %{name: "ghost-model"},
              vocation_id: AgentTestHelpers.vocation_id_for_test(),
              created_by_user_id: user.id
            })

          space_id = AgentTestHelpers.current_space_id()
          token = Process.get(:agent_test_token)
          {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})

          {:ok, _, socket} =
            subscribe_and_join(
              connected,
              NestWeb.AgentChannel,
              "agent:#{space_id}:#{name}"
            )

          ref = push(socket, "change_model", %{"some_other_field" => "x"})
          assert_reply ref, :error, %{"reason" => "invalid_payload"}
        end)

      assert log =~ "could not resolve model"
    end
  end

  describe "handle_in(chat:message) in :model_missing state" do
    test "rejects with agent_status_model_missing", %{user: user} do
      # The model-probe failure fires a `Logger.error` from
      # `Agent.init/1` — capture it and assert it's the
      # expected error path, not noise.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          stub_ghost_model_config()

          {_pid, name} =
            AgentTestHelpers.start_agent(%{
              name: "reject-model-missing-#{System.unique_integer([:positive])}",
              model: %{name: "ghost-model"},
              vocation_id: AgentTestHelpers.vocation_id_for_test(),
              created_by_user_id: user.id
            })

          space_id = AgentTestHelpers.current_space_id()
          token = Process.get(:agent_test_token)
          {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})

          {:ok, _, socket} =
            subscribe_and_join(
              connected,
              NestWeb.AgentChannel,
              "agent:#{space_id}:#{name}"
            )

          ref = push(socket, "chat:message", %{"content" => "hello?"})
          assert_reply ref, :error, %{"reason" => "agent_status_model_missing"}
        end)

      assert log =~ "could not resolve model"
    end
  end

  # Stub `Config.create_client_config/1` so `Agent.init/1`
  # boots in `:model_missing` for the "ghost-model" test
  # agent, while passing through to the real function for
  # any other model name. The three callers below all
  # need this exact pattern (change_model + invalid_payload
  # + chat:message in :model_missing) but differ in the
  # downstream handler under test.
  defp stub_ghost_model_config do
    Nest.Agents.Agent.Config
    |> stub(:create_client_config, fn model ->
      if model[:name] == "ghost-model" do
        {:error, %Nest.ChatModel.ModelNotFoundError{message: "x"}}
      else
        real_fn = Function.capture(Nest.Agents.Agent.Config, :create_client_config, 1)
        real_fn.(model)
      end
    end)
  end
end
