# Properly handle summary messages and `` content

## Background

The conversation UI gets weird after multiple compactions. The
`CollapsedHistory` pane shows the archived messages in the wrong
order, the active pane duplicates the user's message, and stray
`</think>\n\n` text leaks into the assistant's reply. These are
three independent bugs with a shared root cause: the compactor's
LLM call is treated as a transient side effect, and the messages
involved in the compaction process are not stored on the message
list.

The user established a hard rule:

> **Every message goes on the message list, in order. No
> exceptions, no excuses. That includes the compaction messages.**

This plan executes the work in one go, in this order: (A) remove
the dead renumbering code in the regenerator, (C-display) JS
`` rendering in the history and active panes, (C-strip)
`` strip on the compactor's LLM-call input, (B) the
compactor's pipeline change to store the suffix and the LLM's
response on the message list. Tests and verification alongside
each step.

---

## Part A — remove the dead renumbering code

`lib/nest/agents/agent/handlers/compaction_handler/regenerator.ex`
has three coupled edits:

**`split_compactor_output/1`** (lines 92-112): change return
type from `{original_system, summary_text, rest}` to
`{original_system, summary_text}`. The `rest = Enum.drop(rest, 1)`
line in the wrap_summary branch and the `rest` returned in the
fallback branches both go away.

**`regenerate_for_compaction/2`** (line 60): destructure as
`{_original_system, summary_text}` (drop the `rest` binding).

**`rebuild_for_compaction/4`** (lines 201-203): drop the
`renumbered_rest = Compaction.assign_indices(rest, marker_index + 3)`
line. Change
`new_messages = [fresh_system, summary_user | renumbered_rest]`
to `new_messages = [fresh_system, summary_user]`.

**Why is this safe**: in the new compactor
(`lib/nest/tokens/compactor.ex:209`) the LLM call returns
`[system, wrap_summary(head_summary)]` only. `rest` is `[]` on every
compaction, so the renumbering is a no-op. No test depends on the
3-tuple shape or on the echoed-message behavior. The user is firm:
no dead code "for backwards compatibility" — if a future LLM
echoes the conversation, the new code can re-introduce the
handling without dragging in the current `marker_index + 3`
assumption.

`Compaction.assign_indices/2` itself stays: it's used by
`CompactionLifecycle.apply/2` for the new list (live use) and
by Part B's new compactor pipeline change below (new live use).

Tests:
- `test/nest/agents/agent_regenerate_on_compaction_test.exs`:
  update tests that destructure the 3-tuple or assert on a
  3+-element `new_messages` — drop the `rest` binding, expect
  exactly 2 elements (fresh_system + summary_user).

---

## Part C-display — render `` content as thinking in the UI

**New file: `assets/js/utils/thinkTags.js`**

```js
/**
 * Splits a text on <think>/</think> markers.
 * Returns segments in original order:
 *   [{kind: "text" | "thinking", text}, ...]
 * Handles nested markers, orphan tags, and empty
 * think blocks. The split is recursive: a closing tag
 * without a matching opening tag is treated as an orphan
 * and routed to text (so the user doesn't see stray
 * `</think>` characters in the rendered text).
 */
export function splitThinkTags(text) {
  // ... recursive implementation
}

/**
 * Walks a message's parts. Returns:
 *   {
 *     thinking: string,  // concatenated thinking content
 *     textParts: Part[],  // text parts with <think> blocks
 *                         // split out
 *   }
 * For each Part.Text, splits on <think>/</think>. The
 * thinking text accumulates into `thinking`; the segments
 * around the think block remain as separate Part.Text
 * entries. Part.Thinking passes through (its content is
 * added to `thinking`). Other part types pass through
 * unchanged.
 */
export function splitThinkFromParts(parts) {
  // ... walk + split
}
```

**`assets/js/components/CollapsedHistory.jsx`** and
**`assets/js/pages/ChatPage.jsx`**: for assistant messages,
replace the current
`thinkingFromParts(parts)` + `textParts(parts)` pair with
`splitThinkFromParts(parts)`. The `thinking` field is passed to
`<ThinkingBlock>`, the `textParts` field is passed to
`<MessageContent>`. `ToolCalls`, `ToolResults`, and `ApiLogsBlock`
are unchanged.

