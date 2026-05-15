# Nest - LLM Agent Flock System

## Overview

Nest is a Phoenix-based system for creating, managing, and executing "flocks" of AI agents. It supports complex workflow graphs where each node is an agent instance, with features for real-time introspection, forking, and log-based analysis.

## Core Concepts

### Agents vs Workflow Nodes

**Agent** - A template/configuration for an LLM-powered entity:
- Associated model (from provider config)
- System prompt / base personality
- Available tools
- Output schema (optional)
- Max tokens, temperature, etc.

**Workflow** - A directed graph of execution steps stored in the database:
- Nodes: Execution steps (each is an agent instance)
- Edges: Control flow between nodes
- Supports both sequential and parallel execution
- Editable via UI

**Node Instance** - A runtime execution of a workflow node:
- References an agent template
- May have step-specific overrides (prompt additions, input transformations)
- Configurable isolation (fresh context vs inherited context)
- Captures full execution logs

### Execution Modes

1. **Sequential Pipeline**: Output of node A → Input of node B
2. **Parallel Fork/Join**: Execute multiple branches simultaneously, wait for all
3. **Race**: Multiple agents attempt same task, first result wins
4. **Fan-out**: Broadcast to multiple agents, aggregate results

### Standalone Agents

Agents can also run independently of workflows:
- Interactive chat interface
- Full conversation history
- Can be forked/cloned from any point
- Not subject to workflow orchestration

## Configuration

### Provider Configuration (~/.config/nest/config.toml)

API keys and provider settings live outside the repository in user's home directory:

```toml
[providers.openai]
base_url = "https://api.openai.com/v1"
protocol = "openai"
api_key = "${OPENAI_API_KEY}"  # Can reference env vars

[providers.anthropic]
base_url = "https://api.anthropic.com/v1"
protocol = "anthropic"
api_key = "${ANTHROPIC_API_KEY}"

[providers.local]
base_url = "http://localhost:11434/v1"
protocol = "openai"
api_key = "ollama"  # Local models often don't need keys

[providers.custom]
base_url = "https://my-llm-server.internal/api"
protocol = "openai"
api_key_file = "~/.config/nest/secrets/custom.key"  # Or read from file

# Default model for new agents
[defaults]
provider = "openai"
model = "gpt-4o"
```

### Agent Templates

Stored in database with flexible text-based configuration:

```elixir
%{
  id: "uuid",
  name: "Code Reviewer",
  provider_id: "openai",
  model: "gpt-4o",
  system_prompt: "You are a meticulous code reviewer...",
  # Text-based config for LLM manipulation:
  config_text: """
  temperature: 0.7
  max_tokens: 4096
  
  tools:
    - name: search_code
      description: "Search the codebase"
    - name: run_tests
      description: "Run test suite"
  
  output_schema:
    type: object
    properties:
      issues:
        type: array
        items:
          type: object
          properties:
            severity: {enum: [critical, warning, info]}
            message: {type: string}
  """,
  # Parsed version for runtime use:
  config: %{
    temperature: 0.7,
    max_tokens: 4096,
    tools: [...],
    output_schema: ...
  }
}
```

## Database Schema

### agents

| Column | Type | Description |
|--------|------|-------------|
| id | uuid | Primary key |
| name | string | Display name |
| description | text | Human-readable description |
| provider_id | string | Reference to provider in config.toml |
| model | string | Model identifier (gpt-4o, claude-3-opus, etc.) |
| system_prompt | text | Base system prompt |
| config_text | text | YAML/TOML text configuration |
| config | jsonb | Parsed configuration object |
| created_at | datetime | Creation timestamp |
| updated_at | datetime | Last modification |

### workflows

| Column | Type | Description |
|--------|------|-------------|
| id | uuid | Primary key |
| name | string | Display name |
| description | text | Human-readable description |
| definition_text | text | JSON/YAML workflow graph definition |
| definition | jsonb | Parsed graph structure |
| status | enum | draft, active, archived |
| created_at | datetime | Creation timestamp |
| updated_at | datetime | Last modification |

**Workflow Definition Structure** (stored in definition_text/definition):

