defmodule Nest.Tools.History do
  @moduledoc """
  The `agents-history` tool spec (issue #22).

  Kept in its own module (like `FileTools`, `InspectFile`, `ShellJobs`, and
  `WaitForIdle`) so `Nest.Tools`'s own functions stay small.

  The `function` here is a stub: real execution lives in
  `Nest.Agents.Agent.History.run/2`, which the turn's tool worker reaches
  through `Nest.Agents.Agent.ToolLoop.run_history/2`. It is a plain read of the
  target's persisted message sequence, so it is callable mid-turn and never
  touches the target's process.
  """

  alias Nest.LLM.Tool

  @doc """
  The `agents-history` `Nest.LLM.Tool` struct.
  """
  @spec function() :: Tool.t()
  def function do
    %Tool{
      name: "agents-history",
      description:
        "View the message history of an agent in this space (default: yourself). " <>
          "Two modes. Range: pass `start_index` (default -1) and `length` " <>
          "(default 1); indices are Python-style, so 0 is the first message and a " <>
          "negative index counts from the end — -1 is the last message, -2 the one " <>
          "before it. The window runs forward from the resolved index, so the last " <>
          "message is `start_index: -1` and the last 5 messages are " <>
          "`start_index: -5, length: 5`. An index outside the history, or a window " <>
          "that runs past the end of it, is an error naming the valid range — never " <>
          "a silent truncation. Search: pass `search` (a case-insensitive literal " <>
          "substring) instead of `start_index`/`length` and get back a JSON object " <>
          ~s|{"agent": ..., "query": ..., "matches": [{"index": N, "role": "user",| <>
          ~s| "text": "...", "text_truncated": false}]} with one match per message | <>
          "that contains it, in index order; `text` is a snippet around " <>
          "the first occurrence in that message and `text_truncated` says whether " <>
          "that message's text was longer. Read a match in full with a range read " <>
          "at its index. The agent must be in your own space, and an archived " <>
          "agent is refused (restore it with `agents-unarchive` first).",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The agent whose history to read. Defaults to you."
          },
          "start_index" => %{
            "type" => "integer",
            "description" =>
              "First message index to return. Defaults to -1 (the last message). " <>
                "Negative counts from the end: -1 is the last message, -2 the one " <>
                "before it."
          },
          "length" => %{
            "type" => "integer",
            "description" =>
              "How many messages to return, starting at `start_index` and moving " <>
                "forward (toward newer messages). Defaults to 1. Must be a positive " <>
                "integer; a window that runs past the end of the history is an error."
          },
          "search" => %{
            "type" => "string",
            "description" =>
              "Search the whole history for a case-insensitive literal substring " <>
                "instead of reading a range. Returns a JSON object with a `matches` " <>
                "list. Do not pass this together with `start_index` or `length`."
          }
        },
        "required" => []
      },
      function: fn _args, _context ->
        {:ok, "History request received."}
      end
    }
  end
end
