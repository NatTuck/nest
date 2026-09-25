defmodule Nest.LLM.Preflight do
  @moduledoc """
  Validates a `RunRequest.messages` list for sequencing rules that
  Anthropic enforces on the wire.

  ## Rules

  `validate/1` runs a named rule list and unions every violation (it
  does not stop at the first):

    * `:known_roles` — only `:system`, `:user`, `:assistant`, `:tool`,
      and `:compaction` (compaction markers are ignored).
    * `:tool_pairing` — each assistant `tool_use.id` must be matched by
      a tool result in the immediately-following `{:tool, _}` message.
    * `:no_orphan_tool_results` — a `{:tool, _}` message must answer the
      `tool_use` ids of the immediately-preceding assistant, with no
      extra ids.
    * `:alternation` — no two consecutive `user` or `assistant`
      messages on the Anthropic wire (`{:tool, _}` is wire role `user`;
      `{:system, _}` is ignored for alternation).
    * `:no_trailing_orphan` — the list must not end with an assistant
      whose `tool_use` is unanswered.

  `validate_tool_call_pairing/1` is the legacy wrapper used by
  `Nest.LLM.MockClient` for its 400-parody. It returns the original
  `kind`-based error shape without the `:rule` tag.
  """

  alias Nest.Messages.Assistant
  alias Nest.Messages.Message
  alias Nest.Messages.Part
  alias Nest.Messages.Tool

  @rules [
    :known_roles,
    :tool_pairing,
    :no_orphan_tool_results,
    :alternation,
    :no_trailing_orphan
  ]

  @known_roles [:system, :user, :assistant, :tool, :compaction]

  @type rule ::
          :known_roles
          | :tool_pairing
          | :no_orphan_tool_results
          | :alternation
          | :no_trailing_orphan

  @type error_kind ::
          :unknown_role
          | :orphan_tool_result
          | :missing_tool_responses
          | :unclosed_tool_responses
          | :alternation_violation

  @type violation :: %{
          optional(:role) => atom(),
          rule: rule(),
          kind: error_kind(),
          position: non_neg_integer(),
          orphan_ids: [String.t()],
          missing_ids: [String.t()],
          expected_ids: [String.t()]
        }

  # Kept for the legacy `validate_tool_call_pairing/1` return shape.
  @type error :: %{
          kind: error_kind(),
          position: non_neg_integer(),
          orphan_ids: [String.t()],
          missing_ids: [String.t()],
          expected_ids: [String.t()]
        }

  @doc """
  The named rule list run by `validate/1`.
  """
  @spec rules() :: [rule()]
  def rules, do: @rules

  @doc """
  Run every rule and return all violations (or `:ok`).

  See the moduledoc for the rule list.
  """
  @spec validate([Message.t()]) :: :ok | {:error, [violation()]}
  def validate(messages) do
    visible = reject_compaction(messages)

    {errors, _final_state} = walk(visible, {:free, nil}, [], 0)

    violations =
      errors
      |> Enum.reverse()
      |> Enum.map(&tag_rule(&1, length(visible)))
      |> Kernel.++(known_role_violations(messages))

    case violations do
      [] -> :ok
      _ -> {:error, violations}
    end
  end

  @doc """
  Legacy pairing/alternation check used by `Nest.LLM.MockClient`.

  Returns `:ok` or
  `{:error, {:preflight_unpaired_tool_call, [error()]}}` with the
  original `kind`-based error map (no `:rule` tag).
  """
  @spec validate_tool_call_pairing([Message.t()]) ::
          :ok | {:error, {:preflight_unpaired_tool_call, [error()]}}
  def validate_tool_call_pairing(messages) do
    visible = reject_compaction(messages)

    case walk(visible, {:free, nil}, [], 0) do
      {[], _final_state} ->
        :ok

      {errors, _final_state} ->
        {:error, {:preflight_unpaired_tool_call, Enum.reverse(errors)}}
    end
  end

  @doc """
  Format violations as a single human-readable line for the
  `chat:error` path (rule name + offending ids/positions).
  """
  @spec format_violations([violation()]) :: String.t()
  def format_violations(violations) do
    details = Enum.map_join(violations, "; ", &format_violation/1)

    "Refusing to send an invalid message sequence (wire preflight): " <> details
  end

  # --- rules ---

  # Tag a `kind`-based walk error with the rule that produced it.
  defp tag_rule(%{kind: :missing_tool_responses} = error, _length) do
    Map.put(error, :rule, :tool_pairing)
  end

  defp tag_rule(%{kind: :unclosed_tool_responses, position: position} = error, length) do
    rule = if position == length, do: :no_trailing_orphan, else: :tool_pairing
    Map.put(error, :rule, rule)
  end

  defp tag_rule(%{kind: :orphan_tool_result} = error, _length) do
    Map.put(error, :rule, :no_orphan_tool_results)
  end

  defp tag_rule(%{kind: :alternation_violation} = error, _length) do
    Map.put(error, :rule, :alternation)
  end

  defp known_role_violations(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reject(fn {{role, _}, _idx} -> role in @known_roles end)
    |> Enum.map(fn {{role, _}, idx} ->
      %{
        rule: :known_roles,
        kind: :unknown_role,
        position: idx,
        orphan_ids: [],
        missing_ids: [],
        expected_ids: [],
        role: role
      }
    end)
  end

  defp format_violation(%{rule: :known_roles, position: pos, role: role}) do
    "known_roles: unknown role #{inspect(role)} at #{pos}"
  end

  defp format_violation(%{rule: :tool_pairing} = v) do
    ids = v.missing_ids ++ v.expected_ids

    "tool_pairing: tool_use at #{v.position} missing tool_result(s) for #{inspect(Enum.uniq(ids))}"
  end

  defp format_violation(%{rule: :no_orphan_tool_results} = v) do
    "no_orphan_tool_results: orphan tool_result at #{v.position} for #{inspect(v.orphan_ids)}"
  end

  defp format_violation(%{rule: :no_trailing_orphan} = v) do
    "no_trailing_orphan: unpaired tool_use at #{v.position} for #{inspect(v.expected_ids)}"
  end

  defp format_violation(%{rule: :alternation, position: pos}) do
    "alternation: consecutive same-role messages at #{pos}"
  end

  defp reject_compaction(messages) do
    Enum.reject(messages, fn {role, _} -> role == :compaction end)
  end

  # State: {pairing_state, last_wire_role}
  # pairing_state: :free | {:need, MapSet.t()}
  # last_wire_role: :user | :assistant | nil

  defp walk([], state, errors, idx) do
    {final_errors, _} = finalize_errors(state, errors, idx)
    {final_errors, :free}
  end

  defp walk([{role, msg} | rest], {pairing, last_role}, errors, idx) do
    wire_role = wire_role_for(role, msg)
    alt_errors = check_alternation(last_role, wire_role, idx, errors)
    {next_errors, next_state} = dispatch(pairing, role, msg, alt_errors, idx, wire_role)
    walk(rest, next_state, next_errors, idx + 1)
  end

  defp dispatch({:need, expected}, :tool, msg, errors, idx, _wire_role) do
    result_ids = tool_result_ids(msg)
    result_set = MapSet.new(result_ids)
    missing = MapSet.difference(expected, result_set)
    extra = MapSet.difference(result_set, expected)
    {errors ++ tool_response_errors(idx, expected, missing, extra), {:free, :user}}
  end

  defp dispatch({:need, expected}, _role, _msg, errors, idx, wire_role) do
    {errors ++ [unclosed(idx, expected)], {:free, wire_role}}
  end

  defp dispatch(:free, :tool, msg, errors, idx, wire_role) do
    orphan = tool_result_ids(msg)
    {errors ++ [orphan_error(idx, orphan)], {:free, wire_role}}
  end

  defp dispatch(:free, :assistant, msg, errors, _idx, wire_role) do
    case tool_use_ids(msg) do
      [] -> {errors, {:free, wire_role}}
      ids -> {errors, {{:need, MapSet.new(ids)}, wire_role}}
    end
  end

  defp dispatch(pairing, _role, _msg, errors, _idx, wire_role) do
    {errors, {pairing, wire_role}}
  end

  defp finalize_errors({{:need, expected}, _last_role}, errors, idx) do
    {errors ++ [unclosed(idx, expected)], :free}
  end

  defp finalize_errors(_, errors, _idx), do: {errors, :free}

  defp check_alternation(nil, _new_role, _idx, errors), do: errors

  defp check_alternation(same, same, idx, errors) when same in [:user, :assistant] do
    errors ++ [alternation_error(idx, same)]
  end

  defp check_alternation(_last, _new, _idx, errors), do: errors

  defp wire_role_for(:system, _msg), do: nil
  defp wire_role_for(:user, _msg), do: :user
  defp wire_role_for(:tool, _msg), do: :user

  defp wire_role_for(:assistant, %Assistant{parts: parts}) do
    if has_tool_use?(parts), do: :assistant, else: :assistant
  end

  defp wire_role_for(:assistant, _msg), do: :assistant
  defp wire_role_for(_unknown, _msg), do: nil

  defp has_tool_use?(parts) do
    Enum.any?(parts || [], &match?(%Part.ToolUse{}, &1))
  end

  defp alternation_error(idx, role) do
    %{
      kind: :alternation_violation,
      position: idx,
      orphan_ids: [],
      missing_ids: [],
      expected_ids: [role]
    }
  end

  defp orphan_error(idx, orphan) do
    %{
      kind: :orphan_tool_result,
      position: idx,
      orphan_ids: orphan,
      missing_ids: [],
      expected_ids: []
    }
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
    |> append_error(missing, fn ids ->
      %{
        kind: :missing_tool_responses,
        position: idx,
        orphan_ids: [],
        missing_ids: MapSet.to_list(ids),
        expected_ids: MapSet.to_list(expected)
      }
    end)
    |> append_error(extra, fn ids ->
      %{
        kind: :orphan_tool_result,
        position: idx,
        orphan_ids: MapSet.to_list(ids),
        missing_ids: [],
        expected_ids: MapSet.to_list(expected)
      }
    end)
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
