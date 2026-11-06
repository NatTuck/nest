defmodule Nest.Agents.Agent.Inbox.Render do
  @moduledoc """
  The LLM-facing rendering of a drain batch, split out of
  `Nest.Agents.Agent.Inbox` to keep that module under the credo line cap.

  This module owns one responsibility: **what one inbox entry reads as** when
  the drain delivers it to the model. A batch is its entries joined by a blank
  line (`combine/2`), and each entry contributes its own body:

    * **every body carries its own header** (`Nest.Messages.Header`), stating
      who sent it and the mode the recipient's turn will run in. That is what
      disambiguates a batch of peer messages from each other and from a human's
      (issue #31 decision 7 for a `:query`, whose requester really is that
      agent), and it is why a batch row has no header of its own;
    * a `:runtime` entry says `nest runtime` whatever agent it is *about*, so
      the runtime's own words can never be framed as an agent's (issue #31
      decision 9) — the impersonation the retired `[nest notice]` marker
      existed to prevent;
    * a `:query` adds `, agents-send reply required`: it is the one kind that
      obliges an answer;
    * a missing or blank sender still says `agent` — the body must not read as
      a human's, and printing `nil` would be worse.

  The same text is what the over-cap offload measures: a batch over
  `Nest.Agents.Agent.Config.configured_async_message_max_tokens/0` is written
  to the agent's scratch dir and replaced by a short pointer naming the file,
  so the model reads it back there instead of the whole batch riding the
  prompt.

  ## Segments: the batch row is more than one text part (issue #139)

  `parts/2` is the rendering in segments — `{:text, String.t()}` for prose and
  `{:output, String.t()}` for a backgrounded command's own output — and
  `combine/2` is exactly the join of those segments' texts. That is the
  invariant that makes the split a *display* change: everything that reads a
  batch as a string (the offload's size measurement, the pointer, the message's
  joined text, the model's prompt) sees the same bytes it always did.

  So the delivered row carries **one `%Part.Text{}` per rendered segment**:
  one per body, plus one per command output inside a backgrounded notice. Every
  consumer joins text parts with `""` (`Nest.LLM.Client.text_from_parts/1`), so
  the model-facing text is unchanged; the split exists so the browser can render
  a command's output as output instead of as markdown, which mangles `#`, `*`,
  `_`, backticks and indented lines. Which parts those are is stated on the row
  by `Nest.Messages.User.command_output_metadata/1` — the wire's
  `"commandOutputParts"`, a list of indexes into `"parts"`.

  **The header goes on the first segment only.** A body's header is a prefix
  (`Header.put(a <> rest) == Header.put(a) <> rest`), so applying it to the
  first segment puts it at the head of the body exactly as before — and keeps it
  off the command output, which is the whole point.

  ## Where the marker sits

  A body's header heads the **body**, not the delivered message: a batch is its
  bodies joined by a blank line, so a notice behind a peer's entry puts the
  header at the head of the second body. The client's strip is therefore a
  whole-line-at-the-head-of-any-body removal rather than a single leading-prefix
  removal (`assets/js/utils/stripHeader.js`); this module's contract is only
  that a body starts with its own header — which `parts/2` guarantees by
  headering the first segment of every entry, and which the segments cannot
  break, because the first segment's first line is the body's first line.

  The **offload** is the one case with no command output: the pointer replaced
  the whole text, and the pointer is the runtime's own sentence — so the row is
  one text part carrying the runtime's header, and no `"commandOutputParts"` at
  all. Which row it is is **stated** by `combine_and_offload/2` rather than
  inferred from the content afterwards (issue #147): it hands back the delivered
  parts, so nothing has to re-render the batch and compare.

  `build_drained_message/3` is the seam's other half: the one place a drained
  batch becomes the message the transcript carries, so the batch's metadata —
  the `fulfilled_ids` a notice answers and the human recall marker — has a
  single writer.

  The entries rendered here are `t:Nest.Agents.Agent.Inbox.entry/0`.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Inbox.Delivery
  alias Nest.Agents.Agent.ResultPolicy
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Messages.Header
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.Segment
  alias Nest.Messages.User
  alias Nest.Sandbox.Mounts

  @doc """
  Combine one drain batch and admit it: whole when it fits, offloaded to the
  agent scratch dir when it does not. Returns the content to deliver.

  `{:error, reason}` means the batch was too large to inline and could not be
  written either — the caller must leave the entries queued and surface the
  reason. Nothing is ever inlined over the budget and nothing is dropped.

  Used by the turn executor's drain actions, which pass `Inbox.batch/1`'s
  selection so the entries rendered are exactly the entries consumed.
  """
  @spec combine_and_offload([map()], Agent.t()) ::
          {:ok, String.t(), [Segment.t()] | nil} | {:error, String.t()}
  def combine_and_offload(entries, state) do
    # `state.live.mode` is the mode the turn will run in — the drain applies the
    # batch's own request before it renders (see `Turn.Executor.peek_inbox/1`) —
    # so a peer delivery's header states the mode the *recipient* is about to
    # work under, which is what every message an agent receives has to say.
    mode = state.live.mode
    content = combine(entries, mode)

    case offload(content, length(entries), Delivery.batch_id(entries), state) do
      # Inlined: the delivered row *is* the batch's own rendering, so there is
      # no separate part list to state — `nil` says "render the batch".
      {:ok, ^content} ->
        {:ok, content, nil}

      # Offloaded: the pointer is the runtime's own sentence about the batch, so
      # the row says `nest runtime` and is one text part with no command output.
      # The file it points at keeps the whole rendered batch, headers and all.
      {:ok, pointer} ->
        text = Header.put(pointer, :runtime, mode)
        {:ok, text, [{:text, text}]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Admit one message: whole when it fits, offloaded to the agent's scratch dir
  when it does not.

  The single-message path (`ChatPipeline.handle_chat`) and the drain share this
  rule; they differ only in what the pointer says, because a batch pointer has
  to say how many bodies the file holds. A message is never inlined over the
  budget and never dropped.
  """
  @spec admit_single(term(), Agent.t()) :: {:ok, term()} | {:error, String.t()}
  def admit_single({:user, %User{} = user} = message, state) do
    content = text_of(user)

    case offload(content, 0, nil, state) do
      {:ok, ^content} ->
        {:ok, message}

      # The pointer replaced the message's own text — including its header — so
      # the row states the runtime, which is who is saying "it was too large".
      {:ok, pointer} ->
        text = Header.put(pointer, :runtime, state.live.mode)
        {:ok, {:user, %{user | parts: [%Part.Text{text: text}]}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def admit_single(message, _state), do: {:ok, message}

  defp text_of(%User{parts: parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %Part.Text{text: text} -> text || ""
      _other -> ""
    end)
  end

  defp text_of(%User{}), do: ""

  @doc """
  The user message a drained batch is delivered as.

  `content` is the batch's combined text (`combine_and_offload/2`) and `mode`
  the drain's winning mode; `Dispatch.build_user_message/3` builds the message
  itself, given the batch's segments as its parts. The batch's `fulfilled_ids`
  also ride it as message metadata (`MessageList.fulfilled_metadata/1`): a
  backgrounded batch's notice answers or closes those calls, so a later load can
  tell a promise that was kept from one the process died with
  (`MessageList.backgrounded_results/1`).

  The row's text is `content` — the caller has already used it for the fit
  check and the offload — and `parts` is what `combine_and_offload/2` handed
  back, whose join is `content` in every case. Which of them are command output
  is stated by `User.command_output_metadata/1`, the only writer of that key.

  The single writer of that marker, so every drain shape builds its message here
  — including the backgrounding path, which delivers a *notice* entry when one
  was queued while another batch executed.
  """
  @spec build_drained_message([map()], String.t(), [Segment.t()] | nil, String.t()) ::
          {:user, User.t()}
  def build_drained_message(entries, content, parts, mode) do
    # `parts` is what `combine_and_offload/2` stated: `nil` when the batch was
    # inlined (the row is the batch's own rendering), the pointer row when it was
    # not. Nothing is re-rendered to find out which.
    parts = parts || parts(entries, mode)

    metadata =
      entries
      |> MessageList.drained_metadata()
      |> Map.merge(User.command_output_metadata(parts))

    # No `:sender`: a batch is one row holding several bodies, and each body
    # already carries its own header (`combine/2`) — which `parts/2` has already
    # applied, so the parts passed here are final.
    Dispatch.build_user_message(content, mode,
      parts: Enum.map(parts, fn {_kind, text} -> %Part.Text{text: text} end),
      metadata: metadata
    )
  end

  @doc """
  The batch's rendering as ordered segments: `:text` for prose, `:output` for a
  backgrounded command's own output.

  `combine/2` is this list's texts joined with no separator, and that equality
  is the module's contract — every string consumer of a batch (the offload's
  measurement, the pointer, the delivered row's text) goes through the join, so
  the segment split can never change what the model reads.

  An entry with no segments of its own contributes its body as one `:text`
  segment, headered exactly as it always was. An entry that carries segments (a
  backgrounded notice, `Inbox.enqueue_runtime/3`) contributes them, with the
  header applied to the **first** one only: the header is a prefix, so it still
  heads the body, and it stays off the command output. Entries are separated by
  a blank line, carried by the last segment of every entry but the last.
  """
  @spec parts([map()], String.t()) :: [Segment.t()]
  def parts(entries, mode) do
    entries
    |> Enum.map(&entry_parts(&1, mode))
    |> Segment.separate()
  end

  # ---- private ----

  # The LLM-facing rendering of one drain batch. Each body opens with its own
  # header, so a queued human message reads exactly like one that arrived while
  # the agent was idle (issue #31 decision 8): the model never has to reason
  # about whether it was queued. The batch row itself carries no header — there
  # is no single sender to state.
  defp combine(entries, mode) do
    entries
    |> parts(mode)
    |> Enum.map_join("", &elem(&1, 1))
  end

  # One entry's segments. A producer-supplied segment list is the backgrounded
  # notice's (issue #139): its own split of `content`, so the command output in
  # it is marked rather than re-derived from the text.
  defp entry_parts(entry, mode) do
    human? = Map.get(entry, :source, false) != false
    sender = Header.sender(Map.get(entry, :from), human?, entry.kind)
    reply? = entry.kind == :query

    case Map.get(entry, :parts) do
      [_ | _] = segments -> header_first(segments, sender, mode, reply?)
      _plain -> [{:text, Header.put(entry.content, sender, mode, reply?)}]
    end
  end

  # The header heads the *body*, and the body is the first segment: `Header.put`
  # is a prefix, so `put(a <> rest) == put(a) <> rest`. Applying it here — rather
  # than to the joined text and then splitting — is what keeps it off a notice's
  # command output.
  defp header_first([{kind, text} | rest], sender, mode, reply?) do
    [{kind, Header.put(text, sender, mode, reply?)} | rest]
  end

  # The blank line between entries is `Nest.Messages.Segment.separate/1`'s: it
  # rides each entry's last segment, keeping that segment's kind, so an entry
  # that ends in command output still ends in command output — otherwise the
  # client would render its last line as markdown.
  # The same admission the tool results get, with `requested` being the
  # configured async-message cap: the content is inlined whole when it fits, and
  # written to the agent's scratch dir with a pointer when it does not. A write
  # that fails is its own error — the caller keeps the batch queued and says so,
  # rather than inlining something over the budget or dropping it.
  defp offload(content, count, id, state) do
    # The message cap is intrinsic: it is about how much a single body may
    # carry, not about how full the conversation is. A message over it is filed,
    # because a large paste must not force a compaction; a message under it is
    # delivered whole and the *conversation* being full is what the fit
    # decision (and so a compaction) is for.
    limit = Config.configured_async_message_max_tokens()

    case ResultPolicy.admit(content, limit, :file) do
      {:inline, _size} ->
        {:ok, content}

      {:file, size} ->
        case Overflow.write(
               content,
               %{mounts: Mounts.from_agent(state)},
               "agent-inbox",
               "txt",
               id
             ) do
          nil -> {:error, ResultPolicy.offload_failure(size)}
          path -> {:ok, pointer(count, path)}
        end

      {:refuse, size} ->
        {:error, ResultPolicy.refusal(size, limit, "queued message")}
    end
  end

  defp pointer(0, path) do
    "Your message was too large to include inline and was saved to #{path}. " <>
      "Read that file to see it."
  end

  defp pointer(1, path) do
    "You have 1 queued message. It was too large to " <>
      "include inline and was saved to #{path}. Read that file to see it."
  end

  defp pointer(n, path) do
    "You have #{n} queued messages. They were too large to " <>
      "include inline and were saved to #{path}. Read that file to see them."
  end
end
