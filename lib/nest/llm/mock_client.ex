defmodule Nest.LLM.MockClient do
  @moduledoc """
  Test mock for the LLM client boundary.

  Mirrors what the real OpenAI/Anthropic clients will do: accepts a
  `RunRequest`, returns an `Enumerable` that yields canonical events,
  and exposes a small scripting API for tests to queue responses.

  The scripting API is process-safe (state is held in an `Agent`)
  because LLM calls happen in spawned tasks.

  ## Scripting API

  Scripts are queued in a FIFO list. Each `set_*` call appends to
  the back; each `run/2` call pops from the front. This lets tests
  script multi-turn tool-call flows in order:

      Nest.LLM.MockClient.set_tool_response(%{text: "Calling shell",
        tool_calls: [%{id: "call_1", name: "shell_cmd",
                       arguments: %{"command" => "ls"}}]})
      Nest.LLM.MockClient.set_response("Here is the listing") # 2nd call
      Nest.LLM.MockClient.set_error("connection failed")       # 3rd call
      Nest.LLM.MockClient.set_stream_events([{:text, "hi"}, {:text, " there"}])
      Nest.LLM.MockClient.clear()

  When the queue is empty, `run/2` falls back to a short random
  text response.
  """

  @behaviour Nest.LLM.Client

  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse

  # Per-agent state. Each test starts a unique MockClient Agent
  # named after the agent pid. The chat task (spawned by the agent)
  # inherits the agent's process dictionary; the test stores the
  # agent pid there via `:sys.replace_state/2`, so the chat task's
  # `run/2` call finds the right queue. The test's own `set_*`
  # calls also look up the agent pid from the test's process dict.
  #
  # `start_link/0` (no args) defaults to `self()` for backward
  # compatibility with `MockClient`'s own self-tests and any
  # pre-async callers — but only works when `set_*` and `run/2`
  # are called from the same process.

  @doc """
  Start a per-agent queue. Idempotent for the same agent_pid.
  """
  def start_link(agent_pid \\ self()) when is_pid(agent_pid) do
    name = agent_name(agent_pid)

    case Agent.start(fn -> [] end, name: name) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @doc """
  Stop the queue for the given agent pid. No-op if not started.
  """
  def stop(agent_pid \\ current_owner()) when is_pid(agent_pid) do
    case Process.whereis(agent_name(agent_pid)) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end
  end

  @doc """
  Take all pending items from the queue for `agent_pid`, leaving it
  empty. Used to migrate a test's pre-`start_agent/1` queue contents
  into the per-agent queue.
  """
  def take_pending(agent_pid) when is_pid(agent_pid) do
    case Process.whereis(agent_name(agent_pid)) do
      nil -> []
      pid -> Agent.get_and_update(pid, fn queue -> {queue, []} end)
    end
  end

  @doc """
  Append a single item to the queue for `agent_pid`. The opposite
  of `take_pending/1`; used to re-queue items after migration.
  """
  def put_pending(agent_pid, item) when is_pid(agent_pid) do
    Agent.update(agent_name(agent_pid), fn queue -> queue ++ [item] end)
  end

  @doc """
  Append a plain-text response. Consumed by the next `run/2` call.
  """
  def set_response(text) when is_binary(text) do
    update_queue(&(&1 ++ [{:text, text}]))
  end

  @doc """
  Append a tool-call response. Consumed by the next `run/2` call.

  The `text` field is the assistant turn's preamble text (emitted as
  a `{:text, _}` event). `tool_calls` is a list of `%{id, name,
  arguments}` maps; emitted as `{:tool_call_start, _}` events
  followed by a synthesized `{:tool_call_delta, _}` carrying the
  full arguments JSON.
  """
  def set_tool_response(%{tool_calls: calls} = resp) when is_list(calls) do
    update_queue(&(&1 ++ [{:tool, Map.put(resp, :tool_calls, normalize_tool_calls(calls))}]))
  end

  @doc """
  Append an error. Consumed by the next `run/2` call, which returns
  `{:error, reason}`.
  """
  def set_error(reason) do
    update_queue(&(&1 ++ [{:error, reason}]))
  end

  @doc """
  Append a raw canonical event sequence. Consumed by the next
  `run/2` call.

  Options:

    * `:auto_done` (default `true`) — when `true`, append a
      synthetic `{:done, _}` event if the caller didn't end
      the list with one. Most callers want this (it's the
      "happy path"). When `false`, pass the events verbatim —
      useful for tests that need to exercise the no-`:done`
      path (e.g. the OpenAI client's `[DONE]`-synthesis
      fix in `handle_req_done_openai/1`).
  """
  def set_stream_events(events, opts \\ []) when is_list(events) do
    auto_done = Keyword.get(opts, :auto_done, true)
    update_queue(&(&1 ++ [{:events, {events, auto_done}}]))
  end

  @doc """
  Empty the queue. The next `run/2` call falls back to a random
  text response.
  """
  def clear do
    case Process.whereis(agent_name(current_owner())) do
      nil -> :ok
      _ -> Agent.update(agent_name(current_owner()), fn _ -> [] end)
    end
  end

  @impl Nest.LLM.Client
  def run(%RunRequest{} = request, opts \\ []) do
    case take_script(opts, request.tools) do
      nil ->
        {:ok, build_stream({:text, random_response()})}

      {:error, reason} ->
        # `Client.run/2` always returns `{:ok, stream}` per the
        # behaviour; errors are surfaced as `{:error, _}` events
        # inside the stream. Use the canned `{:error, reason}` to
        # build a stream that yields that error followed by `:done`
        # so consumers can detect it via the accumulator's error
        # field.
        {:ok, build_stream({:error, reason})}

      script ->
        {:ok, build_stream(script)}
    end
  end

  @impl Nest.LLM.Client
  def format_request_payload(%RunRequest{} = req, _opts \\ []) do
    %{
      "model" => req.model,
      "messages" => Enum.map(req.messages, &message_to_wire/1),
      "stream" => req.stream,
      "temperature" => req.temperature,
      "max_tokens" => req.max_tokens,
      "top_p" => req.top_p
    }
    |> maybe_put("tools", tools_to_wire(req.tools))
    |> maybe_put("tool_choice", req.tool_choice)
  end

  # The agent pid used to scope `set_*` and `run/2` calls. Pulled
  # from the caller's process dict (`:nest_test_agent_pid`). Falls
  # back to `self()` for tests that call `set_*` and `run/2` from
  # the same process (e.g. MockClient's own self-tests).
  defp current_owner do
    Process.get(:nest_test_agent_pid, self())
  end

  defp agent_name(agent_pid), do: :"nest_llm_mock_client_#{inspect(agent_pid)}"

  defp update_queue(fun), do: Agent.update(agent_name(current_owner()), fun)

  defp take_script(opts, tools) do
    agent_pid =
      Keyword.get(opts, :agent_pid) ||
        Process.get(:nest_test_agent_pid, self())

    case Process.whereis(agent_name(agent_pid)) do
      nil -> nil
      pid -> Agent.get_and_update(pid, fn queue -> take_head(queue, tools) end)
    end
  end

  # When tools is nil, skip any queued tool responses and find the next non-tool response
  defp take_head(queue, nil) do
    case Enum.split_while(queue, fn
           {:tool, _} -> true
           _ -> false
         end) do
      {tool_responses, [head | rest]} ->
        # Skip the tool responses, return the next non-tool response
        {head, rest ++ tool_responses}

      {_, []} ->
        # All remaining are tool responses or queue is empty
        {nil, queue}
    end
  end

  # When tools is not nil, take the head of the queue as normal
  defp take_head([], _tools), do: {nil, []}
  defp take_head([head | tail], _tools), do: {head, tail}

  defp build_stream({:text, text}), do: text_stream(text)
  defp build_stream({:tool, resp}), do: tool_stream(resp)
  defp build_stream({:events, payload}), do: events_stream(payload)
  defp build_stream({:error, reason}), do: error_stream(reason)

  defp text_stream(text) do
    response = %RunResponse{text: text, stop_reason: "stop"}
    Stream.concat([[{:text, text}, {:finish_reason, "stop"}], [done_event(response)]])
  end

  defp tool_stream(%{text: text, tool_calls: calls}) do
    events =
      [{:text, text}] ++
        Enum.flat_map(calls, fn tc ->
          [
            {:tool_call_start, %{id: tc.id, name: tc.name}},
            {:tool_call_delta, %{id: tc.id, arguments_delta: Jason.encode!(tc.arguments || %{})}}
          ]
        end) ++
        [
          {:finish_reason, "tool_calls"},
          done_event(%RunResponse{text: text, tool_calls: calls, stop_reason: "tool_calls"})
        ]

    Stream.map(events, & &1)
  end

  defp events_stream({events, true}) do
    if ends_with_done?(events) do
      Stream.map(events, & &1)
    else
      Stream.map(events ++ [done_event(%RunResponse{})], & &1)
    end
  end

  defp events_stream({events, false}) do
    # Caller asked for verbatim passthrough — used by tests that
    # exercise the no-`:done` path through the LLM client.
    Stream.map(events, & &1)
  end

  defp ends_with_done?(events) do
    match?({:done, _}, List.last(events))
  end

  defp error_stream(reason) do
    [{:error, reason}, done_event(%RunResponse{stop_reason: "stop"})]
    |> Stream.map(& &1)
  end

  defp done_event(%RunResponse{} = response) do
    {:done, %{response: response}}
  end

  defp message_to_wire({:assistant, %{content: content, tool_calls: tool_calls}}) do
    base = %{"role" => "assistant", "content" => content || ""}

    case tool_calls do
      nil -> [base]
      [] -> [base]
      calls -> [Map.put(base, "tool_calls", Enum.map(calls, &tool_call_to_wire/1))]
    end
  end

  defp message_to_wire({:user, %{content: content}}) when is_binary(content) do
    %{"role" => "user", "content" => content}
  end

  defp message_to_wire({:system, %{content: content}}) when is_binary(content) do
    %{"role" => "system", "content" => content}
  end

  defp message_to_wire({:tool, %{tool_results: results}}) when is_list(results) do
    Enum.map(results, fn r ->
      %{
        "role" => "tool",
        "tool_call_id" => r.tool_call_id,
        "content" => r.content || ""
      }
    end)
  end

  defp tool_call_to_wire(%{id: id, name: name, arguments: args}) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => if(is_binary(args), do: args, else: Jason.encode!(args || %{}))
      }
    }
  end

  defp tools_to_wire(nil), do: nil
  defp tools_to_wire([]), do: nil

  defp tools_to_wire(tools) do
    Enum.map(tools, fn t ->
      %{
        "type" => "function",
        "function" => %{
          "name" => t.name,
          "description" => t.description,
          "parameters" => t.parameters_schema
        }
      }
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_tool_calls(calls) do
    Enum.map(calls, fn
      %{id: id, name: name, arguments: nil} ->
        %{id: id, name: name, arguments: %{}}

      %{id: id, name: name, arguments: args} when is_map(args) or is_list(args) ->
        %{id: id, name: name, arguments: args}

      %Nest.LLM.Tool{} = _tool ->
        raise ArgumentError, "set_tool_response expects maps with :id, :name, :arguments"
    end)
  end

  defp random_response do
    adjectives = ["bright", "clever", "swift", "wise", "keen", "sharp"]
    nouns = ["insight", "analysis", "thought", "idea", "perspective", "observation"]
    verbs = ["reveals", "shows", "demonstrates", "indicates", "suggests"]
    adj = Enum.random(adjectives)
    noun = Enum.random(nouns)
    verb = Enum.random(verbs)
    id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "This #{adj} #{noun} #{verb} that the model is working correctly. #{id}"
  end
end
