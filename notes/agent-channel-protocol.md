# Agent Channel Protocol

## Overview

This document specifies the wire format for real-time communication between clients and agents via Phoenix channels.

## Core Principles

- **Everything is indexed**: Messages and deltas both have sequential indices
- **Forward as-received**: Server forwards streaming chunks immediately from the LLM
- **In-order delivery**: Out-of-order delivery is a bug
- **Validation at end**: Final message includes counts for integrity checking

## Channel Topic

`agent:{agent_id}` - e.g., `agent:clever-raven`

## Message Indexing

Messages are assigned sequential `messageIndex` values starting from 0:

- Even indexes (0, 2, 4...) - user messages
- Odd indexes (1, 3, 5...) - assistant messages

Deltas within a message are assigned sequential `deltaIndex` values starting from 0:

- `deltaIndex` 0, 1, 2, 3... within each assistant message
- Used for sync validation and integrity checking

The `messageCount` in status/sync responses indicates the number of complete (non-streaming) messages.

## Server to Client Events

### `init`

Sent automatically when client joins the channel.

Example:
```json
{
  "id": "clever-raven",
  "model": {"name": "Kimi-K2.5", "provider": "openrouter"},
  "vocation": {"id": 1, "name": "Developer"},
  "messageCount": 5,
  "status": "streaming",
  "streaming": {
    "messageIndex": 5,
    "lastDeltaIndex": 8,
    "content": "accumulated content...",
    "segments": [
      {"type": "text", "content": "Hello!"},
      {"type": "thinking", "content": "The user..."},
      {"type": "text", "content": " Here's"}
    ],
    "currentType": "text"
  }
}
```

Fields:
- `id` - Agent identifier (string)
- `model` - Model configuration (object)
- `vocation` - Vocation info or null (object)
- `messageCount` - Number of complete messages (integer)
- `status` - "idle" or "streaming" (string)
- `streaming` - Current streaming state if status is "streaming", otherwise null (object)

Streaming object fields:
- `messageIndex` - Index of message being streamed (integer)
- `lastDeltaIndex` - Last delta sent (integer)
- `content` - Accumulated content so far (string)
- `segments` - Array of content segments
- `currentType` - Current content type: "text", "thinking", "tool_call", or null

### `chat:delta`

Sent for each streaming chunk from the LLM.

Text example:
```json
{
  "messageIndex": 5,
  "deltaIndex": 3,
  "partType": "text",
  "content": "ello"
}
```

Tool call example:
```json
{
  "messageIndex": 5,
  "deltaIndex": 4,
  "partType": "tool_call",
  "toolCallId": "call_abc123",
  "toolCallName": "read_file",
  "content": "{\"path\": \"/tm"
}
```

Fields:
- `messageIndex` - Which message this delta belongs to (integer)
- `deltaIndex` - Sequential within message (0, 1, 2, ...) (integer)
- `partType` - Content type: "text", "thinking", or "tool_call" (string)
- `content` - The chunk content (string)
- `toolCallId` - Tool call identifier (only for partType: "tool_call") (string)
- `toolCallName` - Tool name (only for partType: "tool_call") (string)

Client behavior:
- Validate deltaIndex is the expected next value
- If deltaIndex doesn't match expected, request sync
- Accumulate content by messageIndex + partType (+ toolCallId for tool calls)
- Create new segment when partType changes

### `chat:message`

Sent when a message is complete.

Example:
```json
{
  "index": 5,
  "role": "assistant",
  "content": "Hello! Here's the file content: ...",
  "thinking": "The user wants to see a file...",
  "toolCalls": [
    {
      "id": "call_abc123",
      "name": "read_file",
      "arguments": {"path": "/tmp/foo.txt"}
    }
  ],
  "apiLogs": [],
  "graphemeCount": 156,
  "finalDeltaIndex": 12
}
```

Fields:
- `index` - Message index (integer)
- `role` - "assistant", "user", "system", or "tool" (string)
- `content` - Message content (string)
- `thinking` - Reasoning content (string or null)
- `toolCalls` - Array of tool calls (array or null)
- `toolResults` - Array of tool results (array or null, only for role: "tool")
- `apiLogs` - API call logs (array)
- `graphemeCount` - Total graphemes in content (integer)
- `finalDeltaIndex` - Last delta index (integer)

Validation: Client should verify it received all deltas (0 through finalDeltaIndex).

### `chat:error`

Sent when an error occurs.

Example:
```json
{
  "messageIndex": 5,
  "deltaIndex": 7,
  "content": "Error: model unavailable"
}
```

Fields:
- `messageIndex` - Message index where error occurred (integer)
- `deltaIndex` - Delta index where error occurred (integer)
- `content` - Error message (string)

Note: Errors replace the streaming state and use the message index that was being generated.

## Client to Server Messages

### `chat:message`

Send user message. Payload: `{content: string}`

### `chat:status`

Get current status. Payload: `{}`

### `chat:sync`

Request missing messages. Payload: `{lastIndex: number}`

Success reply:
```json
{
  "messages": [
    {"index": 4, "role": "user", "content": "..."},
    {"index": 5, "role": "assistant", "content": "..."}
  ],
  "streaming": {
    "messageIndex": 6,
    "lastDeltaIndex": 2,
    "content": "...",
    "segments": [],
    "currentType": "text"
  },
  "status": "streaming",
  "messageCount": 6
}
```

Fields:
- `messages` - Messages after lastIndex
- `streaming` - Current streaming state or null
- `status` - "idle" or "streaming"
- `messageCount` - Server's message count

Sync behavior:
- Returns all complete messages with index > lastIndex
- If lastIndex is -1, returns all complete messages
- Always includes current streaming state if status is "streaming"

## Content Types

Segment types track content boundaries when content types are interleaved:

```json
[
  {"type": "text", "content": "Hello! "},
  {"type": "thinking", "content": "The user wants..."},
  {"type": "text", "content": " Here's the answer"},
  {"type": "tool_call", "content": "{\"path\": \"/tmp/foo\"}"}
]
```

Types:
- `text` - Regular message text
- `thinking` - Reasoning/thinking content
- `tool_call` - Tool call JSON

Delta accumulation keys:
- Text: messageIndex + "text"
- Thinking: messageIndex + "thinking"
- Tool calls: messageIndex + "tool_call:" + toolCallId

When partType changes or toolCallId changes, start a new segment.

## Status Values

- `idle` - Agent ready, not streaming
- `streaming` - Agent generating response

The `streaming` field is only present when status is "streaming".
