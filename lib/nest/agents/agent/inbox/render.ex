defmodule Nest.Agents.Agent.Inbox.Render do
  @moduledoc """
  The LLM-facing rendering of a drain batch, split out of
  `Nest.Agents.Agent.Inbox` to keep that module under the credo line cap.

  This module owns one responsibility: **what one inbox entry reads as** when
  the drain delivers it to the model. A batch is its entries joined by a blank
  line (`combine/1`), and each entry contributes its own body:

    * a `:user` entry (a human's words) and a `:runtime` entry (the runtime
      speaking for itself) render with **no agent label** — no agent said either,
      and a `[Message from agent "X"]` label on a notice would impersonate `X`
      (issue #31 decision 9) — and the notice additionally carries the
      `[nest notice]` marker at the head of its text (`NoticeTag.tag/1`), the
      wire-level signal that this body is the runtime's own (the client strips
      it on render, so only the model reads it);
    * every other kind keeps its `[Message from agent "X"]` label, which is
      what disambiguates a batch of peer messages from each other and from a
      human's (issue #31 decision 7 for a `:query`, whose requester really is
      that agent). A missing or blank sender drops the quoted name rather than
      putting `nil` in the prompt.

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
  alias Nest.Messages.MessageList
  alias Nest.Messages.NoticeTag
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
    Dispatch.build_user_message(content, mode, MessageList.drained_metadata(entries))
  end

  # ---- private ----

  # The LLM-facing rendering of one drain batch. A human entry is rendered as
  # its bare content — plus, later, the `[mode: X]\n` prefix
  # `Dispatch.build_user_message/2` adds — because a queued human message must
  # read exactly like one that arrived while the agent was idle (issue #31
  # decision 8): the model never has to reason about whether it was queued.
  # A `:runtime` entry keeps no `[Message from agent "X"]` label either — it is the
  # runtime speaking, and the label would impersonate X (decision 9) — but it
  # does carry the `[nest notice]` marker at the head of its own text, which is
  # what tells the model (and, once the client strips it, only the model) that
  # this body is the runtime's own. Every other kind keeps its
  # `[Message from agent "X"]` label, which is what disambiguates a batch of
  # peer messages (from each other and from a human's) — including a `:query`,
  # whose requester really is that agent (decision 7).
  defp combine(entries, mode) do
    Enum.map_join(entries, "\n\n", &render_entry(&1, mode))
  end

  defp render_entry(%{kind: :runtime, content: content}, _mode), do: NoticeTag.tag(content)

  defp render_entry(%{kind: :user, content: content}, _mode), do: content

  defp render_entry(%{content: content} = entry, mode),
    do: "#{agent_label(entry, mode)}\n#{content}"

  # The LLM-facing label for one `:agent` entry: who sent it, and the mode the
  # *recipient* will run the delivered turn in. The mode is the recipient's
  # because that is what the agent needs to know about itself — a peer's message
  # is the only place an agent whose inbox is all peer traffic ever sees its own
  # mode — and it is not a request to change anything (a request rides
  # `set_mode`, and arrives as an entry of its own).
  #
  # A missing or blank sender drops the quoted name rather than putting
  # `nil`/`""` in the prompt, and a mode-less render (an entry that predates the
  # clause, or a caller with no mode to state) keeps the older bare label.
  defp agent_label(%{from: from}, mode) when is_binary(mode),
    do: "[Message from agent#{quoted(from)} | mode: #{mode}]"

  defp agent_label(%{from: from}, _mode), do: "[Message from agent#{quoted(from)}]"

  defp quoted(from) when is_binary(from) and from != "", do: " \"#{from}\""
  defp quoted(_from), do: ""

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