```json
{
  "nodes": [
    {
      "id": "node-1",
      "agent_id": "uuid-of-agent-template",
      "position": {"x": 100, "y": 200},
      "config": {
        "isolation": true,
        "input_transform": "{{input.code}}",
        "output_schema": {...}
      }
    }
  ],
  "edges": [
    {
      "id": "edge-1",
      "from": "node-1",
      "to": "node-2",
      "type": "sequential",
      "condition": null
    },
    {
      "id": "edge-2",
      "from": "node-2",
      "to": ["node-3", "node-4"],
      "type": "parallel",
      "join_mode": "all"
    }
  ],
  "inputs": [
    {"name": "code", "type": "string", "required": true}
  ],
  "outputs": [
    {"name": "review", "node": "node-3", "path": "content"}
  ]
}
```

### workflow_executions

| Column | Type | Description |
|--------|------|-------------|
| id | uuid | Primary key |
| workflow_id | uuid | Reference to workflow |
| status | enum | pending, running, paused, completed, failed, cancelled |
| parent_execution_id | uuid | For forks - reference to parent |
| forked_from_node_id | string | If forked, which node instance |
| started_at | datetime | Execution start |
| completed_at | datetime | Execution end (if finished) |
| log_file_path | string | Path to JSONL log file |
| inputs | jsonb | Initial inputs |
| outputs | jsonb | Final outputs |
| metadata | jsonb | Runtime metadata |

### node_instances

| Column | Type | Description |
|--------|------|-------------|
| id | uuid | Primary key |
| execution_id | uuid | Reference to workflow execution |
| node_id | string | Reference to node in workflow definition |
| agent_id | uuid | Reference to agent template (may differ from definition) |
| status | enum | pending, running, paused, completed, failed, skipped |
| started_at | datetime | Node execution start |
| completed_at | datetime | Node execution end |
| inputs | jsonb | Node inputs |
| outputs | jsonb | Node outputs |
| log_file_path | string | Path to node-specific log |
| parent_instance_id | uuid | For non-isolated nodes - inherit context |
| metadata | jsonb | Token usage, latency, etc. |

### standalone_sessions

For interactive agent conversations outside workflows:

| Column | Type | Description |
|--------|------|-------------|
| id | uuid | Primary key |
| agent_id | uuid | Reference to agent template |
| status | enum | active, paused, archived |
| forked_from_session_id | uuid | If forked from another session |
| forked_at_message_index | integer | Fork point in conversation |
| log_file_path | string | Path to JSONL log |
| created_at | datetime | Session start |
| last_activity_at | datetime | Last message timestamp |
| metadata | jsonb | Token usage totals, etc. |

## Log File Format (JSON Lines)

### Structure

Logs stored in `~/.local/share/nest/logs/`:

```
~/.local/share/nest/logs/
├── agents/
│   └── {agent_id}/
│       └── {session_id}-{timestamp}.jsonl
└── workflows/
    └── {execution_id}/
        ├── execution.jsonl
        └── nodes/
            └── {node_id}-{instance_id}.jsonl
```

### Log Entry Types

```json
// Session/Execution Start
{"type": "session_start", "timestamp": "2025-05-14T10:30:00Z", "id": "...", "agent_id": "...", "forked_from": "..."}

// Configuration
{"type": "config", "timestamp": "...", "provider": "...", "model": "...", "temperature": 0.7}

// User Message (standalone) or Node Input (workflow)
{"type": "user_message", "timestamp": "...", "index": 0, "content": "...", "metadata": {}}

// LLM Request
{"type": "llm_request", "timestamp": "...", "message_count": 5, "tokens_estimated": 1024}

// LLM Response (streaming)
{"type": "llm_chunk", "timestamp": "...", "index": 0, "content": "...", "is_thinking": false}
{"type": "llm_chunk", "timestamp": "...", "index": 1, "content": "..."}

// LLM Complete
{"type": "llm_response", "timestamp": "...", "full_content": "...", "finish_reason": "stop", "usage": {"input": 1024, "output": 256}}

// Tool Call
{"type": "tool_call", "timestamp": "...", "tool": "search_code", "arguments": {"query": "..."}, "call_id": "call-123"}

// Tool Result
{"type": "tool_result", "timestamp": "...", "call_id": "call-123", "result": "...", "duration_ms": 150}

// Assistant Message
{"type": "assistant_message", "timestamp": "...", "index": 1, "content": "...", "tool_calls": [...]}

// Node Start (workflow only)
{"type": "node_start", "timestamp": "...", "node_id": "...", "instance_id": "...", "inputs": {...}}

// Node Complete
{"type": "node_complete", "timestamp": "...", "node_id": "...", "outputs": {...}, "duration_ms": 5000}

// Parallel Branch Start
{"type": "parallel_start", "timestamp": "...", "branches": ["node-3", "node-4"], "join_mode": "all"}

// Parallel Branch Complete
{"type": "parallel_join", "timestamp": "...", "completed_branches": ["node-3", "node-4"], "results": {...}}

// Pause Event
{"type": "paused", "timestamp": "...", "reason": "user_request"}

// Resume Event
{"type": "resumed", "timestamp": "..."}

// Fork Event
{"type": "forked", "timestamp": "...", "new_session_id": "...", "at_index": 5}

// Session/Execution End
{"type": "session_end", "timestamp": "...", "reason": "completed|failed|cancelled", "total_tokens": {...}}
```

