# Vocation Design and Implementation Plan

## Overview

Vocations are **reusable agent blueprints** that define an agent's role, available tools, and sandbox capabilities. They enable multi-step workflows where each agent has a distinct job with specific permissions and constraints.

### Key Concepts

- **Vocation**: A template defining an agent's capabilities, tools, and modes
- **Mode**: A set of sandbox permissions that can change per-turn (e.g., "plan" vs "build")
- **Agent**: A runtime instance spawned from a vocation with a specific mode and workspace
- **Tool**: An executable action available to agents (shell commands via bwrap sandbox)

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Tool Implementation | Templates with Mustache interpolation | Simple, fast to implement, extensible to modules later |
| Tool Location | Elixir code | Type-safe, version controlled, can be tested |
| Vocation Location | Database | Users can create/edit vocations via UI |
| Mode Location | Embedded in vocation (JSONB) | Tightly coupled to vocation, simpler schema |
| Sandbox | bwrap + erlexec | Lightweight, fast, proper Linux namespace isolation |
| Filesystem Access | Bind mounts | Direct host filesystem access with RO/RW controls |
| /tmp Handling | Per-agent subdirectory | Isolated temp space, cleaned on termination |
| Workspace | Persistent after agent exit | For review, debugging, and workflow step handoff |
| Tool Calling | Standard LangChainEx tool calling | Familiar pattern, structured function calling |
| Capabilities | Per-mode, no base/inheritance | Explicit permissions at runtime |

---

## Data Model

### Vocation Schema

```elixir
%Vocation{
  id: UUID,
  name: String,              # e.g., "Code Reviewer"
  description: Text,       # Human-readable purpose
  system_prompt: Text,     # Base prompt for LLM
  
  # Available tools for this vocation (references Tool definitions in code)
  tools: [String],          # e.g., ["read_file", "shell_cmd", "task_complete"]
  
  # Modes define sandbox capabilities
  modes: %{                # JSONB in database
    plan: %{
      caps: %{
        net: false,         # No network access
        fs: %{
          read: ["/"],      # Can read entire host (RO)
          write: []         # No write access
        }
      }
    },
    build: %{
      caps: %{
        net: true,          # Network allowed
        fs: %{
          read: ["/"],
          write: [:workspace]  # Can write to workspace only
        }
      }
    }
  }
}
```

### Agent Schema (Extensions)

```elixir
%Agent{
  id: UUID,
  vocation_id: UUID,         # References Vocation
  current_mode: String,     # e.g., "build"
  workspace_path: String,   # Absolute path to workspace directory
  
  # Existing fields:
  # model, messages, next_message_index, partial_message, status
}
```

### Tool Definition (Code)

```elixir
%Tool{
  id: Atom,                 # e.g., :read_file
  name: String,             # Display name
  description: String,      # For LLM/tool selection UI
  template: String,         # Mustache template for shell command
  parameters: [             # For LangChainEx function schema
    %{name: "path", type: "string", required: true}
  ]
}
```

---

## Tool Definitions (MVP)

```elixir
defmodule Nest.Tools do
  @tools %{
    read_file: %{
      name: "Read File",
      description: "Read contents of a file",
      template: "cat {{path}}",
      parameters: [
        %{name: "path", type: "string", required: true, description: "Path to file"}
      ]
    },
    
    write_file: %{
      name: "Write File",
      description: "Write content to a file (overwrites)",
      template: "cat > {{path}} << 'EOF'\n{{content}}\nEOF",
      parameters: [
        %{name: "path", type: "string", required: true},
        %{name: "content", type: "string", required: true}
      ]
    },
    
    append_file: %{
      name: "Append to File",
      description: "Append content to end of file",
      template: "printf '%s' {{content}} >> {{path}}",
      parameters: [
        %{name: "path", type: "string", required: true},
        %{name: "content", type: "string", required: true}
      ]
    },
    
    shell_cmd: %{
      name: "Run Shell Command",
      description: "Execute arbitrary shell command",
      template: "{{command}}",
      parameters: [
        %{name: "command", type: "string", required: true, description: "Shell command to execute"}
      ]
    },
    
    task_complete: %{
      name: "Task Complete",
      description: "Signal that the current task is complete",
      template: "echo 'TASK_COMPLETE:{{message}}'",
      parameters: [
        %{name: "message", type: "string", required: false, description: "Completion message"}
      ]
    }
  }
  
  def list_tools, do: @tools
  def get_tool(id), do: Map.get(@tools, String.to_atom(id))
end
```