Tests:
- New file: `assets/js/utils/thinkTags.test.js` covers
  `splitThinkTags` (no tags, single block, nested, orphan, multiple
  blocks, empty) and `splitThinkFromParts` (mixed with
  `Part.Thinking` and `Part.Text`).
- `assets/js/components/CollapsedHistory.test.jsx`: add a test for
  `<think>` in `Part.Text` rendering as a `ThinkingBlock`.
- `assets/js/pages/ChatPage.test.jsx`: same.

---

## Part C-strip — strip `` on the compactor's LLM call input

**New file: `lib/nest/messages/think_tags.ex`**

```elixir
defmodule Nest.Messages.ThinkTags do
  @moduledoc """
  Strips `<think>...</think>` content from text. Used by
  the compactor's LLM call to remove thinking from the
  messages sent to the compactor (which should see clean
  text, not the previous turn's verbatim thinking). The
  summary itself is stored intact — only the LLM call's
  input is stripped.
  """

  @opening_tag "<think>"
  @closing_tag "</think>"

  @spec strip(String.t()) :: String.t()
  def strip(text) do
    # Recursive: split on the first tag occurrence, drop
    # the inner content + tags, recurse on the prefix and
    # suffix. Empty tags are fine. Orphan closing tags
    # (no matching opening) are also dropped.
  end

  @spec strip_from_parts([Part.t()]) :: [Part.t()]
  def strip_from_parts(parts) do
    Enum.map(parts, fn
      %Part.Text{text: text} = part -> %{part | text: strip(text)}
      part -> part
    end)
  end
end
```

**`lib/nest/agents/agent/compaction.ex`** — the `messages`
parameter to the LLM call goes through
`ThinkTags.strip_from_parts/1` first. The `rendered_suffix` is the
LLM's own system message; it does not contain `<think>` (it's
text, not part content), so it does not need stripping.

```elixir
defp llm_call_for_compaction(client_config, rendered_suffix) do
  fn messages, _remaining_tokens, _optional_guidance ->
    cleaned_messages =
      Enum.map(messages, fn
        {:assistant, %Assistant{parts: parts} = msg} ->
          {:assistant, %{msg | parts: ThinkTags.strip_from_parts(parts)}}
        other -> other
      end)

    request = %Nest.LLM.RunRequest{
      messages: cleaned_messages ++ [rendered_suffix],
      tools: nil,
      tool_choice: :none,
      model: client_config.model,
      stream: true,
      metadata: %{}
    }
    ...
  end
end
```

Tests:
- New file: `test/nest/messages/think_tags_test.exs` covers
  `strip/1` and `strip_from_parts/1` (no tags, single block,
  nested, orphan, multiple blocks, empty, mixed with other part
  types).
- `test/nest/llm/openai_client_delta_test.exs:79-135`: the
  existing test asserts
  `assert {:text, "</think>\n\n"} in events`. After this change,
  the orphan closing tag is routed to thinking. Update to assert
  `{:thinking, "</think>\n\n"}` (or whatever the new event
  shape is — see the open question below).

---

## Part B — store every compaction message on the list

`lib/nest/agents/agent/compaction.ex` — after the LLM call
returns, append the suffix and the LLM's response to
`state.chat_state.messages` with fresh indices. Bump
`state.chat_state.next_message_index` past the new tail. Pass
the original LLM response (not the messages list) to the
regenerator.

```elixir
defp llm_call_for_compaction(client_config, rendered_suffix) do
  fn messages, _remaining_tokens, _optional_guidance ->
    # Part C-strip: <think> blocks stripped from old messages
    # before they're sent to the compactor LLM.
    cleaned_messages = strip_think_from_messages(messages)

    request = %Nest.LLM.RunRequest{
      messages: cleaned_messages ++ [rendered_suffix],
      ...
    }

    case client_config.client.run(request, opts) do
      {:ok, stream} ->
        case consume_quietly(stream, self()) do
          {:ok, response_messages} ->
            # Part B: append the suffix and the LLM's response
            # to the messages list BEFORE the regenerator runs.
            #
            # The LLM is asked to echo the conversation + a
            # summary; the response is the same shape (or a
            # subset — the new compactor's `rest` is empty).
            # We treat each response message as a real message
            # in the sequence.
            messages_with_response =
              append_suffix_and_response(
                cleaned_messages,
                rendered_suffix,
                response_messages
              )

            # Hand the regenerator the original LLM response
            # so its `split_compactor_output` logic can still
            # extract the wrap_summary for the
            # `summary_user` message.
            {messages_with_response, response_messages}
        end
    end
  end
end
```

