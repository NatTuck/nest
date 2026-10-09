defmodule Nest.Agents.Agent.ToolLoopSpawnTest do
  @moduledoc """
  `agents-spawn` and `agents-query` inside `ToolLoop.execute/3`.

  Both tools deliver and return: nothing waits for the child's (or the peer's)
  answer. A spawn call returns a confirmation of what will happen, and the
  outcome arrives later as a message in the calling agent's own inbox through
  the §2.1 delivery — the child's own words when it produced content, a runtime
  notice naming the reason when it failed, was stopped, or produced nothing.

  The interception tests use a `FakeParent` so they pin the tool's own contract
  (the confirmation, the error surfacing) without a turn; the delivery tests use
  a real agent, exactly as the turn's tool worker would.
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    Mimic.copy(Nest.Agents)
    {:ok, _space_id} = AgentTestHelpers.create_test_space()

    {:ok, vid: upsert_vocation(["context", "agents"]), peer_slug: peer_slug()}
  end

  describe "the spawn request" do
    defmodule FakeParent do
      @moduledoc """
      Test double for the parent Agent GenServer, started under
      `Agents.Registry.via_tuple(name)` so `ToolLoop` routes to it through the
      registry.

      It answers `:spawn_agent_request` with `{:ok, child_name}` — or
      `{:error, reason}` when `reply_failure` is set — and nothing else: the
      spawn tool must not wait for a child's answer, so a parent that never
      reports one is exactly the contract.
      """
      use GenServer

      defstruct [:child_name, :reply_failure]

      def start(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:via])

      @impl true
      def init(opts) do
        {:ok,
         %__MODULE__{
           child_name: Keyword.get(opts, :child_name, "test-child"),
           reply_failure: Keyword.get(opts, :reply_failure)
         }}
      end

      @impl true
      def handle_call({:spawn_agent_request, _task_pid, _opts}, _from, state) do
        case state.reply_failure do
          nil -> {:reply, {:ok, state.child_name}, state}
          reason -> {:reply, {:error, reason}, state}
        end
      end

      def handle_call(_, _from, state), do: {:reply, :ok, state}

      @impl true
      def handle_cast(_, state), do: {:noreply, state}

      @impl true
      def handle_info(_, state), do: {:noreply, state}
    end

    test "a spawn returns a confirmation that says the answer arrives as a message" do
      {:ok, _pid} =
        FakeParent.start(
          via: AgentsRegistry.via_tuple(AgentTestHelpers.current_space_id(), "parent-success"),
          child_name: "child-success"
        )

      assert [result] =
               spawn_from("parent-success", %{"query" => "say hi", "name" => "child-success"})

      assert %ToolResult{
               tool_call_id: "spawn-1",
               name: "agents-spawn",
               arguments: %{"query" => "say hi", "name" => "child-success"},
               content: content,
               is_error: false
             } = result

      # It names the child, says where the answer goes, and names the notice
      # that replaces it — and it never says "asynchronously", because there is
      # no synchronous mode left to contrast with.
      assert content =~ "child-success"
      assert content =~ "arrive as a message in your inbox"
      assert content =~ "runtime notice"
      refute content =~ "asynchronous"
    end

    test "a spawn with no query says there is nothing to report back" do
      {:ok, _pid} =
        FakeParent.start(
          via: AgentsRegistry.via_tuple(AgentTestHelpers.current_space_id(), "parent-bare"),
          child_name: "child-bare"
        )

      assert [%ToolResult{content: content, is_error: false}] =
               spawn_from("parent-bare", %{"name" => "child-bare"})

      assert content =~ "child-bare"
      assert content =~ "no query"
    end

    test "a parent reply of {:error, _} surfaces as an is_error ToolResult" do
      {:ok, _pid} =
        FakeParent.start(
          via: AgentsRegistry.via_tuple(AgentTestHelpers.current_space_id(), "parent-err"),
          reply_failure: :max_depth_reached
        )

      # BatchSizer logs every `is_error` result: expected, so capture it.
      {results, log} =
        with_log(fn -> spawn_from("parent-err", %{"query" => "x"}) end)

      assert [%ToolResult{tool_call_id: "spawn-1", name: "agents-spawn", is_error: true}] =
               results

      assert hd(results).content =~ "max_depth_reached"
      assert log =~ "is_error=true tool result"
    end
  end

  describe "the child's outcome arrives as a message" do
    test "a completed child's answer lands in the parent's inbox as its own words", %{
      vid: vid,
      peer_slug: slug
    } do
      {parent_pid, parent_name} = start_agent(vid)
      child_name = "spawn-child-#{System.unique_integer([:positive])}"

      # The child's own chat cycle is short-circuited; the test drives its
      # completion below, and the parent's delivery turn is scripted.
      Mimic.stub(Nest.Agents, :chat, fn _space_id, _name, _prompt -> :ok end)
      Mimic.allow(Nest.Agents, self(), parent_pid)
      MockClient.set_response("noted")

      [result] =
        spawn_from(parent_name, %{
          "name" => child_name,
          "vocation" => slug,
          "query" => "do the thing"
        })

      assert %ToolResult{name: "agents-spawn", is_error: false, content: confirmation} = result
      assert confirmation =~ child_name
      # Nothing was awaited: the parent's transcript has no child answer yet.
      refute parent_texts(parent_pid) |> Enum.any?(&(&1 =~ "the answer"))

      cast_child_event(parent_pid, {:child_completed, child_name, "the answer", usage()})

      # Exactly one delivery, framed as the child's own words.
      assert [delivered] = await_delivery(parent_pid, "the answer")
      assert delivered =~ ~s([Message from agent "#{child_name}"])
      assert delivered =~ "the answer"

      # The child's usage merged into the parent's descendant totals.
      assert :sys.get_state(parent_pid).llm_metrics.descendant_usage.output_tokens == 42
    end

    test "a child stopped before it answered reaches the parent as a bare notice", %{vid: vid} do
      {parent_pid, parent_name} = start_agent(vid)
      child_name = "stopped-child-#{System.unique_integer([:positive])}"

      Mimic.stub(Nest.Agents, :chat, fn _space_id, _name, _prompt -> :ok end)
      Mimic.allow(Nest.Agents, self(), parent_pid)
      MockClient.set_response("noted")

      assert [%ToolResult{is_error: false}] =
               spawn_from(parent_name, %{
                 "name" => child_name,
                 "vocation" => peer_slug(),
                 "query" => "do the thing"
               })

      cast_child_event(parent_pid, {:child_terminated, child_name, :shutdown})

      notice = "Child agent #{child_name} was stopped before it answered: :shutdown"
      assert [delivered] = await_delivery(parent_pid, notice)

      # The runtime is speaking, not the child: no `[Message from agent …]`
      # label frames it. (The delivery's own `[mode: …]` prefix is added to
      # every delivered message, notice or not.)
      assert delivered =~ notice
      refute delivered =~ "Message from agent"
    end
  end

  describe "agents-query" do
    test "delivers with the query kind and reports the disposition", %{vid: vid} do
      # intentional: nothing waits. The tool result is the disposition, the kind
      # is `:query` — which is what makes the peer owe the caller a reply — and
      # no background process is started at all.
      {parent_pid, parent_name} = start_agent(vid)
      test_pid = self()

      Mimic.stub(Nest.Agents, :send_message, fn _space_id, from, name, content, kind ->
        send(test_pid, {:delivered_query, from, name, content, kind})
        {:ok, :delivered}
      end)

      assert [%ToolResult{name: "agents-query", is_error: false, content: confirmation}] =
               run_query(parent_pid, parent_name, %{"name" => "peer", "prompt" => "hello?"})

      assert_received {:delivered_query, ^parent_name, "peer", "hello?", :query}

      assert confirmation =~ "Query delivered to peer"
      assert confirmation =~ "owes you a reply"
      refute confirmation =~ "asynchronously"
    end

    test "reports a queued delivery and every refusal", %{vid: vid} do
      {parent_pid, parent_name} = start_agent(vid)

      Mimic.stub(Nest.Agents, :send_message, fn _space_id, _from, _name, _content, _kind ->
        {:ok, :queued}
      end)

      assert [%ToolResult{is_error: false, content: content}] =
               run_query(parent_pid, parent_name, %{"name" => "peer", "prompt" => "hi"})

      assert content =~ "Query queued for peer (busy)"

      # A refusal is an error result carrying the reason, never a silent drop,
      # and both arguments are required (a missing one never reaches the
      # delivery). BatchSizer logs every `is_error` result: expected, so capture
      # it.
      {_results, log} =
        with_log(fn ->
          cases = [
            {{:error, :not_found}, "not found in this space"},
            {{:error, :inbox_full}, "its inbox is full"},
            {{:error, {:status, :needs_repair}}, "needs_repair"}
          ]

          for {reply, expected} <- cases do
            Mimic.stub(Nest.Agents, :send_message, fn _s, _f, _n, _c, _k -> reply end)

            [result] =
              run_query(parent_pid, parent_name, %{"name" => "peer", "prompt" => "hi"})

            assert %ToolResult{name: "agents-query", is_error: true, content: content} = result
            assert content =~ expected
          end

          for {args, expected} <- [
                {%{"prompt" => "hi"}, "Missing required argument: name"},
                {%{"name" => "peer"}, "Missing required argument: prompt"}
              ] do
            [result] = run_query(parent_pid, parent_name, args)

            assert %ToolResult{is_error: true, content: content} = result
            assert content =~ expected
          end
        end)

      assert log =~ "is_error=true tool result"
    end
  end

  # -- helpers --

  defp start_agent(vid) do
    AgentTestHelpers.start_agent(%{
      model: %{name: "qwen3.5-plus", provider: "model-studio"},
      vocation_id: vid
    })
  end

  defp ctx(agent_pid, agent_name) do
    %{
      agent_pid: agent_pid,
      agent_name: agent_name,
      space_id: AgentTestHelpers.current_space_id(),
      context_limit: 100_000,
      messages: []
    }
  end

  defp spawn_from(parent_name, arguments) do
    ToolLoop.execute(ctx(self(), parent_name), nil, [
      %ToolCall{id: "spawn-1", name: "agents-spawn", arguments: arguments}
    ])
  end

  defp run_query(agent_pid, agent_name, arguments) do
    ToolLoop.execute(ctx(agent_pid, agent_name), nil, [
      %ToolCall{id: "query-1", name: "agents-query", arguments: arguments}
    ])
  end

  # Cast one child lifecycle event to the parent, mimicking what the child (or
  # the child registry's `:DOWN`) sends in production.
  defp cast_child_event(parent_pid, {:child_completed, child_name, response, usage}) do
    GenServer.cast(parent_pid, {:child_completed, child_name, response, usage})
  end

  defp cast_child_event(parent_pid, {:child_terminated, child_name, reason}) do
    GenServer.cast(parent_pid, {:child_terminated, child_name, reason})
  end

  # Realistic child usage: `output_tokens: 42` proves the merge ran.
  defp usage do
    %{
      input_tokens: 0,
      output_tokens: 42,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0,
      reasoning_tokens: 0,
      total_tokens: 42,
      last_output: 42,
      total_input_tokens: 0,
      total_cache_read_input_tokens: 0,
      total_cache_creation_input_tokens: 0,
      context_input_tokens: 0
    }
  end

  # Wait until the parent has delivered `needle` AND finished the turn that
  # delivery started, so no background process touches the sandbox after the
  # test ends. Returns every matching delivered text, so a caller can assert
  # there is *exactly one* (a duplicate delivery must fail the test).
  defp await_delivery(parent_pid, needle) do
    Eventually.eventually(
      fn -> delivered_when_idle(parent_pid, needle) end,
      timeout: 500
    )
  end

  defp delivered_when_idle(parent_pid, needle) do
    state = :sys.get_state(parent_pid)

    case {Machine.status_for(state.live.machine), delivered(state, needle)} do
      {:idle, [_ | _] = delivered} -> delivered
      _ -> nil
    end
  end

  defp delivered(state, needle) do
    state.chat_state.messages
    |> Enum.flat_map(&user_texts/1)
    |> Enum.filter(&(&1 =~ needle))
  end

  defp parent_texts(parent_pid) do
    :sys.get_state(parent_pid).chat_state.messages |> Enum.flat_map(&user_texts/1)
  end

  defp user_texts({:user, %{parts: parts}}) do
    for %Part.Text{text: text} <- parts, do: text
  end

  defp user_texts(_other), do: []

  defp upsert_vocation(tools) do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "SpawnTools #{System.unique_integer([:positive])}",
        description: "Coordinator with sub-agent tools",
        system_prompt: "Coordinate specialists in this space.",
        tools: tools,
        modes: %{
          "chat" => %{
            "description" => "Chat",
            "caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp"]}}
          }
        }
      })

    vid
  end

  defp peer_slug do
    {:ok, %Vocations.Vocation{slug: slug}} =
      Vocations.upsert_vocation(%{
        name: "SpawnPeer #{System.unique_integer([:positive])}",
        description: "A peer specialist",
        system_prompt: "You are a peer.",
        tools: ["context"],
        modes: %{}
      })

    slug
  end
end
