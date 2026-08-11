defmodule Nest.Agents.AgentTestAssertions do
  @moduledoc """
  Assertion helpers used by `Nest.Agents.AgentTest` and its
  split files. These have no dependencies on the agent's
  lifecycle — they only operate on data shapes that come out
  of the Agent GenServer — so they live in a separate module
  to keep `AgentTestHelpers` (which sets up the supervisor,
  sandbox, and MockClient pipeline) under the credo 500-line
  cap.

  ## Why the boundary exists

  `AgentTestHelpers.start_agent/1` is the canonical entry point
  for a test that needs a live agent. Anything it owns (the
  subprocess, the DB sandbox checkout, the MockClient queue,
  the PubSub subscription) belongs in `AgentTestHelpers`.
  The general-purpose helpers that operate on *already running*
  agents — text serialization, index uniqueness checks, file
  cache seeding, pid-down waits — live here.
  """

  import ExUnit.Assertions

  alias Nest.Messages.Part

  @doc """
  Concatenate the text from a list of `Part` structs, in order.
  Used by tests that used to assert on `message.content` to
  bridge to the parts-based representation. Skips non-text
  parts.
  """
  @spec text_from_parts([Part.t()]) :: String.t()
  def text_from_parts(nil), do: ""
  def text_from_parts([]), do: ""

  def text_from_parts(parts) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %Part.Text{text: text} -> text
      %Part.Thinking{thinking: text} -> text
      %Part.Refusal{refusal: text} -> text
      _ -> ""
    end)
  end

  @doc """
  Assert every message in `state.chat_state.messages` has a
  unique `index` field. Regression guard for the
  dual-counter bug class: a budget reminder and the next
  response used to share an index, causing the UI's
  `addChatMessage` merge to silently overwrite the reminder
  with the response. Call this at the end of any
  chat-flow integration test that drives a turn to
  completion.

  Compaction markers (which are `{:compaction, _}` tuples
  with their own `index` field) are ignored — only the four
  persisted message roles are asserted.
  """
  def assert_unique_message_indices(state) do
    indices =
      state.chat_state.messages
      |> Enum.flat_map(fn
        {_, %{index: idx}} -> [idx]
        _ -> []
      end)

    duplicates = indices -- Enum.uniq(indices)

    assert duplicates == [],
           "duplicate message indices: #{inspect(duplicates)} — dual-counter bug"
  end

  @doc """
  Seed an entry in the agent's `read_files` cache. Tests
  for the `write_file` "must read first" / "contents
  changed" policy use this to skip the streaming `read_file`
  flow and pre-populate the cache with a specific
  `{mtime, size}` pair. Bypasses the `:check_read_policy`
  introspection clause (the worker never gets a chance to
  refuse) — purely a setup helper.

  `path` MUST be the same string the LLM will pass in
  `write_file.arguments["path"]` (i.e. the agent's
  workspace-relative path; the policy check resolves
  relative paths against `client_config.workspace_path`).

  `mtime` defaults to the current POSIX mtime if omitted,
  and `size` defaults to 0. Both can be overridden when
  the test wants to assert a specific staleness error.
  """
  @spec record_read_file(pid(), String.t(), keyword()) :: :ok
  def record_read_file(pid, path, opts \\ []) do
    %{mtime: mtime, size: size} = File.stat!(path, time: :posix)

    recorded = %{
      mtime: Keyword.get(opts, :mtime, mtime),
      size: Keyword.get(opts, :size, size)
    }

    :sys.replace_state(pid, fn state ->
      new_cache = Map.put(state.chat_state.read_files, path, recorded)
      %{state | chat_state: %{state.chat_state | read_files: new_cache}}
    end)
  end
end