---

## Sandbox Configuration

### bwrap Arguments Builder

```elixir
def build_bwrap_args(caps, workspace_path) do
  base = [
    "--unshare-all",
    "--die-with-parent",
    "--new-session",
    "--proc", "/proc",
    "--dev", "/dev",
    "--tmpfs", "/tmp" # This is wrong
  ]
  
  # Network isolation
  args = if caps.net do
    base
  else
    ["--unshare-net" | base]
  end
  
  # Read-only mounts
  args = Enum.reduce(caps.fs.read, args, fn path, acc ->
    resolved = resolve_path(path, workspace_path)
    ["--ro-bind", resolved, resolved | acc]
  end)
  
  # Read-write mounts (including workspace symbol)
  args = Enum.reduce(caps.fs.write, args, fn path, acc ->
    resolved = resolve_path(path, workspace_path)
    ["--bind", resolved, resolved | acc]
  end)
  
  # Set working directory
  ["--chdir", workspace_path | args]
end

defp resolve_path(:workspace, workspace), do: workspace
defp resolve_path(path, _), do: path
```

### Special /tmp Handling

```elixir
def create_tmp_space(agent_id) do
  tmp_path = "/tmp/nest-#{System.pid()}/agent-#{agent_id}"
  File.mkdir_p!(tmp_path)
  tmp_path
end

def cleanup_tmp(agent_id) do
  tmp_path = "/tmp/nest-#{System.pid()}/agent-#{agent_id}"
  File.rm_rf(tmp_path)
end
```

---

## Execution Flow

### 1. Tool Invocation

```
1. LLM sends tool call via LangChainEx
2. Agent validates tool is in vocation.tools list
3. Agent gets current mode's caps
4. Tool template rendered with Mustache interpolation
5. Sandbox args built from caps + workspace
6. Command executed via erlexec with bwrap
7. Output streamed via PubSub to frontend
8. Tool result added to message history
```

### 2. Template Rendering

```elixir
def render_template(tool_id, args) do
  tool = Tools.get_tool(tool_id)
  
  # Validate required params
  required = Enum.filter(tool.parameters, & &1.required)
  missing = Enum.filter(required, fn p -> is_nil(args[p.name]) end)
  
  if missing != [] do
    {:error, "Missing required parameters: #{inspect(Enum.map(missing, & &1.name))}"}
  else
    # Simple Mustache replacement
    rendered = Enum.reduce(args, tool.template, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
    
    {:ok, rendered}
  end
end
```

### 3. Sandbox Execution

```elixir
def execute(command, workspace_path, caps) do
  bwrap_args = build_bwrap_args(caps, workspace_path)
  full_command = "bwrap #{Enum.join(bwrap_args, " ")} bash -c '#{escape_shell(command)}'"
  
  # Use erlexec for process management
  {:ok, pid, os_pid} = :exec.run_link(
    to_charlist(full_command),
    [
      :monitor,
      :stdout,
      :stderr,
      {:kill_timeout, 5000}  # 5 second grace period
    ]
  )
  
  # Return pid for streaming output
  {:ok, pid}
end
```

---

## Agent Lifecycle

### Spawn