The handler in `lib/nest/agents/agent/handlers/compaction_handler.ex`
that calls `Compactor.compact/3` needs the matching update:
take the second tuple element (the LLM response), not the first
(the full messages list with the suffix appended), and pass it to
`regenerate_for_compaction/2`.

The new `append_suffix_and_response/3` function:

```elixir
defp append_suffix_and_response(messages, rendered_suffix, response_messages) do
  base = messages ++ [rendered_suffix]
  # `response_messages` is the LLM's wire response shape
  # (an array of JSON-shaped messages). Each one needs to be
  # converted to a canonical tagged-tuple and given a fresh
  # index. The first message of the response is the
  # echoed system; the second is the wrap_summary; the rest
  # (if any) are echoes.
  with_indices = Compaction.assign_indices(
    Enum.map(response_messages, &message_to_canonical/1),
    length(base)
  )
  base ++ with_indices
end
```

`message_to_canonical/1` converts the LLM's wire response
(`%{"role" => "system", "content" => "..."}`) to the canonical
`{:system, %System{parts: [Part.Text{text: "..."}], ...}}`
shape. This is the inverse of `OpenAIClient.message_to_wire/1`'s
`{:system, _}` clause. Implement as a private helper in
`compaction.ex` (don't reach into the LLM client).

Update `state.chat_state.next_message_index` to one past the last
appended message via `GenServer.call` (the compactor's task is in
a different process; it needs to round-trip to the agent to
update the state).

### Index layout

Before compaction, the user's last message is at some index. The
compactor's LLM call input is `messages ++ [suffix]`. After the
LLM call:

- `state.chat_state.messages`: `[..., last_user_msg, suffix, ...response_messages]`
  - The suffix gets the next index (after last_user_msg).
  - The response messages get the next indices.
  - `state.chat_state.next_message_index` is bumped to one past
    the last response message.

The regenerator then takes the original `response_messages` (NOT
the messages list) as input. It uses the now-correct
`next_message_index` as the marker. `new_messages` is
`[fresh_system, summary_user]`. `CompactionLifecycle.apply/2`
renumbers the new list starting at `marker_index + 1`.

The marker lands at the right position (after the response
messages). The swap moves everything `<= marker_index` to
history. The new active list is `[fresh_system, summary_user,
continuation_tail]`.

Tests:
- `test/nest/agents/agent/compaction_test.exs` (or
  `test/nest/tokens/compactor_test.exs`): new test that asserts
  the compactor's task appends the suffix and the LLM's response
  to `state.chat_state.messages` BEFORE the regenerator runs, with
  `next_message_index` advanced past the new tail.
- `test/nest/agents/agent_regenerate_on_compaction_test.exs`:
  update tests that pin the marker at `next_message_index` to
  shift the expected marker by the number of appended messages
  (suffix + LLM response).
- `test/nest/agents/agent/handlers/compaction_handler_test.exs`
  (or similar): the integration test that exercises the full
  pipeline.

---

## Files to change (summary)

| File | Parts | Change |
|---|---|---|
| `lib/nest/agents/agent/handlers/compaction_handler/regenerator.ex` | A | Drop `rest` from `split_compactor_output`, drop `renumbered_rest` from `rebuild_for_compaction`. |
| `assets/js/utils/thinkTags.js` (new) | C-display | `splitThinkTags`, `splitThinkFromParts`. |
| `assets/js/components/CollapsedHistory.jsx` | C-display | Use `splitThinkFromParts` for assistant messages. |
| `assets/js/pages/ChatPage.jsx` | C-display | Same. |
| `lib/nest/messages/think_tags.ex` (new) | C-strip | `strip/1`, `strip_from_parts/1`. |
| `lib/nest/agents/agent/compaction.ex` | B + C-strip | Strip `<think>` from old messages; append suffix + LLM response to `state.chat_state.messages`; bump `next_message_index`; pass the original LLM response (not the messages list) to the regenerator. |
| `lib/nest/agents/agent/handlers/compaction_handler.ex` | B | Update the caller of `Compactor.compact/3` to take the original LLM response (second tuple element) and pass it to the regenerator. |

## Files to add (tests)

| File | Part | What |
|---|---|---|
| `assets/js/utils/thinkTags.test.js` | C-display | Unit tests for `splitThinkTags`, `splitThinkFromParts`. |
| `test/nest/messages/think_tags_test.exs` | C-strip | Unit tests for `strip/1`, `strip_from_parts/1`. |
| `test/nest/agents/agent/compaction_test.exs` (or `test/nest/tokens/compactor_test.exs`) | B | Asserts the compactor's task appends the suffix and the LLM's response to `state.chat_state.messages` and bumps `next_message_index`. |

## Files to update (tests)

| File | Part | Change |
|---|---|---|
| `test/nest/agents/agent_regenerate_on_compaction_test.exs` | A + B | Drop the 3-tuple destructure; expect 2 elements in `new_messages`; shift expected `marker_index` by the number of appended messages. |
| `test/nest/agents/agent/handlers/compaction_handler_test.exs` | B | Update integration test to account for the appended suffix and LLM response. |
| `test/nest/llm/openai_client_delta_test.exs` | C-strip | The existing "a delta with both content and tool_calls" test asserts `{:text, "</think>\n\n"}`. Update to assert the orphan closing tag is routed to thinking. |
| `assets/js/components/CollapsedHistory.test.jsx` | C-display | Add a test for `<think>` in `Part.Text` rendering as a `ThinkingBlock`. |
| `assets/js/pages/ChatPage.test.jsx` | C-display | Same. |

## Open question (Part C-strip)

Should orphan closing tags (no matching opening) be routed to the
thinking channel (as the opening-less thinking content) or
silently dropped?

- Route to thinking: matches the user's principle ("with any
  `<think>` blocks intact"). Stray `</think>` in the response
  shows up under the thinking toggle.
- Silently dropped: cleaner visual; stray `</think>` text is
  invisible in the UI.

The default in this plan: route to thinking. The alternative is
a one-line change in `strip/1` if the user prefers the visual
cleanliness.

## Verification

- `mix precommit` clean: credo, format, 0 warnings, 0 failures,
  ≥90% branch coverage, under 5s.
- `mix test --no-deps-check` clean.
- `cd assets && pnpm test` (Vitest) clean.
- `cd assets && pnpm exec biome check` clean.
- Manual smoke test: fresh agent, run enough turns to force 2-3
  compactions, confirm the message list shows every message in
  order (suffix, LLM response, marker, fresh_system, summary,
  user's message, all with `<think>` content rendered as
  collapsed thinking blocks in both the history pane and the
  active pane).

## Execution order

1. Part A (smallest blast radius — pure code removal in one file)
2. Part C-display (JS-only — display utility + render update)
3. Part C-strip (Elixir-only — utility + compactor input transform)
4. Part B (the compactor's pipeline change — append suffix +
   LLM response)

Tests and verification alongside each step. No part is dropped
or deferred.

## What is NOT changing

- The Anthropic client (has first-class thinking support).
- The mock client (script-based; `<think>` is irrelevant).
- The streaming logic (the `<think>` content still comes
  through as `:text` events; it's parsed at display time and
  stripped at the compactor's LLM input).
- The wire format for normal agent LLM calls (the model gets
  the full content with `<think>` markers, which is what the
  user said it expects).
- The user's message in the chat pipeline (still in
  `pending_user_message`, not in the old list; not duplicated).
- The `Compaction.assign_indices/2` function (still used by
  `CompactionLifecycle.apply/2` and now also by Part B's new
  compactor pipeline).
- The conversation sequence: it stays monotonic. Every message
  — including the suffix and the LLM's response — lands in the
  right order at the right index, and no compaction message is
  filtered out.
