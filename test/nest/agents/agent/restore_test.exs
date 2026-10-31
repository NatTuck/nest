defmodule Nest.Agents.Agent.RestoreTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.Restore` — the on-demand request-log
  rebuild helper.

  Covers `rebuild_request_api_logs/4`: the caller supplies the slice (the
  active message list through the target message's index, never the
  archive), the wire-format request payload is built with the same
  `client_config.client.format_request_payload/2` the live path uses
  (asserted by comparing against `MockClient`'s own output for an
  equivalent `RunRequest`), and the log's timestamp and `max_tokens` are
  the message's and the request's rather than the fetch's.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.ChatState
  alias Nest.Agents.Agent.LlmMetrics
  alias Nest.Agents.Agent.Restore
  alias Nest.LLM.ClientConfig
  alias Nest.LLM.MockClient
  alias Nest.LLM.RunRequest
  alias Nest.LLM.Tool, as: ToolDef
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.User

  # A distinct, fixed timestamp per message index: the rebuild has to carry the
  # *message's* time, so the test must be able to tell the two apart.
  defp at(index), do: DateTime.from_unix!(1_700_000_000 + index)

  # The caller's cut, exactly as `IntrospectionHandler` makes it: the active
  # list through the target message's index, and nothing after it.
  defp slice_through(messages, index) do
    Enum.take_while(messages, fn {_role, %{index: i}} -> i <= index end)
  end

  # The target message a rebuild is for: the last element of the caller's cut,
  # which is what `find_message/2` matched in the handler. Passed in rather than
  # re-derived, so the log's id and timestamp are that message's own.
  defp target(slice), do: List.last(slice)

  defp fixture_messages do
    [
      {:system,
       %MsgSystem{
         index: 0,
         timestamp: at(0),
         parts: [%Part.Text{text: "sys prompt"}],
         api_logs: []
       }},
      {:user,
       %User{index: 1, timestamp: at(1), parts: [%Part.Text{text: "first turn"}], api_logs: []}},
      {:assistant,
       %Assistant{
         index: 2,
         timestamp: at(2),
         parts: [%Part.Text{text: "first reply"}],
         api_logs: [],
         finish_reason: "stop"
       }},
      {:user,
       %User{index: 3, timestamp: at(3), parts: [%Part.Text{text: "second turn"}], api_logs: []}},
      {:tool,
       %Nest.Messages.Tool{
         index: 4,
         timestamp: at(4),
         parts: [%Part.ToolResult{tool_call_id: "c1", name: "shell-cmd", content: "ok"}],
         api_logs: []
       }},
      {:assistant,
       %Assistant{
         index: 5,
         timestamp: at(5),
         parts: [%Part.Text{text: "second reply"}],
         api_logs: [],
         finish_reason: "stop"
       }}
    ]
  end

  # A resolved context limit, so `max_tokens` is the `min(model_default, 0.20L)`
  # arm the live turn uses (20 000 here) and cannot be confused with the
  # encoder's 32 000 fallback.
  defp fixture_state do
    tools = [
      %ToolDef{
        name: "shell-cmd",
        description: "run a shell command",
        parameters_schema: %{"type" => "object"},
        function: fn _, _ -> {:ok, "ok"} end
      }
    ]

    client_config = %ClientConfig{
      client: MockClient,
      base_url: "https://test/api",
      api_key: "test-key",
      first_byte_timeout: 5_000,
      stream_idle_timeout: 5_000,
      model: "test-model",
      thinking_effort: :high
    }

    %Nest.Agents.Agent{
      name: "test-agent",
      model: %{name: "test-model", provider: "test"},
      client_config: client_config,
      tools: tools,
      chat_state: %ChatState{messages: fixture_messages()},
      llm_metrics: %LlmMetrics{context_limit: 100_000},
      live: %ChatState.Live{api_log_sequences: %{}}
    }
  end

  describe "rebuild_request_api_logs/4" do
    test "the log is the message's own request: id, timestamp and the live wire payload" do
      state = fixture_state()
      slice = slice_through(fixture_messages(), 3)

      rebuilt = Restore.rebuild_request_api_logs(state, slice, target(slice), state.client_config)

      assert rebuilt.type == :request
      assert rebuilt.id == "003.000"
      # Not the fetch's clock: the widget shows when the request happened.
      assert rebuilt.timestamp == at(3)

      # The same wire format the live path uses for that slice — including the
      # cap the live request would have used (`min(32 000, 0.20 * 100 000)`),
      # not the encoder's 32 000 fallback.
      expected_request = %RunRequest{
        messages: slice,
        tools: state.tools,
        tool_choice: :auto,
        model: state.client_config.model,
        thinking_effort: state.client_config.thinking_effort,
        max_tokens: 20_000,
        stream: true,
        metadata: %{}
      }

      assert rebuilt.payload == MockClient.format_request_payload(expected_request, [])
      assert rebuilt.payload["max_tokens"] == 20_000
    end

    test "a tool-less agent with no resolved limit rebuilds with no tools, :none and the default cap" do
      state = %{
        fixture_state()
        | tools: [],
          llm_metrics: %LlmMetrics{context_limit: nil}
      }

      slice = slice_through(fixture_messages(), 1)
      rebuilt = Restore.rebuild_request_api_logs(state, slice, target(slice), state.client_config)

      refute Map.has_key?(rebuilt.payload, "tools")
      assert rebuilt.payload["tool_choice"] == :none
      # Nothing to take 20% of, so the model default stands alone — `test-model`
      # has none, and the sane default is 32 000.
      assert rebuilt.payload["max_tokens"] == 32_000
      assert rebuilt.timestamp == at(1)
    end

    # The `entire-ox` production regression was a rebuild that cut a preloaded
    # sequence positionally and then stripped the `{:compaction, _}` markers it
    # crossed: with N compactions the log ran N messages past the message it
    # described, and it carried pre-compaction rows. The fix removed both the
    # cut and the strip — the caller passes the slice, and the active list has
    # no markers to cross.
    test "the payload is exactly the caller's slice (entire-ox regression)" do
      state = fixture_state()

      # The post-compaction active list: a fresh system row, the summary, the
      # compactor's reply, then a human turn. Everything below the boundary is
      # archived and is not in this list at all.
      active = [
        {:system,
         %MsgSystem{index: 6, timestamp: at(6), parts: [%Part.Text{text: "fresh system"}]}},
        {:user,
         %User{index: 7, timestamp: at(7), parts: [%Part.Text{text: "summary"}], api_logs: []}},
        {:assistant,
         %Assistant{
           index: 8,
           timestamp: at(8),
           parts: [%Part.Text{text: "compactor reply"}]
         }},
        {:user,
         %User{
           index: 9,
           timestamp: at(9),
           parts: [%Part.Text{text: "after compaction"}],
           api_logs: []
         }}
      ]

      rebuilt =
        Restore.rebuild_request_api_logs(
          state,
          slice_through(active, 9),
          target(slice_through(active, 9)),
          state.client_config
        )

      wire = rebuilt.payload["messages"]

      # One wire message per slice element, in order, ending at the target: no
      # marker role (the encoder has no clause for one) and nothing past it.
      assert Enum.map(wire, & &1["role"]) == ["system", "user", "assistant", "user"]
      assert List.last(wire)["content"] == "after compaction"
      assert rebuilt.timestamp == at(9)

      # An earlier index gets an earlier slice — the caller's cut, not a re-cut
      # of it — which is what keeps the log aligned with the message it is for.
      earlier =
        Restore.rebuild_request_api_logs(
          state,
          slice_through(active, 7),
          target(slice_through(active, 7)),
          state.client_config
        )

      assert Enum.map(earlier.payload["messages"], & &1["role"]) == ["system", "user"]
      assert earlier.timestamp == at(7)
    end
  end
end
