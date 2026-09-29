defmodule Nest.Persistence.AgentCompaction.Planner do
  @moduledoc """
  Pure planner for the offline agent compaction tool
  (`mix nest.compact_agent`).

  Given a persisted agent row, its full resolved message sequence,
  the resolved context limits, and the re-rendered system prompt, it
  produces a `%Planner{}` describing the offline compaction without
  touching the database or the LLM:

    * the **active prefix** to summarize: the longest contiguous run
      of rows after `agents.last_compaction_index` (starting at the
      boundary + 1). A history whose rows are not contiguous (a
      previous compaction crashed mid-write) yields `orphans` — the
      rows after the first gap, and any row at or past
      `next_message_index` — which the writer deletes;
    * the **marker slot** (`max(next_message_index, prefix_end + 1)`)
      and the new active rows' indices;
    * the **summary budget** (`summary_budget`) and the per-call
      **chunk budget** (`chunk_budget`) used by the iterative
      summarizer;
    * the **chunk plan** — the conversation split into bounded,
      wire-valid groups (never between an assistant `tool_use` and
      its result) so a history larger than the summarizer's context
      can still be folded down.

  Oversized single messages are truncated for the summarization input
  only; the persisted row is untouched.
  """

  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Agents.PersistedAgent
  alias Nest.Messages.Assistant
  alias Nest.Messages.Compaction
  alias Nest.Messages.Message
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Tokens.Estimator
  alias Nest.Tokens.Reserve

  @summary_prefix "Summary of earlier conversation:\n\n"

  # Rough token cost of the per-call instruction/system preamble the
  # summarizer appends. Kept conservative; the estimator's safety
  # multiplier already absorbs most of the slack.
  @instruction_overhead 80

  @type t :: %__MODULE__{
          space_id: integer(),
          agent_id: integer(),
          agent_name: String.t(),
          slice: [Message.t()],
          orphan_count: non_neg_integer(),
          marker_index: non_neg_integer(),
          archived_count: non_neg_integer(),
          compaction_count: non_neg_integer(),
          system_text: String.t(),
          summary_budget: non_neg_integer(),
          chunk_budget: non_neg_integer(),
          chunks: [[Message.t()]],
          truncated?: boolean(),
          focus: String.t() | nil,
          agent_context_limit: integer(),
          summarizer_context_limit: integer()
        }

  defstruct [
    :space_id,
    :agent_id,
    :agent_name,
    :slice,
    :orphan_count,
    :marker_index,
    :archived_count,
    :compaction_count,
    :system_text,
    :summary_budget,
    :chunk_budget,
    :chunks,
    :truncated?,
    :focus,
    :agent_context_limit,
    :summarizer_context_limit
  ]

  @doc """
  Plan an offline compaction.

  `ctx` carries:

    * `:agent_context_limit` — the agent's resolved context window (the
      summary must fit here once stored).
    * `:summarizer_context_limit` — the summarization model's window.
    * `:system_prompt` — the re-rendered system prompt (or `nil`).
    * `:fallback_system_prompt` — the vocation's raw prompt, used when
      the rendered one leaves no summary headroom.
    * `:focus` — optional operator guidance.
    * `:max_calls` — the hard cap on summarization calls.
  """
  @spec plan(PersistedAgent.t(), [Message.t()], map()) :: {:ok, t()} | {:error, term()}
  def plan(%PersistedAgent{} = agent, full, ctx) do
    with {:ok, slice, orphans} <- active_prefix(agent, full),
         {:ok, budgets, conversation} <- budgets(slice, ctx),
         {:ok, chunks, truncated?} <- pack(conversation, budgets.chunk, ctx.max_calls) do
      {:ok, build_plan(agent, full, {slice, orphans}, {budgets, chunks, truncated?}, ctx)}
    end
  end

  defp budgets(slice, ctx) do
    with {:ok, system_text, summary_budget} <- choose_system(ctx),
         {:ok, chunk_budget} <- chunk_budget(ctx, system_text, summary_budget),
         {:ok, conversation} <- conversation(slice) do
      {:ok, %{system: system_text, summary: summary_budget, chunk: chunk_budget}, conversation}
    end
  end

  defp build_plan(agent, full, {slice, orphans}, {budgets, chunks, truncated?}, ctx) do
    %__MODULE__{
      space_id: agent.space_id,
      agent_id: agent.id,
      agent_name: agent.name,
      slice: slice,
      orphan_count: length(orphans),
      marker_index: max(agent.next_message_index, index(List.last(slice)) + 1),
      archived_count: length(slice),
      compaction_count: compaction_count(full, agent.last_compaction_index),
      system_text: budgets.system,
      summary_budget: budgets.summary,
      chunk_budget: budgets.chunk,
      chunks: chunks,
      truncated?: truncated?,
      focus: Map.get(ctx, :focus),
      agent_context_limit: ctx.agent_context_limit,
      summarizer_context_limit: ctx.summarizer_context_limit
    }
  end

  @doc """
  The new active rows the writer inserts after the marker.
  """
  @spec new_messages(t(), String.t(), DateTime.t()) :: [Message.t()]
  def new_messages(%__MODULE__{} = plan, summary, now) do
    marker = plan.marker_index

    [
      {:system,
       %System{
         index: marker + 1,
         parts: [%Part.Text{text: plan.system_text}],
         timestamp: now,
         api_logs: [],
         metadata: nil,
         tokens: nil
       }},
      {:user,
       %User{
         index: marker + 2,
         parts: [%Part.Text{text: @summary_prefix <> summary}],
         timestamp: now,
         api_logs: [],
         tokens: nil
       }}
    ]
  end

  @doc """
  The first message index the writer deletes (everything past the
  summarized prefix is orphaned by a crashed compaction).
  """
  @spec orphan_from(t()) :: non_neg_integer()
  def orphan_from(%__MODULE__{slice: slice}), do: index(List.last(slice)) + 1

  @doc """
  Approximate token count for a list of messages, using the same
  byte-based heuristic as the chunker (`size_message/1`). Never touches
  the tokenizer, so it is safe on the multi-megabyte histories this
  recovery tool exists to handle; the writer stores the result in the
  marker's `tokens_compacted` stats.
  """
  @spec estimate_tokens([Message.t()]) :: non_neg_integer()
  def estimate_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn message, acc -> acc + size_message(message) end)
  end

  # --- active slice / orphan detection ---

  defp active_prefix(%PersistedAgent{} = agent, full) do
    case active_rows(agent, full) do
      [] -> {:error, :nothing_to_compact}
      active -> split_prefix(agent, active)
    end
  end

  defp active_rows(%PersistedAgent{} = agent, full) do
    boundary = agent.last_compaction_index

    full
    |> Enum.filter(fn {_role, %{index: idx}} -> idx > boundary end)
    |> Enum.sort_by(&index/1)
  end

  defp split_prefix(%PersistedAgent{} = agent, active) do
    {within, beyond} =
      Enum.split_with(active, fn {_role, %{index: idx}} -> idx < agent.next_message_index end)

    case within do
      [] ->
        {:error, :active_prefix_gap}

      _ ->
        {slice, gap} = take_contiguous(within, agent.last_compaction_index + 1, [])
        classify(slice, gap ++ beyond)
    end
  end

  defp classify([], _orphans), do: {:error, :active_prefix_gap}

  defp classify(slice, orphans) do
    case conversation_length(slice) do
      0 -> {:error, :nothing_to_compact}
      _ -> {:ok, slice, orphans}
    end
  end

  defp take_contiguous([], _expected, acc), do: {Enum.reverse(acc), []}

  defp take_contiguous([row | rest], expected, acc) do
    if index(row) == expected do
      take_contiguous(rest, expected + 1, [row | acc])
    else
      {Enum.reverse(acc), [row | rest]}
    end
  end

  # The conversation is the active prefix without its durable leading
  # system prompt (the request re-prepends the freshly rendered one).
  defp conversation([{:system, _} | rest]), do: {:ok, rest}
  defp conversation([]), do: {:error, :nothing_to_compact}
  defp conversation(rest), do: {:ok, rest}

  defp conversation_length([{:system, _} | rest]), do: length(rest)
  defp conversation_length(slice), do: length(slice)

  # --- budgets ---

  defp choose_system(ctx) do
    limit = ctx.agent_context_limit
    reserve = Reserve.response_budget(limit)
    rendered = ctx.system_prompt

    rendered_candidate =
      if is_binary(rendered) and SystemPrompt.within_size_budget?(rendered, limit), do: rendered

    candidates = Enum.reject([rendered_candidate, ctx.fallback_system_prompt], &is_nil/1)

    Enum.find_value(candidates, {:error, :reserve_exhausted}, fn text ->
      budget = reserve - size_text(text) - size_text(@summary_prefix)
      if budget > 0, do: {:ok, text, budget}, else: nil
    end)
  end

  defp chunk_budget(ctx, system_text, summary_budget) do
    limit = ctx.summarizer_context_limit
    reserve = Reserve.response_budget(limit)

    budget = limit - reserve - size_text(system_text) - summary_budget - @instruction_overhead

    if budget > 0, do: {:ok, budget}, else: {:error, :reserve_exhausted}
  end

  # --- chunk packing ---

  defp pack(messages, budget, max_calls) do
    {chunks, current, _size, truncated?} =
      Enum.reduce(messages, {[], [], 0, false}, fn message, {chunks, current, size, tr} ->
        append_message(chunks, current, size, message, budget, tr)
      end)

    chunks = if current == [], do: chunks, else: [Enum.reverse(current) | chunks]
    chunks = Enum.reverse(chunks)

    cond do
      chunks == [] -> {:error, :nothing_to_compact}
      length(chunks) > max_calls -> {:error, {:too_many_calls, length(chunks), max_calls}}
      true -> {:ok, chunks, truncated?}
    end
  end

  defp append_message(chunks, current, size, message, budget, tr) do
    cost = size_message(message)

    cond do
      current == [] -> append_to_empty(chunks, message, cost, budget, tr)
      size + cost > budget -> flush_or_truncate(chunks, current, size, message, budget, tr)
      true -> {chunks, [message | current], size + cost, tr}
    end
  end

  defp append_to_empty(chunks, message, cost, budget, tr) when cost > budget do
    {message, cut?} = truncate(message, budget)
    {chunks, [message], size_message(message), tr or cut?}
  end

  defp append_to_empty(chunks, message, cost, _budget, tr), do: {chunks, [message], cost, tr}

  defp flush_or_truncate(chunks, current, size, message, budget, tr) do
    if safe_tail?(List.last(current)) do
      {[Enum.reverse(current) | chunks], [message], size_message(message), tr}
    else
      {message, cut?} = truncate(message, max(1, budget - size))
      {chunks, [message | current], size + size_message(message), tr or cut?}
    end
  end

  # A chunk may only end where the next request would still be a valid
  # wire sequence: after a user/tool message, or after an assistant
  # that requested no tools. Never between an assistant tool_use and
  # its tool result.
  defp safe_tail?({:assistant, %Assistant{parts: parts}}) do
    not Enum.any?(parts || [], &match?(%Part.ToolUse{}, &1))
  end

  defp safe_tail?({role, _}) when role in [:user, :tool, :system], do: true
  defp safe_tail?(_), do: true

  # --- truncation (summarization input only) ---

  @truncation_marker "\n...[truncated for offline compaction]"
  @max_shrink_passes 60

  defp truncate(message, budget) do
    if size_message(message) <= budget do
      {message, false}
    else
      {role, struct} = message
      parts = (struct.parts || []) |> Enum.reject(&match?(%Part.Thinking{}, &1))
      parts = shrink(parts, max(1, budget - 10), 0)
      {{role, %{struct | parts: parts}}, true}
    end
  end

  defp shrink(parts, _target, pass) when pass > @max_shrink_passes, do: parts

  defp shrink(parts, target, pass) do
    if size_parts(parts) <= target do
      parts
    else
      case largest_text_index(parts) do
        nil -> parts
        idx -> parts |> List.update_at(idx, &halve_text/1) |> shrink(target, pass + 1)
      end
    end
  end

  defp largest_text_index(parts) do
    parts
    |> Enum.with_index()
    |> Enum.reduce({nil, 0}, fn {part, idx}, {best, best_len} ->
      case text_of(part) do
        text when is_binary(text) and byte_size(text) > best_len -> {idx, byte_size(text)}
        _ -> {best, best_len}
      end
    end)
    |> elem(0)
  end

  defp text_of(%Part.Text{text: text}), do: text
  defp text_of(%Part.ToolResult{content: content}), do: content
  defp text_of(%Part.Refusal{refusal: refusal}), do: refusal
  defp text_of(_), do: nil

  defp halve_text(%Part.Text{text: text} = part), do: %{part | text: cut(text)}
  defp halve_text(%Part.ToolResult{content: content} = part), do: %{part | content: cut(content)}
  defp halve_text(%Part.Refusal{refusal: refusal} = part), do: %{part | refusal: cut(refusal)}
  defp halve_text(part), do: part

  defp cut(nil), do: @truncation_marker

  defp cut(text) do
    keep = max(0, div(String.length(text), 2))
    String.slice(text, 0, keep) <> @truncation_marker
  end

  # --- sizing ---

  # Byte-based sizing. The tokenizer NIF is pathologically slow on the
  # multi-megabyte tool results this recovery tool exists to handle, so
  # the planner never tokenizes: `estimate_bytes/1`'s bytes/4 heuristic
  # plus the estimator's own safety multiplier is conservative enough
  # for chunking and truncation decisions.
  defp size_message({_role, %{parts: parts}}), do: size_parts(parts)
  defp size_message(_), do: @instruction_overhead

  defp size_parts(nil), do: Estimator.estimate_bytes(0)

  defp size_parts(parts) when is_list(parts) do
    bytes = Enum.reduce(parts, 0, fn part, acc -> acc + part_bytes(part) end)
    Estimator.estimate_bytes(bytes)
  end

  defp part_bytes(%Part.Text{text: text}), do: bytes(text)
  defp part_bytes(%Part.Thinking{thinking: text, signature: sig}), do: bytes(text) + bytes(sig)
  defp part_bytes(%Part.ToolUse{name: name, arguments: args}), do: bytes(name) + args_bytes(args)

  defp part_bytes(%Part.ToolResult{content: content, arguments: args}),
    do: bytes(content) + args_bytes(args)

  defp part_bytes(%Part.Refusal{refusal: refusal}), do: bytes(refusal)
  defp part_bytes(_), do: 0

  defp bytes(nil), do: 0
  defp bytes(text) when is_binary(text), do: byte_size(text)
  defp bytes(_), do: 0

  defp args_bytes(nil), do: 0

  defp args_bytes(value) do
    byte_size(inspect(value))
  rescue
    _ -> 0
  end

  defp size_text(nil), do: 0
  defp size_text(text) when is_binary(text), do: Estimator.estimate_bytes(byte_size(text))
  defp size_text(_), do: 0

  # --- helpers ---

  defp compaction_count(full, boundary) do
    boundaries =
      Enum.count(full, fn
        {:compaction, %Compaction{index: idx}} -> idx <= boundary
        _ -> false
      end)

    boundaries + 1
  end

  defp index({_role, %{index: idx}}), do: idx
end
