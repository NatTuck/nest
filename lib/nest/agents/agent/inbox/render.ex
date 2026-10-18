defmodule Nest.Agents.Agent.Inbox.Render do
  @moduledoc """
  The LLM-facing rendering of a drain batch, split out of
  `Nest.Agents.Agent.Inbox` to keep that module under the credo line cap.

  This module owns one responsibility: **what one inbox entry reads as** when
  the drain delivers it to the model. A batch is its entries joined by a blank
  line (`combine/1`), and each entry contributes its own body:

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

  ## Where the marker sits

  The marker heads the notice **body**, not the delivered message: a batch is
  its bodies joined by a blank line, so a notice behind a peer's entry puts
  the marker at the head of the second body. The client's strip is therefore a
  marker-at-the-head-of-any-body removal rather than a single leading-prefix
  removal (`assets/js/utils/stripNoticePrefix.js`); this module's contract is
  only that a notice's own body starts with it, which `render_entry/1`
  guarantees by tagging the entry's content.

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
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Messages.Header
  alias Nest.Messages.MessageList
  alias Nest.Messages.User
  alias Nest.Sandbox.Mounts
  alias Nest.Tokens.Estimator

  @doc """
  Combine one drain batch and, when over the async-message cap, offload the
  text to the agent scratch dir. Returns the content string to deliver.
  Used by the turn executor's drain actions, which pass `Inbox.batch/1`'s
  selection so the entries rendered are exactly the entries consumed.
  """
  @spec combine_and_offload([map()], Agent.t()) :: String.t()
  def combine_and_offload(entries, state) do
    # `state.live.mode` is the mode the turn will run in — the drain applies the
    # batch's own request before it renders (see `Turn.Executor.peek_inbox/1`) —
    # so a peer delivery's header states the mode the *recipient* is about to
    # work under, which is what every message an agent receives has to say.
    offload(combine(entries, state.live.mode), entries, state)
  end

  @doc """
  The user message a drained batch is delivered as.

  `content` is the batch's combined text (`combine_and_offload/2`) and `mode`
  the drain's winning mode; `Dispatch.build_user_message/3` builds the message
  itself. The batch's `fulfilled_ids` also ride it as message metadata
  (`MessageList.fulfilled_metadata/1`): a backgrounded batch's notice answers or
  closes those calls, so a later load can tell a promise that was kept from one
  the process died with (`MessageList.backgrounded_results/1`).

  The single writer of that marker, so every drain shape builds its message here
  — including the backgrounding path, which delivers a *notice* entry when one
  was queued while another batch executed.
  """
  @spec build_drained_message([map()], String.t(), String.t()) :: {:user, User.t()}
  def build_drained_message(entries, content, mode) do
    # No `:sender`: a batch is one row holding several bodies, and each body
    # already carries its own header (`combine/2`).
    Dispatch.build_user_message(content, mode, metadata: MessageList.drained_metadata(entries))
  end

  # ---- private ----

  # The LLM-facing rendering of one drain batch. Each body opens with its own
  # header, so a queued human message reads exactly like one that arrived while
  # the agent was idle (issue #31 decision 8): the model never has to reason
  # about whether it was queued. The batch row itself carries no header — there
  # is no single sender to state.
  defp combine(entries, mode) do
    Enum.map_join(entries, "\n\n", &render_entry(&1, mode))
  end

  # Every body states its sender and the mode the recipient will run the
  # delivered turn in, which is what `Nest.Messages.Header` is for. The mode is
  # the recipient's because that is what the agent needs to know about itself —
  # a peer's message is the only place an agent whose inbox is all peer traffic
  # ever sees its own mode — and it is not a request to change anything (a
  # request rides `set_mode`, and arrives as an entry of its own).
  #
  # The kind decides two of the three facts: `:query` is the one kind that
  # obliges an answer, and `:runtime` is the runtime speaking whatever agent it
  # is about.
  defp render_entry(entry, mode) do
    sender = Header.sender(Map.get(entry, :from), Map.get(entry, :human?, false), entry.kind)

    Header.put(entry.content, sender, mode, entry.kind == :query)
  end

  # Over the configured cap, write the full combined text to the agent's
  # scratch dir and return a pointer. If the write fails, fall back to
  # the full text so no messages are lost.
  defp offload(content, entries, state) do
    if Estimator.estimate(content) > Config.configured_async_message_max_tokens() do
      case Overflow.write(
             content,
             %{mounts: Mounts.from_agent(state)},
             "agent-inbox",
             "txt",
             Delivery.batch_id(entries)
           ) do
        nil -> content
        path -> pointer(length(entries), path)
      end
    else
      content
    end
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
