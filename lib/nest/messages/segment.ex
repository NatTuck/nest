defmodule Nest.Messages.Segment do
  @moduledoc """
  A rendered body split into segments, and the rule that joins bodies.

  A user-role row is not uniformly prose (issue #139). A backgrounded shell
  command's notice is the sentence that announces it followed by the command's
  own output, and a drained batch is one body per inbox entry; the browser has
  to render the output as command output — fixed font, collapsed when long —
  rather than as markdown, which mangles `#`, `*`, `_`, backticks and indented
  lines. So a body is rendered as an ordered list of segments, each tagged with
  how the client renders it:

    * `{:text, text}` — prose, rendered as markdown.
    * `{:output, text}` — a backgrounded command's own output, rendered
      verbatim.

  The tag never changes the text. Every producer's segments are joined with no
  separator to make the string the model reads
  (`Nest.Agents.Agent.Turn.Backgrounded.notice/1`,
  `Nest.Agents.Agent.Inbox.Render.combine/2`), so which segments are `:output`
  is a rendering fact only — `Nest.Messages.User.command_output_metadata/1`
  turns it into the wire's `"commandOutputParts"`.

  `separate/1` is the one rule two renderers share: bodies are separated by a
  blank line, carried by the **last segment of every body but the last** so the
  next body starts a paragraph of its own. It appends while keeping the
  segment's tag — a body that ends in command output must still end in command
  output, or the client would render its last line as markdown.
  """

  @typedoc """
  One piece of a rendered body: `:text` is prose, `:output` is a backgrounded
  command's own output.
  """
  @type t :: {:text | :output, String.t()}

  @doc """
  Join `groups` — one list of segments per body — into a single segment list,
  putting a blank line between bodies and none after the last.

  The blank line rides the preceding body's last segment, so no segment is ever
  a bare separator: a separator segment would become a `Part.Text` of its own
  and an empty markdown block in the browser.

  Every group must be non-empty — a body always renders at least one segment
  (a notice's prose, an entry's headered body) — because a group with nothing in
  it has no last segment to carry the separator. Both callers guarantee it; a
  group that did not would raise here rather than silently losing the blank
  line.
  """
  @spec separate([[t()]]) :: [t()]
  def separate([]), do: []

  def separate(groups) do
    last = length(groups) - 1

    groups
    |> Enum.with_index()
    |> Enum.flat_map(fn {segments, index} ->
      if index == last, do: segments, else: append_to_last(segments, "\n\n")
    end)
  end

  defp append_to_last(segments, suffix) do
    {init, [{kind, text}]} = Enum.split(segments, -1)
    init ++ [{kind, text <> suffix}]
  end
end
