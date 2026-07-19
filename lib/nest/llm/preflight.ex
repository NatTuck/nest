defmodule Nest.LLM.Preflight do
  @moduledoc """
  Validates a `RunRequest.messages` list for sequencing rules that
  Anthropic and OpenAI enforce on the wire. Currently checks one
  rule: each assistant `tool_use.id` must be matched by a tool
  result with the same id in the **immediately-following**
  `{:tool, _}` message, before any other role can appear.

  Used by `Nest.LLM.MockClient` only at the moment. The real
  clients (`OpenAIClient`, `AnthropicClient`) still let the API
  surface these errors and report them via the canonical
  `{:error, _}` event pipeline. Putting the check in the mock
  turns fixtures that violate the rule into test failures instead
  of mysterious downstream symptoms.

  ## Pairing rules

    * An assistant message with N `tool_use` parts (ids `[a, b]`)
      MUST be followed by exactly one `{:tool, _}` message whose
      `parts` contain a matching `ToolResult` for every id.
    * Sets are compared — order within a single `Tool` message
      doesn't matter (mirrors the wire protocol).
    * A `{:tool, _}` message with no preceding assistant
      `tool_use` parts is **orphan_tool_result**.
    * A `{:system, _}`, `{:user, _}`, or `{:assistant, _}` that
      appears between an assistant `tool_use` and its tool
      response is **unclosed_tool_responses** (strict — a system
      reminder mid-pairing rejects the request).
    * End-of-messages while still expecting tool responses is
      **unclosed_tool_responses**.

  `{:compaction, _}` markers are filtered out before walking —
  they live in `state.history`, not in the wire `RunRequest`.
  """

  alias Nest.Messages.Assistant
  alias Nest.Messages.Message
  alias Nest.Messages.Part
  alias Nest.Messages.Tool

  @type error_kind ::
          :orphan_tool_result
          | :missing_tool_responses
          | :unclosed_tool_responses

  @type error :: %{
          kind: error_kind(),
          position: non_neg_integer(),
          orphan_ids: [String.t()],
          missing_ids: [String.t()],
          expected_ids: [String.t()]
        }

  @spec validate_tool_call_pairing([Message.t()]) ::
          :ok | {:error, {:preflight_unpaired_tool_call, [error()]}}
  def validate_tool_call_pairing(messages) do
    visible = Enum.reject(messages, fn {role, _} -> role == :compaction end)

    case walk(visible, :free, [], 0) do
      {[], _final_state} ->
        :ok

      {errors, _final_state} ->
        {:error, {:preflight_unpaired_tool_call, Enum.reverse(errors)}}
    end
  end

  # Walks `messages` and returns `{errors, final_state}`. The
  # state is one of:
  #
  #   * `:free` — last fully-paired turn or no turn in progress.
  #   * `{:need, MapSet.t(String.t())}` — last assistant turn
  #     declared `tool_use` ids we still need to consume.
  #
  # `idx` is the position of the *next* message in `messages`,
  # i.e. `idx` at end-of-list equals the length of `messages`.
  defp walk([], state, errors, idx) do
    final_errors =
      case state do
        {:need, expected} ->
          errors ++
            [
              %{
                kind: :unclosed_tool_responses,
                position: idx,
                orphan_ids: [],
                missing_ids: [],
                expected_ids: MapSet.to_list(expected)
              }
            ]

        _ ->
          errors
      end

    {final_errors, :free}
  end

  defp walk([{role, msg} | rest], state, errors, idx) do
    case state do
      :free ->
        walk_free(rest, role, msg, errors, idx)

      {:need, expected} ->
        walk_need(rest, expected, role, msg, errors, idx)
    end
  end

  # When we're free, system/user/text-only-assistant are no-ops;
  # an assistant with tool_use ids transitions us into `{:need,
  # _}`; a tool message with no preceding tool_use is an
  # orphan_tool_result.
  defp walk_free(rest, :system, _msg, errors, idx) do
    walk(rest, :free, errors, idx + 1)
  end

  defp walk_free(rest, :user, _msg, errors, idx) do
    walk(rest, :free, errors, idx + 1)
  end

  defp walk_free(rest, :assistant, msg, errors, idx) do
    case tool_use_ids(msg) do
      [] ->
        walk(rest, :free, errors, idx + 1)

      ids ->
        walk(rest, {:need, MapSet.new(ids)}, errors, idx + 1)
    end
  end

  defp walk_free(rest, :tool, msg, errors, idx) do
    orphan = tool_result_ids(msg)

    walk(
      rest,
      :free,
      errors ++
        [
          %{
            kind: :orphan_tool_result,
            position: idx,
            orphan_ids: orphan,
            missing_ids: [],
            expected_ids: []
          }
        ],
      idx + 1
    )
  end

  # When we're waiting on tool responses, the *next* message
  # must be a tool message with matching ids. Anything else
  # (system, user, assistant) closes the previous batch as
  # `unclosed_tool_responses` and reprocesses the current
  # message in the new state.
  defp walk_need(rest, expected, :system, _msg, errors, idx) do
    walk(rest, :free, errors ++ [unclosed(idx, expected)], idx + 1)
  end

  defp walk_need(rest, expected, :user, _msg, errors, idx) do
    walk(rest, :free, errors ++ [unclosed(idx, expected)], idx + 1)
  end

  defp walk_need(rest, expected, :assistant, msg, errors, idx) do
    new_state =
      case tool_use_ids(msg) do
        [] -> :free
        ids -> {:need, MapSet.new(ids)}
      end

    walk(
      rest,
      new_state,
      errors ++ [unclosed(idx, expected)],
      idx + 1
    )
  end

  defp walk_need(rest, expected, :tool, msg, errors, idx) do
    result_ids = tool_result_ids(msg)
    result_set = MapSet.new(result_ids)

    missing = MapSet.difference(expected, result_set)
    extra = MapSet.difference(result_set, expected)

    tool_errors = tool_response_errors(idx, expected, missing, extra)
    walk(rest, :free, errors ++ tool_errors, idx + 1)
  end

  defp unclosed(idx, expected) do
    %{
      kind: :unclosed_tool_responses,
      position: idx,
      orphan_ids: [],
      missing_ids: [],
      expected_ids: MapSet.to_list(expected)
    }
  end

  defp tool_response_errors(idx, expected, missing, extra) do
    []
    |> append_error(
      missing,
      fn ids ->
        %{
          kind: :missing_tool_responses,
          position: idx,
          orphan_ids: [],
          missing_ids: MapSet.to_list(ids),
          expected_ids: MapSet.to_list(expected)
        }
      end
    )
    |> append_error(
      extra,
      fn ids ->
        %{
          kind: :orphan_tool_result,
          position: idx,
          orphan_ids: MapSet.to_list(ids),
          missing_ids: [],
          expected_ids: MapSet.to_list(expected)
        }
      end
    )
  end

  defp append_error(errors, set, build) do
    case MapSet.size(set) do
      0 -> errors
      _ -> errors ++ [build.(set)]
    end
  end

  defp tool_use_ids(%Assistant{parts: parts}), do: collect_tool_use_ids(parts)
  defp tool_use_ids(_), do: []

  defp tool_result_ids(%Tool{parts: parts}), do: collect_tool_result_ids(parts)
  defp tool_result_ids(_), do: []

  defp collect_tool_use_ids(nil), do: []

  defp collect_tool_use_ids(parts) when is_list(parts) do
    for(part <- parts, match?(%Part.ToolUse{}, part), do: part.id)
  end

  defp collect_tool_result_ids(nil), do: []

  defp collect_tool_result_ids(parts) when is_list(parts) do
    for(part <- parts, match?(%Part.ToolResult{}, part), do: part.tool_call_id)
  end
end
