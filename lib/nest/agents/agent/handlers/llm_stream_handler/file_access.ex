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
  alias Nest.Sandbox
  alias Nest.Sandbox.Mounts

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
    mounts = Mounts.from_agent(state)

    new_read_files =
      Enum.reduce(parts, state.chat_state.read_files, fn part, acc ->
        case part_for_tracking(part, mounts) do
          {:ok, full_path} -> record_stat(acc, full_path, state)
          :skip -> acc
        end
      end)

    %{state | chat_state: %{state.chat_state | read_files: new_read_files}}
  end

  def record(_, state), do: state

  defp part_for_tracking(
         %Part.ToolResult{name: name, is_error: false, arguments: args},
         mounts
       )
       when name in ["file-read", "file-write"] and is_map(args) do
    raw_path = args["path"]

    with true <- is_binary(raw_path) and raw_path != "",
         {:ok, full_path} <- Mounts.resolve(raw_path, mounts) do
      {:ok, full_path}
    else
      _ -> :skip
    end
  end

  defp part_for_tracking(_part, _mounts), do: :skip

  # `Mounts.from_agent/1` matches the agent's `:mounts` key hard rather than
  # guarding for its absence, and that is safe here: every call site passes an
  # `%Nest.Agents.Agent{}`, whose struct always carries it. The
  # `when is_binary(root)` guard this replaced could only have absorbed a
  # malformed agent-shaped map, which is a bug rather than a case to keep.
  defp record_stat(read_files, full_path, state) do
    # `full_path` is the path the agent used, in the domain the agent names.
    case Sandbox.stat(full_path, Agent.resolve_caps(state), Mounts.from_agent(state),
           time: :posix
         ) do
      {:ok, %File.Stat{mtime: mtime, size: size}} when is_integer(mtime) ->
        Map.put(read_files, full_path, %{mtime: mtime, size: size})

      _ ->
        read_files
    end
  end
end
