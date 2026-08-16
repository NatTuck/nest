defmodule Nest.Agents.Agent.Handlers.LLMStreamHandler.FileAccess do
  @moduledoc """
  `file-read` / `file-write` cache maintenance for the agent.

  The `read_files` cache (`state.chat_state.read_files`) is the
  source of truth for the `file-write` "must read first" /
  "contents changed" policy. The agent's `LLMStreamHandler`
  populates it on every `file-read` and `file-write` tool
  result (the path the agent just took). This module holds the
  read-tracking walker so the parent `LLMStreamHandler` stays
  under credo's 500-line cap.

  Cache key shape: `%{path => %{mtime: posix_int, size: int}}`
  where `path` is the FULL path (workspace_root joined with
  the relative path the LLM used; the policy check resolves
  the same way so the keys match). The
  `IntrospectionHandler.handle/3` `:check_read_policy` clause
  reads this same shape; see
  `test/nest/agents/agent_file_policy_test.exs` for the
  round-trip.

  Extracted to keep `LLMStreamHandler` under credo's
  500-line cap.
  """

  alias Nest.Agents.Agent
  alias Nest.Messages.Part

  require Logger

  @doc """
  Walk a just-appended tool-result message. For every
  `file-read` / `file-write` part that succeeded, stat the
  on-disk file and write `path => %{mtime, size}` to
  `state.chat_state.read_files`. The `is_error` flag and the
  empty-string case both skip silently — a failed read/write
  shouldn't pin a stale mtime into the cache.

  ## All-or-nothing overwrites

  `Map.put/3` is unconditional: a successful `file-write`
  ALWAYS overwrites the cache entry for the same path,
  regardless of what was there before. This is the user-facing
  guarantee that two consecutive `file-write`s from the same
  agent never trigger a false-positive "contents changed"
  (the second write sees the post-first-write stat, not the
  post-read stat). Likewise a successful `file-read` after a
  successful `file-write` overwrites with the latest state.

  ## All-or-nothing reads

  `file-read` is itself all-or-nothing at the tool-closure
  level (it either returns the full content or an error —
  there's no partial-read silent path), so a single
  successful `file-read` either populates the cache
  completely (full file) or doesn't populate at all (failure).
  This module does NOT record for the "read truncated
  because of `max_result_tokens`" case because the BatchSizer
  produces a `ToolResult{is_error: true}` for that path,
  not a partial content body.

  `BatchSizer.FilePolicy` (the gate that runs before every
  `file-write` tool call) consults the same cache key to
  decide whether to refuse the call, so the cache key shape
  here must match the lookup shape there.
  """
  @spec record({atom(), map()}, Agent.t()) :: Agent.t()
  def record({:tool, %{parts: parts}}, state) do
    workspace_path = workspace_root_of(state)

    new_read_files =
      Enum.reduce(parts, state.chat_state.read_files, fn part, acc ->
        case part_for_tracking(part, workspace_path) do
          {:ok, full_path} -> record_stat(acc, full_path)
          :skip -> acc
        end
      end)

    %{state | chat_state: %{state.chat_state | read_files: new_read_files}}
  end

  def record(_, state), do: state

  defp part_for_tracking(
         %Part.ToolResult{name: name, is_error: false, arguments: args},
         workspace_path
       )
       when name in ["file-read", "file-write"] and is_map(args) do
    raw_path = args["path"]

    with true <- is_binary(raw_path) and raw_path != "",
         {:ok, full_path} <- resolve_path(raw_path, workspace_path) do
      {:ok, full_path}
    else
      _ -> :skip
    end
  end

  defp part_for_tracking(_part, _workspace_path), do: :skip

  # Mirror `Nest.Tools.FileTools.resolve_full_path/2`. We can't
  # import it (it's a `defp`); duplicating the two-line branch
  # keeps the read-tracking helper self-contained.
  defp resolve_path(path, workspace_path) do
    cond do
      Path.type(path) == :absolute -> {:ok, path}
      is_binary(workspace_path) -> {:ok, Path.join(workspace_path, path)}
      true -> :skip
    end
  end

  # Defensive: tests that boot an agent with a stub
  # `ClientConfig` (no `:workspace_path` field, e.g. the
  # `MockClient` queue) shouldn't crash here. The
  # `part_for_tracking/2` clause falls back to `:skip` for
  # paths it can't resolve, so a `nil` workspace doesn't
  # lose us any real tool results.
  defp workspace_root_of(state) do
    case state do
      %{workspace_path: root} when is_binary(root) -> root
      _ -> nil
    end
  end

  defp record_stat(read_files, full_path) do
    case File.stat(full_path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, size: size}} when is_integer(mtime) ->
        Map.put(read_files, full_path, %{mtime: mtime, size: size})

      _ ->
        read_files
    end
  end
end