## Architecture

### Process Supervision Tree

```
Nest.Application
├── Nest.ConfigWatcher (GenServer)
│   └── Watches ~/.config/nest/config.toml for changes
├── Nest.AgentRegistry (Registry + DynamicSupervisor)
│   ├── Nest.AgentServer (per standalone session)
│   ├── Nest.WorkflowServer (per workflow execution)
│   │   └── Nest.NodeInstanceServer (per active node)
│   └── Nest.ToolServer (for active tool calls)
├── Nest.LogWriter (GenServer)
│   └── Batches and writes log entries to files
└── Nest.ChannelBroadcast (PubSub)
    └── Phoenix.PubSub for real-time updates
```

### Key GenServers

#### Nest.ConfigWatcher
- Loads and caches provider configuration from ~/.config/nest/config.toml
- Reloads on file changes
- Provides API key resolution (env vars, files, direct values)

#### Nest.AgentServer
- Manages a standalone agent session
- Maintains conversation history
- Handles user messages and LLM responses
- Supports pause/resume
- Emits log entries

#### Nest.WorkflowServer
- Orchestrates workflow execution
- Manages node lifecycle
- Handles parallel execution coordination
- Tracks execution state
- Emits workflow-level log entries

#### Nest.NodeInstanceServer
- Single-use server for node execution
- References agent configuration
- May inherit context from previous nodes
- Handles LLM calls and tool execution
- Emits node-specific log entries

### Phoenix Channels

```
user_socket:
  "agent:*" -> Nest.AgentChannel (standalone sessions)
  "workflow:*" -> Nest.WorkflowChannel (workflow executions)
  "lobby" -> Nest.LobbyChannel (broadcasts, presence)
```

#### AgentChannel Events

**Client → Server:**
- `send_message` - Send message to agent
- `pause` - Pause processing
- `resume` - Resume processing
- `fork` - Fork session at current point

**Server → Client:**
- `message_received` - New message in conversation
- `llm_chunk` - Streaming response chunk
- `tool_called` - Tool execution started
- `tool_completed` - Tool execution finished
- `status_changed` - Session status changed
- `fork_created` - New fork session created

#### WorkflowChannel Events

**Client → Server:**
- `start` - Start workflow execution
- `pause` - Pause execution
- `resume` - Resume execution
- `cancel` - Cancel execution
- `fork` - Fork execution at specific node

**Server → Client:**
- `execution_started` - Workflow execution began
- `node_started` - Node execution started
- `node_output` - Node produced output
- `node_completed` - Node finished
- `parallel_started` - Parallel branches began
- `parallel_joined` - Parallel branches completed
- `execution_completed` - Workflow finished
- `execution_failed` - Workflow error

## Tool System

### Built-in Tools

Initial set of Elixir functions as tools:

- `file_read` - Read file contents
- `file_write` - Write file contents
- `file_list` - List directory contents
- `http_request` - Make HTTP requests
- `search_logs` - Query log files
- `spawn_agent` - Create standalone agent (for sub-tasks)
- `run_workflow` - Execute another workflow

### Tool Definition

Tools defined as Elixir modules in `lib/nest/tools/builtin/`:

