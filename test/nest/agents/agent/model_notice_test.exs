defmodule Nest.Agents.Agent.ModelNoticeTest do
  @moduledoc """
  The notice a model change appends.

  The system message states the model's name, whether the catalog says it accepts
  image input, and the context limit it budgets against — and it is never rebuilt
  (prefix cache). So a change to any of the three is announced instead, and a
  change to none of them says nothing.

  It lives beside `Nest.Agents.Agent.ChangeModelTest` — the change and recovery
  flows themselves — rather than in it: that file is at credo's source-file cap.
  """
  use Nest.DataCase, async: true

  import Mimic
  import Nest.Agents.AgentTestHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Repo
  alias Nest.Tokens.Reserve

  setup :verify_on_exit!

  describe "a change the prompt states" do
    test "appends one pair stating the new model's verdict and limit" do
      {pid, _name} = start_agent(%{model: %{name: "qwen3.5-plus", provider: "model-studio"}})

      before = Agent.get_messages(pid)

      # qwen3.5-plus declares image input; MiniMax-M2.5 declares nothing, and its
      # window is the 128k default.
      :ok = Agent.set_model(pid, %{name: "MiniMax-M2.5", provider: "model-studio"})

      messages = Agent.get_messages(pid)
      assert length(messages) == length(before) + 2

      [notice_row, ack_row] = Enum.take(messages, -2)
      notice = user_text(notice_row)

      # The runtime is speaking, so the row carries the runtime's header and the
      # recipient's mode, exactly as every other delivered row states it.
      assert String.starts_with?(notice, "[From nest runtime | mode: ")

      assert notice =~ "Nothing declares whether it accepts image input"

      # The limit is the number the agent budgets against, and it was stale before
      # this notice existed: state it with the same arithmetic the prompt uses.
      reserve = Reserve.compaction_reserve(128_000)

      assert notice =~ "Its context limit is 128000 tokens"
      assert notice =~ "~#{reserve} tokens are reserved for compaction"
      assert notice =~ "working token budget of ~#{128_000 - reserve}"

      assert {:assistant, %{parts: [%Part.Text{text: "Model change confirmed."}]}} = ack_row
    end

    test "a thinking-only edit appends nothing, and is still a real edit" do
      {pid, _name} = start_agent(%{model: %{name: "qwen3.5-plus", provider: "model-studio"}})

      before = Agent.get_messages(pid)

      :ok =
        Agent.edit_agent(pid, %{
          name: "qwen3.5-plus",
          provider: "model-studio",
          thinking_level: "high"
        })

      # The edit landed — only the notice is skipped, because the prompt says
      # nothing about thinking.
      assert Agent.get_client_config(pid, 1_000).thinking_effort == :high
      assert length(Agent.get_messages(pid)) == length(before)
    end

    test "a notice that cannot be delivered is logged, and the change still succeeds" do
      {pid, name} = start_agent(%{model: %{name: "qwen3.5-plus", provider: "model-studio"}})

      Phoenix.PubSub.subscribe(
        Nest.PubSub,
        "agent:#{current_space_id()}:#{name}"
      )

      # A conversation with no room left for the pair: `pegasus-per-model-test`
      # has a 32k window in the test config, and this is far past it, so the
      # notice needs a compaction — and the compaction it would need cannot be
      # planned either, because there is nothing the summary could be fitted
      # into. A real exchange ahead of the big row, so the preflight asks for a
      # compaction rather than refusing one as a no-op.
      crowded = [
        user_row(1, "hi"),
        assistant_row(2, "hello"),
        user_row(3, String.duplicate("word ", 40_000))
      ]

      :sys.replace_state(
        pid,
        fn state ->
          %{
            state
            | chat_state: %{
                state.chat_state
                | messages: state.chat_state.messages ++ crowded,
                  next_message_index: 4
              }
          }
        end,
        1_000
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   Agent.set_model(pid, %{name: "pegasus-per-model-test", provider: "pegasus"})
        end)

      # The agent is told it was not told, and the operator gets the overflow
      # banner instead of a pair appended into a request that cannot hold it.
      assert log =~ "model change not announced on agent #{inspect(name)}"
      assert_receive {:chat_error, %{content: content}}, 1_000
      assert content =~ "Cannot compact"

      # The change itself is not failed: the row is persisted and the agent holds
      # the new model, which is what the operator asked for.
      {:ok, row} = Persistence.fetch_agent(current_space_id(), name)

      assert row.model == %{"name" => "pegasus-per-model-test", "provider" => "pegasus"}
      assert Agent.get_client_config(pid, 1_000).model == "pegasus-per-model-test"

      refute Enum.any?(Agent.get_messages(pid), &(row_text(&1) =~ "Your model changed."))
    end
  end

  describe "a change that races a queued message" do
    test "the notice cannot land, so the change is logged and still persisted" do
      # A `:model_missing` agent being repaired while a message is already queued:
      # the `{:unblocked}` settle's drain delivers it, so the machine is
      # `:generating` by the time the notice is settled, its `:idle`-only arm does
      # not match, and the agent works on with a prompt naming the model that did
      # not resolve. That is the documented "the change still lands" outcome — the
      # warning is the only trace, and this pins it.
      agent_name = "queued-repair-#{System.unique_integer([:positive])}"

      # The ghost model cannot resolve (that is the state under test); the repair
      # target resolves to the mock client, so the delivered turn costs no HTTP.
      Nest.Agents.Agent.Config
      |> stub(:create_client_config, fn model ->
        case Nest.ChatModel.model_name(model) do
          "ghost-model" -> {:error, %Nest.ChatModel.ModelNotFoundError{message: "ghost"}}
          name -> {:ok, %Nest.LLM.ClientConfig{client: MockClient, model: name}}
        end
      end)

      # A `:model_missing` start logs the resolution failure: assert it rather
      # than let it print.
      {pid, start_log} =
        ExUnit.CaptureLog.with_log(fn ->
          {pid, ^agent_name} = start_ghost_agent!(agent_name)
          pid
        end)

      assert start_log =~ "Agent #{agent_name} could not resolve model"

      # Mimic stubs are private to the test process, and the agent is a supervisor
      # child with no `$callers` chain back to it — so the stub above needs the
      # grant to be visible where the change actually runs.
      Mimic.allow(Nest.Agents.Agent.Config, self(), pid)

      Phoenix.PubSub.subscribe(
        Nest.PubSub,
        "agent:#{current_space_id()}:#{agent_name}"
      )

      # A queued message. `chat_or_queue/5` drops a chat message to a
      # `:model_missing` agent — that is not one of its busy statuses — so the
      # queue is filled directly, in the shape `Inbox.serialize/1` reads.
      :sys.replace_state(
        pid,
        fn state -> %{state | live: %{state.live | inbox: [queued_entry("wake up")]}} end,
        1_000
      )

      # The delivered turn's answer, so it ends cleanly instead of failing on the
      # test config's null HTTP adapter.
      MockClient.start_link(pid)
      MockClient.put_pending(pid, {:text, "Done"})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :ok =
            Agents.change_model(current_space_id(), agent_name, %{
              name: "claude-3-opus-20240229",
              provider: "anthropic-provider"
            })
        end)

      # The status is the point: the machine was `:generating`, so the notice's
      # `:idle`-only arm could not match.
      assert log =~ "model change not announced on agent #{inspect(agent_name)} (:streaming)"

      # The drain really started a turn — which is what makes the machine
      # `:generating` when the notice is settled — and the turn finished. The idle
      # frame *before* the streaming one is the `{:unblocked}` rest's own, so the
      # streaming frame is the premise and the idle after it is the turn's end.
      assert_receive {:chat_status, %{status: "streaming"}}, 1_000
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      assert Enum.any?(Agent.get_messages(pid), &(row_text(&1) =~ "wake up"))

      # The change itself landed, and nothing in the transcript describes it: the
      # agent is left with a prompt naming the model that did not resolve.
      {:ok, row} = Persistence.fetch_agent(current_space_id(), agent_name)

      assert row.model == %{
               "name" => "claude-3-opus-20240229",
               "provider" => "anthropic-provider"
             }

      refute Enum.any?(Agent.get_messages(pid), &(row_text(&1) =~ "Your model changed."))
    end
  end

  # A `:model_missing` agent, started the raw way: `Agents.create_agent/3` refuses a
  # model it cannot resolve, so `AgentTestHelpers.start_agent/1` cannot reach this
  # state. `ensure_cleanup/1` gives it the `on_exit` teardown a direct
  # `Supervisor.fetch_or_start_agent/1` caller would otherwise lack.
  defp start_ghost_agent!(name) do
    {:ok, space_id} = create_test_space()

    attrs = %{
      name: name,
      space_id: space_id,
      model: %{name: "ghost-model"},
      vocation_id: vocation_id_for_test()
    }

    {:ok, _row} = Persistence.insert_agent(attrs)
    {:ok, ^name} = Supervisor.fetch_or_start_agent(space_id, attrs)
    {:ok, pid} = Supervisor.get_agent(space_id, name)

    # Runtime DB writes from the agent pid (the change persists the row) need
    # explicit access to the test pid's checked-out connection.
    Sandbox.allow(Repo, self(), pid)
    ensure_cleanup(name)

    {pid, name}
  end

  # The text of a delivered user row. The notice pair is one text part, which is
  # what the header and the body are joined into.
  defp user_text({:user, %{parts: [%Part.Text{text: text}]}}), do: text

  # A row's text, or "" for a row that has none of its own (the system row, a tool
  # result). For presence checks over a whole transcript.
  defp row_text({_role, %{parts: parts}}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %Part.Text{text: text} -> text
      _other -> ""
    end)
  end

  defp row_text(_row), do: ""

  defp user_row(index, text) do
    {:user, %User{index: index, parts: [%Part.Text{text: text}], api_logs: []}}
  end

  defp assistant_row(index, text) do
    {:assistant, %Assistant{index: index, parts: [%Part.Text{text: text}], api_logs: []}}
  end

  # One queued inbox entry, in the shape `Inbox.serialize/1` reads (the drain
  # builds its delivered message from it).
  defp queued_entry(content) do
    %{
      id: Inbox.new_id(),
      from: "peer",
      content: content,
      timestamp: DateTime.utc_now(),
      kind: :agent,
      mode: nil,
      human?: false,
      fulfilled_ids: []
    }
  end
end