```elixir
spawn_agent(%{
  vocation_id: vocation_id,
  mode: "build",  # or "plan", etc.
  workspace_path: "/home/nat/nest/workspaces/#{uuid}"
}) do
  # 1. Create workspace directory
  File.mkdir_p!(workspace_path)
  
  # 2. Create tmp space
  create_tmp_space(agent_id)
  
  # 3. Load vocation
  vocation = Vocations.get_vocation!(vocation_id)
  
  # 4. Start Agent GenServer with vocation context
  Agent.start_link(%{
    id: agent_id,
    vocation: vocation,
    current_mode: mode,
    workspace_path: workspace_path,
    # ... existing fields
  })
end
```

### Termination

```elixir
def terminate(_reason, state) do
  # Cleanup /tmp
  cleanup_tmp(state.id)
  
  # Note: workspace is preserved for review/debugging
  :ok
end
```

### Mode Switching

```elixir
def set_mode(agent_pid, mode_name) do
  GenServer.cast(agent_pid, {:set_mode, mode_name})
end

# In Agent GenServer
handle_cast({:set_mode, mode_name}, state) do
  # Validate mode exists in vocation
  if Map.has_key?(state.vocation.modes, mode_name) do
    {:noreply, %{state | current_mode: mode_name}}
  else
    {:noreply, state}  # Or error
  end
end
```

---

## Integration with LangChainEx

### Custom Tool Definition

```elixir
defp build_langchain_tools(vocation) do
  Enum.map(vocation.tools, fn tool_id ->
    tool = Tools.get_tool(tool_id)
    
    LangChain.Function.new!(%{
      name: to_string(tool_id),
      description: tool.description,
      parameters_schema: %{
        type: "object",
        properties: build_param_schema(tool.parameters),
        required: get_required_params(tool.parameters)
      },
      function: fn args, %{agent: agent} ->
        execute_tool(agent, tool_id, args)
      end
    })
  end)
end
```

### Tool Execution Handler

```elixir
defp execute_tool(agent, tool_id, args) do
  # Get current mode capabilities
  mode = agent.current_mode
  caps = agent.vocation.modes[mode].caps
  
  # Render command from template
  {:ok, command} = Tools.render_template(tool_id, args)
  
  # Execute in sandbox
  {:ok, exec_pid} = Sandbox.Executor.execute(
    command,
    agent.workspace_path,
    caps
  )
  
  # Stream output (handled via erlexex port messages)
  # Return initial response
  %{status: "executing", tool: tool_id}
end
```

---

## Example Vocation: Code Grader

```elixir
%Vocation{
  name: "Code Grader",
  description: "Grades student programming assignments",
  system_prompt: """
  You are a code grader for a college programming course.
  Your job is to review student submissions and provide feedback.
  
  In PLAN mode: Analyze the submission and create a grading rubric.
  In BUILD mode: Write detailed feedback files to the workspace.
  """,
  
  tools: [
    "read_file",
    "write_file", 
    "shell_cmd",
    "task_complete"
  ],
  
  modes: %{
    plan: %{
      caps: %{
        net: false,
        fs: %{
          read: ["/"],
          write: []  # Can read student code but not modify
        }
      }
    },
    build: %{
      caps: %{
        net: true,   # Can look up language docs
        fs: %{
          read: ["/"],
          write: [:workspace]  # Can write feedback files
        }
      }
    }
  }
}
```

---

## Database Migration

```elixir
# priv/repo/migrations/20250128000000_create_vocations.exs
defmodule Nest.Repo.Migrations.CreateVocations do
  use Ecto.Migration

  def change do
    create table(:vocations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :system_prompt, :text, null: false
      add :tools, {:array, :string}, null: false, default: []
      add :modes, :map, null: false, default: %{}

      timestamps()
    end

    create table(:agents, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :vocation_id, references(:vocations, type: :uuid, on_delete: :nilify_all)
      add :current_mode, :string
      add :workspace_path, :string
      
      # ... existing agent fields
    end
  end
end
```

---

## Dependencies

Add to `mix.exs`:

```elixir
defp deps do
  [
    # Existing deps...
    
    # For sandboxed execution
    {:erlexec, "~> 2.0"},
    
    # For template rendering
    {:mustache, "~> 0.5"}
  ]
end
```

---

## Testing Strategy

### Unit Tests

1. **Tool Template Rendering**
   - Parameter substitution
   - Missing required params
   - Shell escaping

2. **Sandbox Arg Building**
   - Read-only mounts
   - Read-write mounts
   - :workspace symbol resolution
   - Network unshare flag

3. **Mode Switching**
   - Valid mode change
   - Invalid mode rejection
   - Capability retrieval

4. **Vocation CRUD**
   - Create with valid modes
   - Update tools list
   - Delete (and agent nullification)

### Integration Tests

1. **Tool Execution**
   - Read file in RO mode (success)
   - Write file in RO mode (error)
   - Write file in RW mode (success)
   - Network blocked when caps.net=false

2. **Agent Lifecycle**
   - Spawn with vocation
   - Workspace creation
   - /tmp creation and cleanup
   - Workspace persistence after exit

3. **Mode Transitions**
   - Plan mode: read-only
   - Switch to build: can write
   - Tool execution respects mode

### Manual Testing

1. Full workflow:
   - Create vocation with plan/build modes
   - Spawn agent in plan mode
   - Agent reads files, tries to write (blocked)
   - Switch to build mode
   - Agent writes files successfully
   - Terminate agent
   - Verify workspace preserved
   - Verify /tmp cleaned

---

## Implementation Phases

### Phase 1: Foundation (Day 1)
- [ ] Database migration for vocations and agent updates
- [ ] Vocation schema and changeset
- [ ] Vocations context (CRUD)

### Phase 2: Tools (Day 2)
- [ ] Tool definitions module
- [ ] Template rendering with Mustache
- [ ] Tool validation

### Phase 3: Sandbox (Day 3)
- [ ] Sandbox.Executor module
- [ ] bwrap args builder
- [ ] erlexec integration
- [ ] /tmp management

### Phase 4: Integration (Day 4)
- [ ] Extend Agent with vocation support
- [ ] Mode switching
- [ ] Tool execution in agent
- [ ] LangChainEx integration

### Phase 5: Testing & Polish (Day 5)
- [ ] Unit tests
- [ ] Integration tests
- [ ] Manual testing
- [ ] Documentation

---

## Open Questions for Future Iteration

1. **Tool Output Format**: Currently raw shell output. Should we support structured JSON?

2. **Tool Chaining**: Should tools be able to chain (pipe output to next tool)?

3. **Workspace Sharing**: How do workflow steps hand off workspaces? Copy vs symlink vs shared?

4. **Tool Timeouts**: Per-tool timeout or global? Configurable per-vocation?

5. **Tool Retries**: Should failed commands auto-retry? How many times?

6. **Workspace Templates**: Should vocations define initial workspace contents (template files)?

7. **Multi-Step Transactions**: If a tool fails mid-sequence, should previous tools rollback?

8. **Tool Audit Logging**: Should we log every tool execution (command, args, output) for compliance?

9. **Tool Dependencies**: Can tools depend on other tools (e.g., "compile" needs "read_file")?

10. **Dynamic Tools**: Can agents create custom tools at runtime?

---

## Related Documents

- `AGENT_CHAT.md` - Agent channel protocol
- `CONCEPT.md` - Overall system architecture
- `notes/agent-channel-protocol.md` - Channel message formats

---

## Summary

This design provides a foundation for sandboxed, vocation-driven agents with:

- **Clear separation**: Vocations (templates) → Agents (instances) → Modes (runtime permissions)
- **Strong sandboxing**: bwrap with explicit bind mounts
- **Flexible permissions**: Per-mode capability system
- **Simple tools**: Template-based shell commands
- **Clean lifecycle**: Persistent workspaces, cleaned /tmp

The MVP focuses on functionality over complexity, with clear extension points for future features.