```elixir
defmodule Nest.Tools.FileRead do
  @moduledoc "Read file contents"
  
  use Nest.Tool,
    name: "file_read",
    description: "Read contents of a file",
    parameters: %{
      path: %{type: "string", required: true, description: "File path"},
      encoding: %{type: "string", enum: ["utf8", "base64"], default: "utf8"}
    }
  
  @impl Nest.Tool
  def execute(%{"path" => path} = args, context) do
    # context contains user_id, session_id, etc.
    case File.read(path) do
      {:ok, content} -> {:ok, %{content: content}}
      {:error, reason} -> {:error, "Failed to read: #{reason}"}
    end
  end
end
```

### Dynamic Tools (Future)

Tools loaded from disk at runtime:
- Stored in `~/.config/nest/tools/`
- Elixir modules compiled on startup
- Hot-reload capability
- Versioned and signed (optional)

## User Interface

### Pages

1. **Dashboard** - Overview of active sessions, recent workflows
2. **Agents** - Browse, create, edit agent templates
3. **Agent Studio** - Interactive chat with standalone agents
4. **Workflows** - Browse, create, edit workflow graphs
5. **Workflow Editor** - Visual graph editor for workflows
6. **Execution Viewer** - Real-time workflow execution monitoring
7. **Log Explorer** - Browse, filter, fork from log files
8. **Settings** - Configuration viewer (read-only, points to config file)

### Agent Studio (Interactive Mode)

- Chat interface with streaming responses
- Conversation history with expandable tool results
- Pause/Resume controls
- Fork button at any message
- Token usage display
- Export conversation to log file

### Workflow Editor

- Visual node-based graph editor
- Drag-and-drop node creation
- Node configuration panel (agent selection, isolation, transforms)
- Edge creation with type selection
- Parallel branch visualization
- Validation (detect cycles, disconnected nodes, etc.)
- Test execution with sample inputs

### Execution Viewer

- Real-time node status visualization
- Message stream per node
- Token usage and timing metrics
- Pause/Resume controls
- Fork execution at any node
- Scrollback through completed nodes

## Forking Mechanism

### Fork Creation

When user forks at a point:

1. Create new session/execution record
2. Set `parent_execution_id` and `forked_from_node_id`
3. Copy conversation history up to fork point
4. Start new server with copied state
5. Continue from fork point

### Log Replay

For viewing past executions:

1. Read log file
2. Replay events to reconstruct state
3. Allow branching at any event
4. Create fork from that point

## Development Phases

### Phase 1: Foundation
- [ ] Provider configuration system (config.toml)
- [ ] Database schema (agents, workflows, executions, sessions)
- [ ] Basic AgentServer for standalone sessions
- [ ] JSONL logging
- [ ] Phoenix Channel infrastructure
- [ ] Simple Agent Studio UI (chat interface)

### Phase 2: Workflows
- [ ] Workflow graph data model
- [ ] Visual workflow editor
- [ ] Sequential execution
- [ ] Workflow execution viewer
- [ ] Node isolation options

### Phase 3: Parallelism & Forking
- [ ] Parallel branch execution
- [ ] Join modes (all, any, race)
- [ ] Fork mechanism
- [ ] Log replay

### Phase 4: Tools & Advanced Features
- [ ] Built-in tool library
- [ ] Tool call UI
- [ ] Dynamic tool loading
- [ ] Schema validation
- [ ] Input/output transformations

### Phase 5: Analysis & Optimization
- [ ] Log analysis agents
- [ ] Workflow optimization suggestions
- [ ] Token usage analytics
- [ ] Performance metrics

## Open Questions

1. **Workflow Definition Format**: JSON is machine-friendly, but should we support YAML for human editing?

2. **Node Context Inheritance**: When a node inherits context, does it get full message history or just a summary?

3. **Parallel Execution Limits**: Should we limit concurrent nodes? Configurable per workflow?

4. **Log Retention**: Automatic cleanup? Archival? Configurable per agent/workflow?

5. **Access Control**: Multi-user support? Permissions on agents/workflows?

## Notes

- Keep configuration external to repository (no secrets in git)
- Text-based data where possible for LLM manipulation
- JSON Lines for logs enables easy streaming and grep/filter
- Fork/clone model enables safe experimentation
- Real-time introspection is a first-class feature, not an afterthought
