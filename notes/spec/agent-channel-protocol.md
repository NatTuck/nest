# Agent Channel Protocol Specification

This document specifies the wire format for real-time communication between the Nest browser client and the Phoenix backend via `NestWeb.AgentChannel`.

## Core Principles

- **Indexed Conversation**: Messages are assigned sequential `index` values.
- **PubSub-Driven**: The channel acts as a gateway; the `Agent` GenServer broadcasts events to a PubSub topic, which the channel then pushes to all connected clients.
- **State Mirroring**: The backend maintains a `partial` accumulator (mirror) to allow clients to reconstruct the in-flight response during reconnection or multi-client synchronization.
- **Strict Flow Control**: The server rejects incoming messages while the agent is "Busy" (streaming or executing tools) or "Frozen" (compaction/overflow/model missing).

## Channel Topic

`agent:{agent_name}` — e.g., `agent:clever-raven`

---

## Server to Client Events

### `init`
Sent automatically upon a successful channel join.

**Payload Example:**
```json
{
  "name": "Code Reviewer",
  "model": {"name": "gpt-4o", "provider": "openai"},
  "vocation": {"id": "...", "name": "Developer"},
  "messageCount": 12,
  "history": [
    {"role": "system", "content": "...", "index": 0},
    {"role": "user", "content": "...", "index": 1}
  ],
  "status": "idle",
  "partial": {
    "index": 13,
    "text": "Hello",
    "thinking": "I should greet the user",
    "thinking_signature": "sig_abc123"
  },
  "modes": ["plan", "build"],
  "defaultMode": "plan",
  "currentMode": "plan",
  "contextLimit": 128000,
  "contextLimitSource": "config",
  "usage": {"input_tokens": 1024, "output_tokens": 256}
}
```

### `chat:delta`
Sent for every streaming chunk received from the LLM.

**Payload Example:**
```json
{
  "index": 13,
  "content": " world",
  "charsStart": 5,
  "charsEnd": 11,
  "partType": "text",
  "toolCallId": null,
  "toolCallName": null,
  "toolCallBlockIndex": null
}
```
*   `partType`: Can be `text`, `thinking`, `tool_use_start`, or `tool_use_delta`.
*   `charsStart`/`charsEnd`: Absolute character offsets within the accumulated message.

### `chat:message`
Sent when a message (user, assistant, tool, or system) is finalized and appended to the conversation.

**Payload Shape:**
The payload is the result of `Nest.Messages.Message.to_json/1`.
- **Assistant messages** include `content`, `thinking`, `toolCalls`, and `apiLogs`.
- **Tool messages** include `toolResults`.
- **User/System messages** include `content`.
- All include `index`, `role`, and optionally `tokens`.

### `chat:status`
Broadcast whenever the agent's operational status or metadata changes.

**Payload Example:**
```json
{
  "name": "Code Reviewer",
  "model": {"name": "gpt-4o", "provider": "openai"},
  "messageCount": 14,
  "status": "streaming",
  "partial": { ... },
  "contextLimit": 128000,
  "contextLimitSource": "config",
  "currentMode": "build",
  "usage": {"input_tokens": 2048, "output_tokens": 512}
}
```

### `chat:error`
Sent when a request fails or the agent encounters a critical error.

**Payload Example:**
```json
{
  "index": 13,
  "content": "Error: API rate limit exceeded"
}
```

### `chat:compaction`
Sent when the conversation has been automatically compacted to fit the context window.

**Payload Example:**
```json
{
  "marker": {"index": 5, "role": "compaction", "content": "Messages archived..."},
  "archived": [ ... ]
}
```

### `chat:compaction-loop`
Sent when a compaction loop is detected (repeated compaction without progress).

**Payload Example:**
```json
{
  "message": "Compaction loop detected. Please adjust your prompt or model."
}
```

### `chat:notification`
General purpose notifications (e.g., system alerts).

---

## Client to Server Messages

### `chat:message`
Sends a user message to the agent.
**Payload:** `{"content": "Hello!", "mode": "build"}` (mode is optional).
**Responses:**
- `{:ok, %{}}`: Message accepted.
- `{:error, %{"reason" => "agent_busy"}}`: Agent is currently streaming or executing tools.
- `{:error, %{"reason" => "agent_status_..."}}`: Agent is frozen (e.g., `agent_status_context_overflow`).

### `change_model`
Updates the agent's model configuration.
**Payload:** `{"model": {"name": "claude-3-opus", "provider": "anthropic"}}`

### `chat:stop`
Signals the agent to immediately terminate the current LLM request or tool execution.
**Payload:** `{}`

### `chat:sync`
Requests missing messages after a reconnection.
**Payload:** `{"lastIndex": 10}`
**Response:**
```json
{
  "messages": [ ... ],
  "partial": { ... },
  "status": "idle",
  "messageCount": 15
}
```

### `chat:retry-compaction`
Manual trigger to retry a failed compaction.
**Payload:** `{}`

### `chat:loop-detected-ok`
Acknowledges a compaction loop and resets agent status to `:idle`.
**Payload:** `{}`

---

## Status Values

| Status | Meaning | UI Behavior |
|---|---|---|
| `idle` | Ready for input | Input enabled |
| `streaming` | LLM is generating text | Input disabled, show typing indicator |
| `executing_tools` | Tools are running | Input disabled, show tool activity |
| `compacting` | Reducing context size | Input disabled, show compaction spinner |
| `compaction_failed` | Compaction error | Input disabled, show Retry button |
| `compaction_loop_detected` | Infinite compaction loop | Input disabled, show OK button |
| `context_overflow` | Prompt too large for model | Input disabled, show error banner |
| `model_missing` | Configured model unavailable | Input disabled, show model picker |
