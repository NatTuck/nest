# Agent Channel Protocol

## Channel Topic

`agent:{agent_id}` - e.g., `agent:clever-raven`

## Join Sequence

- Client joins.
- Server responds with status message.
- If client doesn't have all messages through lastCompleteIndex, it requests a
sync.

### Status Message

```json
{
  "id": "clever-raven",
  "model": {"name": "Kimi-K2.5", "provider": "openrouter"},
  "lastCompleteIndex": 3,
  "status": "idle"
}
```

### Status Values

- `"idle"` - Agent is ready, not actively streaming
- `"streaming"` - Agent is generating a response (streaming deltas)

The status reflects the agent's current activity state. When status is `"streaming"`, the client can expect `chat:delta` events followed by a `chat:message`.

## Message Indexing

Messages are assigned sequential indexes starting from 0, incremented for each message in the conversation regardless of role. Indexes are assigned by the server:

- Even indexes (0, 2, 4...) - user messages
- Odd indexes (1, 3, 5...) - assistant messages

The `lastCompleteIndex` in status/sync responses indicates the highest index of a complete (non-partial) message the server has.

## When the LLM Does Stuff

### `chat:delta` (Broadcast)

**When:** Streaming content from LLM, sent multiple times per message

**Purpose:** Deliver incremental content updates during streaming

**Example:**

```json
{
  "index": 4,
  "content": "llo",
  "charsStart": 2,
  "charsEnd": 5
}
```

When the client gets this:

- If it doesn't have complete messages through 3 and the current partial message
through character 2 it requests a sync.
- If it does have everything, it updates the current partial message by
appending this new content.

### `chat:message` (Broadcast)

**When:** Complete message finished streaming

**Purpose:** Confirm message completion with full content

```json
{
  "index": 4,
  "role": "assistant",
  "content": "Hello! How can I help you today?"
}
```

**Roles:**
- `"user"` - Message sent by the user  
- `"assistant"` - Message from the LLM

When the client gets this:

- If it doesn't have previous messages, sync.
- It adds this to the message list if it's the next one, dropping the partial message if the indexes
  match.

### `chat:error` (Broadcast)

**When:** LLM request fails or other processing error

**Purpose:** Report errors that occur during message processing

**Example:**

```json
{
  "index": 4,
  "content": "Error: model unavailable"
}
```

**Note:** Errors are not part of the message sequence. They replace the partial message that was being streamed and use the index that was being generated. Clients should display them differently from assistant messages but they don't affect `lastCompleteIndex`.

### Partial Message Semantics

A partial message exists **only when status is `"streaming"`** and represents the in-progress message being generated. It contains:

- `"index"` - The message index being generated
- `"content"` - Content received so far
- Additional fields like `charsSent` indicating how many characters have been streamed

The partial is cleared when:
- The matching `chat:message` is received (same index)
- A sync response includes a partial with a different index (new streaming started)
- The client explicitly clears it on error

## When the User Does Stuff

### `chat:message`

**Purpose:** Send user message to agent

**Payload:**

```javascript
{ content: "Hello, agent!" }
```

**Success Reply:** `{:ok, %{}}` - Triggers streaming response via `chat:delta` and `chat:message` events

**Error Reply:** Errors use the format `{:error, %{"reason" => reason}}`

### `chat:status`

**Purpose:** Get current agent status (used for rejoin verification)

**Payload:** `{}` (empty)

**Success Reply:**

Exactly the same as the reply to a join:

```json
{
  "id": "clever-raven",
  "model": {"name": "Kimi-K2.5", "provider": "openrouter"},
  "lastCompleteIndex": 3,
  "status": "idle"
}
```

Status is either "idle" or "streaming".

**Error Reply:** Errors use the format `{:error, %{"reason" => reason}}`

---

### `chat:sync`

**Purpose:** Request missing messages after or when confused.

**Payload:**

```javascript
{ lastIndex: 3 }  // Last message index in the client has with no previous gaps
                  // in the message list
```

**Success Reply:**

```elixir
%{
  "messages" => [%{index: 4, role: "assistant", content: "..."}],  # Missing messages only, including both user and assistant messages.
  "partial" => "Hello, wor" | nil,  # Current partial message if streaming
  "status" => "streaming", # Status is "idle" or "streaming"
  "lastCompleteIndex" => last_complete_index  # Server's last complete index
}
```

**Sync Behavior:**

- Server returns **all messages it has with index > lastIndex**, up to its current `lastCompleteIndex`
- If `lastIndex` is -1, server returns all complete messages it has
- If `lastIndex` is higher than server's `lastCompleteIndex`, server returns empty messages list
- Always includes the current status and any current partial message (if streaming)

**Error Reply:** Errors use the format `{:error, %{"reason" => reason}}`
