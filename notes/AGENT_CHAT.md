# Agent Chat System Design

A real-time chat interface with AI agents using Phoenix Channels and React.

## Overview

**Architecture:**
```
Browser (React + React Router)
  ↓ WebSocket
Phoenix Channel (Lobby + Agent-specific)
  ↓
Agent GenServer (in-memory, per-agent)
  ↓
LLMChain with streaming callbacks
  ↓
Model API (OpenAI, Anthropic, etc.)
```

**Key Decisions:**
- Agent storage: In-memory GenServers (no database persistence)
- Agent IDs: Readable two-word strings via `unique_names_generator` (e.g., "clever-raven")
- Communication: Phoenix Channels for all real-time features
- REST API: Minimal (only initial page load)
- Chat UI: `@llamaindex/chat-ui` components
- Streaming: LLMChain callbacks broadcast deltas via channels
- Lifecycle: No auto-terminate (agents run until explicitly deleted)

---

## Phase 1: Agent Backend (`lib/nest/agents/`)

### 1.1 Name Generator

**Purpose:** Generate unique, readable agent IDs.

**File:** `lib/nest/agents/name_generator.ex`

**Implementation:**
- Uses `:unique_names_generator` library
- Configuration: `[:adjectives, :animals]` with `-` separator
- Checks collision against running agents via Registry
- Regenerates on collision

**Test Plan (TDD):**
```elixir
# test/nest/agents/name_generator_test.exs
describe "generate/0" do
  test "generates name in adjective-animal format" do
    name = NameGenerator.generate()
    assert Regex.match?(~r/^[a-z]+-[a-z]+$/, name)
  end

  test "generates unique names across multiple calls" do
    names = for _ <- 1..100, do: NameGenerator.generate()
    assert length(Enum.uniq(names)) == length(names)
  end
end

describe "generate_unique/1" do
  test "avoids collision with existing names" do
    existing = MapSet.new(["clever-raven"])
    name = NameGenerator.generate_unique(existing)
    refute MapSet.member?(existing, name)
    assert Regex.match?(~r/^[a-z]+-[a-z]+$/, name)
  end
end
```

**Run:** `mix test test/nest/agents/name_generator_test.exs`

---

### 1.2 Agent Registry

**Purpose:** Registry for agent process lookup by ID.

**File:** `lib/nest/agents/registry.ex`

**Implementation:**
- Uses Elixir's `Registry` module
- `:unique` keys for agent IDs
- Provides `via_tuple/1` helper for process naming

**Test Plan (TDD):**
```elixir
# test/nest/agents/registry_test.exs
describe "child_spec/0" do
  test "returns registry child spec" do
    spec = Registry.child_spec()
    assert spec.type == :supervisor
    assert spec.restart == :permanent
  end
end

describe "via_tuple/1" do
  test "returns via tuple for agent lookup" do
    assert Registry.via_tuple("clever-raven") ==
           {:via, Registry, {Nest.Agents.Registry, "clever-raven"}}
  end
end
```

**Run:** `mix test test/nest/agents/registry_test.exs`

---

### 1.3 Agent GenServer

**Purpose:** Core agent process managing chat state and LLM streaming.

**File:** `lib/nest/agents/agent.ex`

**State:**
```elixir
%{
  id: String.t(),              # Agent readable ID
  model: map(),                # Model configuration
  chain: LLMChain.t(),         # LangChain chain
  messages: list(),            # Chat history
  status: :idle | :streaming,  # Current status
  channel_pid: pid() | nil     # Channel process for callbacks
}
```

**API:**
- `start_link/1` - Start agent with model config
- `chat/2` - Send user message, triggers streaming response
- `get_state/1` - Get current agent state
- `set_channel/2` - Set channel PID for callbacks

**Streaming Implementation:**
Uses `LLMChain.add_callback/2` with:
- `on_delta/2` - Broadcasts streaming tokens to channel
- `on_message_processed/2` - Broadcasts complete message

**Test Plan (TDD):**
```elixir
# test/nest/agents/agent_test.exs
describe "start_link/1" do
  test "starts agent with initial state" do
    {:ok, pid} = Agent.start_link(%{id: "test-agent", model: %{name: "gpt-4"}})
    state = Agent.get_state(pid)
    assert state.id == "test-agent"
    assert state.status == :idle
    assert state.messages == []
  end
end

describe "chat/2" do
  test "adds user message to state" do
    {:ok, pid} = start_supervised_agent()
    Agent.chat(pid, "Hello")
    state = Agent.get_state(pid)
    assert length(state.messages) == 1
    assert hd(state.messages).role == :user
  end

  test "triggers streaming response" do
    # Mock LLMChain to avoid actual API calls
    {:ok, pid} = start_supervised_agent()
    Agent.set_channel(pid, self())
    Agent.chat(pid, "Hello")
    assert_receive {:delta, _}, 5000
    assert_receive {:message, _}, 5000
  end
end

describe "get_state/1" do
  test "returns current agent state" do
    {:ok, pid} = start_supervised_agent()
    state = Agent.get_state(pid)
    assert state.id == "test-agent"
    assert is_list(state.messages)
  end
end
```

**Test Helpers:**
```elixir
defp start_supervised_agent(attrs \\ %{}) do
  default = %{id: "test-agent", model: %{name: "gpt-4", provider: "openai"}}
  attrs = Map.merge(default, attrs)
  start_supervised!({Agent, attrs})
end
```

**Run:** `mix test test/nest/agents/agent_test.exs`

---

### 1.4 Agent Supervisor

**Purpose:** DynamicSupervisor for agent lifecycle management.

**File:** `lib/nest/agents/supervisor.ex`

**API:**
- `start_agent/1` - Start new agent, generates ID if needed
- `stop_agent/1` - Stop agent by ID
- `list_agents/0` - List all running agents
- `get_agent/1` - Get agent PID by ID

**Test Plan (TDD):**
```elixir
# test/nest/agents/supervisor_test.exs
describe "start_agent/1" do
  test "starts agent with generated ID" do
    {:ok, id} = Supervisor.start_agent(%{model: "gpt-4"})
    assert Regex.match?(~r/^[a-z]+-[a-z]+$/, id)
    assert {:ok, _pid} = Registry.lookup(id)
  end

  test "starts agent with explicit ID" do
    {:ok, "custom-id"} = Supervisor.start_agent(%{id: "custom-id", model: "gpt-4"})
    assert {:ok, _pid} = Registry.lookup("custom-id")
  end
end

describe "stop_agent/1" do
  test "stops agent and removes from registry" do
    {:ok, id} = Supervisor.start_agent(%{model: "gpt-4"})
    :ok = Supervisor.stop_agent(id)
    refute Registry.lookup(id)
  end
end

describe "list_agents/0" do
  test "returns list of running agents" do
    {:ok, id1} = Supervisor.start_agent(%{model: "gpt-4"})
    {:ok, id2} = Supervisor.start_agent(%{model: "claude-3"})
    agents = Supervisor.list_agents()
    assert length(agents) == 2
    assert Enum.any?(agents, & &1.id == id1)
    assert Enum.any?(agents, & &1.id == id2)
  end
end

describe "get_agent/1` do
  test "returns agent PID by ID" do
    {:ok, id} = Supervisor.start_agent(%{model: "gpt-4"})
    {:ok, pid} = Supervisor.get_agent(id)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "returns error for non-existent agent" do
    assert {:error, :not_found} = Supervisor.get_agent("nonexistent")
  end
end
```

**Run:** `mix test test/nest/agents/supervisor_test.exs`

---

### 1.5 Agents Context Module

**Purpose:** Public API for agent operations.

**File:** `lib/nest/agents.ex`

**API:**
- `create_agent(model_name)` - Creates agent with model from DotConfig
- `get_agent(id)` - Get agent state
- `list_agents/0` - List all agents
- `delete_agent(id)` - Delete agent
- `chat(id, message)` - Send message to agent

**Test Plan (TDD):**
```elixir
# test/nest/agents_test.exs
describe "create_agent/1" do
  test "creates agent with model from DotConfig" do
    {:ok, id} = Agents.create_agent("gpt-4")
    assert Regex.match?(~r/^[a-z]+-[a-z]+$/, id)
    assert {:ok, agent} = Agents.get_agent(id)
    assert agent.model.name == "gpt-4"
  end

  test "returns error for invalid model" do
    assert {:error, :model_not_found} = Agents.create_agent("invalid-model")
  end
end

describe "chat/2` do
  test "sends message to agent" do
    {:ok, id} = Agents.create_agent("gpt-4")
    :ok = Agents.chat(id, "Hello")
    {:ok, agent} = Agents.get_agent(id)
    assert length(agent.messages) == 1
  end
end

describe "delete_agent/1` do
  test "removes agent" do
    {:ok, id} = Agents.create_agent("gpt-4")
    :ok = Agents.delete_agent(id)
    assert {:error, :not_found} = Agents.get_agent(id)
  end
end
```

**Run:** `mix test test/nest/agents_test.exs`

---

## Phase 2: Phoenix Channels

### 2.1 User Socket

**Purpose:** Socket mount and connection handling.

**File:** `lib/nest_web/channels/user_socket.ex`

**Implementation:**
- Connects clients via WebSocket
- No authentication (for MVP)
- Assigns socket ID

**Test Plan (TDD):**
```elixir
# test/nest_web/channels/user_socket_test.exs
describe "connect/3" do
  test "connects with valid params" do
    assert {:ok, socket} = UserSocket.connect(%{}, socket(), nil)
  end

  test "assigns socket ID" do
    {:ok, socket} = UserSocket.connect(%{}, socket(), nil)
    assert is_binary(socket.id)
  end
end

describe "id/1` do
  test "returns socket identifier" do
    socket = %Socket{id: "socket-123"}
    assert UserSocket.id(socket) == "socket-123"
  end
end
```

**Run:** `mix test test/nest_web/channels/user_socket_test.exs`

---

### 2.2 Lobby Channel

**Purpose:** Main channel for agent management (list, create, delete).

**File:** `lib/nest_web/channels/lobby_channel.ex`

**Topic:** `"lobby"`

**Events:**
- `join` → Returns `{agents: [...], models: [...]}`
- `create_agent` → Creates agent, broadcasts `agent:created`
- `delete_agent` → Stops agent, broadcasts `agent:deleted`

**Test Plan (TDD):**
```elixir
# test/nest_web/channels/lobby_channel_test.exs
describe "join/3` do
  test "returns agents and models on join" do
    {:ok, _, socket} = subscribe_and_join(socket(), LobbyChannel, "lobby")
    assert %{agents: [], models: _} = socket.assigns
  end
end

describe "handle_in(create_agent)` do
  test "creates agent and broadcasts event" do
    subscribe_and_join(socket(), LobbyChannel, "lobby")
    ref = push(socket(), "create_agent", %{"model" => "gpt-4"})
    assert_reply ref, :ok, %{"id" => id}
    assert Regex.match?(~r/^[a-z]+-[a-z]+$/, id)
    assert_broadcast "agent:created", %{"id" => id}
  end
end

describe "handle_in(delete_agent)` do
  test "deletes agent and broadcasts event" do
    # Setup: create agent first
    {:ok, id} = Agents.create_agent("gpt-4")
    subscribe_and_join(socket(), LobbyChannel, "lobby")
    
    ref = push(socket(), "delete_agent", %{"id" => id})
    assert_reply ref, :ok, %{}
    assert_broadcast "agent:deleted", %{"id" => id}
    
    # Verify agent stopped
    assert {:error, :not_found} = Agents.get_agent(id)
  end
end
```

**Run:** `mix test test/nest_web/channels/lobby_channel_test.exs`

---

### 2.3 Agent Channel

**Purpose:** Per-agent chat channel with streaming support.

**File:** `lib/nest_web/channels/agent_channel.ex`

**Topic:** `"agent:ID"` (e.g., `"agent:clever-raven"`)

**Events:**
- `join` → Returns agent state (messages, model)
- `chat:message` → Sends message to agent
- Broadcasts:
  - `chat:delta` → Streaming token
  - `chat:message` → Complete assistant message
  - `chat:error` → Error response

**Streaming Implementation:**
Agent process subscribes to PubSub, channel receives events and broadcasts to client.

**Test Plan (TDD):**
```elixir
# test/nest_web/channels/agent_channel_test.exs
describe "join/3` do
  test "joins agent channel and returns state" do
    {:ok, id} = Agents.create_agent("gpt-4")
    {:ok, _, socket} = subscribe_and_join(socket(), AgentChannel, "agent:#{id}")
    assert socket.topic == "agent:#{id}"
  end

  test "returns error for non-existent agent" do
    assert {:error, %{reason: "agent not found"}} = 
           subscribe_and_join(socket(), AgentChannel, "agent:nonexistent")
  end
end

describe "handle_in(chat:message)` do
  test "sends message and broadcasts streaming response" do
    {:ok, id} = Agents.create_agent("gpt-4")
    {:ok, _, socket} = subscribe_and_join(socket(), AgentChannel, "agent:#{id}")
    
    ref = push(socket(), "chat:message", %{"content" => "Hello"})
    assert_reply ref, :ok, %{}
    
    # Should receive delta(s) and final message
    assert_broadcast "chat:delta", %{"content" => _}
    assert_broadcast "chat:message", %{"role" => "assistant", "content" => _}
  end
end

describe "terminate/2` do
  test "cleans up channel subscription" do
    {:ok, id} = Agents.create_agent("gpt-4")
    {:ok, _, socket} = subscribe_and_join(socket(), AgentChannel, "agent:#{id}")
    
    # Simulate disconnect
    AgentChannel.terminate(:shutdown, socket)
    
    # Agent should still exist (no auto-terminate)
    assert {:ok, _} = Agents.get_agent(id)
  end
end
```

**Run:** `mix test test/nest_web/channels/agent_channel_test.exs`

---

## Phase 3: Frontend - React Router & State

### 3.1 Zustand Store

**Purpose:** Global state management for agents and socket.

**File:** `assets/js/store/index.js`

**State:**
```javascript
{
  agents: [],           // List of agent summaries
  models: [],           // Available models from DotConfig
  currentAgent: null, // Current agent ID and state
  socket: null,         // Phoenix Socket instance
  lobbyChannel: null,   // Lobby channel ref
  agentChannel: null,   // Current agent channel ref
  isConnected: false
}
```

**Actions:**
- `connectSocket()` - Initialize Phoenix Socket
- `joinLobby()` - Join lobby channel, fetch agents/models
- `createAgent(model)` - Push create_agent event
- `joinAgent(id)` - Join agent channel
- `sendMessage(content)` - Push chat:message event
- `leaveAgent()` - Leave current agent channel
- `deleteAgent(id)` - Push delete_agent event

**Test Plan (TDD):**
```javascript
// assets/js/store/store.test.js
describe("Store", () => {
  beforeEach(() => {
    // Reset store
  });

  describe("connectSocket", () => {
    test("initializes socket connection", () => {
      // Mock Phoenix Socket
      // Verify socket created and connected
    });
  });

  describe("joinLobby", () => {
    test("joins lobby and fetches initial data", async () => {
      // Mock channel join
      // Verify agents and models populated
    });
  });

  describe("createAgent", () => {
    test("creates agent and navigates to it", async () => {
      // Mock channel push
      // Verify agent added to list
      // Verify navigation called
    });
  });

  describe("sendMessage", () => {
    test("pushes message to channel", () => {
      // Setup: joined agent channel
      // Push message
      // Verify channel.push called
    });
  });
});
```

**Run:** `cd assets && pnpm test store/store.test.js`

---

### 3.2 Phoenix Socket Setup

**Purpose:** Initialize and manage Phoenix Socket.

**File:** `assets/js/socket.js`

**Implementation:**
- Create singleton socket with CSRF token
- Handle connection/reconnection
- Export socket instance

**Test Plan (TDD):**
```javascript
// assets/js/socket.test.js
describe("Socket", () => {
  test("initializes with CSRF token", () => {
    // Mock document.querySelector for meta tag
    // Verify socket created with token
  });

  test("connects on creation", () => {
    // Verify socket.connect() called
  });

  test("handles reconnection", () => {
    // Simulate disconnect
    // Verify socket attempts reconnect
  });
});
```

**Run:** `cd assets && pnpm test socket.test.js`

---

## Phase 4: Frontend - Components & Pages

### 4.1 Layout & Sidebar

**Purpose:** Main application layout with navigation sidebar.

**Files:**
- `assets/js/components/Layout.jsx` - Layout wrapper
- `assets/js/components/Sidebar.jsx` - Navigation sidebar

**Features:**
- Responsive sidebar (fixed width desktop, collapsible mobile)
- Active agent list with delete buttons
- "New Agent" button
- About link
- Current route highlighting

**Test Plan (TDD):**
```javascript
// assets/js/components/Sidebar.test.jsx
describe("Sidebar", () => {
  test("renders new agent button", () => {
    render(<Sidebar />);
    expect(screen.getByText("New Agent")).toBeInTheDocument();
  });

  test("renders list of agents", () => {
    const agents = [{ id: "clever-raven", model: "gpt-4" }];
    render(<Sidebar agents={agents} />);
    expect(screen.getByText("clever-raven")).toBeInTheDocument();
  });

  test("highlights current agent", () => {
    const agents = [{ id: "clever-raven", model: "gpt-4" }];
    render(<Sidebar agents={agents} currentAgent="clever-raven" />);
    const link = screen.getByText("clever-raven");
    expect(link).toHaveClass("active");
  });

  test("calls deleteAgent on delete click", () => {
    const deleteAgent = vi.fn();
    const agents = [{ id: "clever-raven", model: "gpt-4" }];
    render(<Sidebar agents={agents} deleteAgent={deleteAgent} />);
    
    fireEvent.click(screen.getByLabelText("Delete clever-raven"));
    expect(deleteAgent).toHaveBeenCalledWith("clever-raven");
  });
});
```

**Run:** `cd assets && pnpm test components/Sidebar.test.jsx`

---

### 4.2 New Agent Page

**Purpose:** Form to create new agent with model selection.

**File:** `assets/js/pages/NewAgentPage.jsx`

**Features:**
- Model dropdown (flat list)
- Create Agent button
- Loading state
- Navigate to new agent on success

**Test Plan (TDD):**
```javascript
// assets/js/pages/NewAgentPage.test.jsx
describe("NewAgentPage", () => {
  test("renders model selector", () => {
    const models = ["gpt-4", "claude-3"];
    render(<NewAgentPage models={models} />);
    expect(screen.getByLabelText("Select Model")).toBeInTheDocument();
  });

  test("creates agent on submit", async () => {
    const createAgent = vi.fn().mockResolvedValue("clever-raven");
    render(<NewAgentPage models={["gpt-4"]} createAgent={createAgent} />);
    
    fireEvent.change(screen.getByLabelText("Select Model"), {
      target: { value: "gpt-4" }
    });
    fireEvent.click(screen.getByText("Create Agent"));
    
    expect(createAgent).toHaveBeenCalledWith("gpt-4");
  });

  test("navigates to new agent on success", async () => {
    const navigate = vi.fn();
    const createAgent = vi.fn().mockResolvedValue("clever-raven");
    render(<NewAgentPage models={["gpt-4"]} createAgent={createAgent} navigate={navigate} />);
    
    fireEvent.click(screen.getByText("Create Agent"));
    await waitFor(() => {
      expect(navigate).toHaveBeenCalledWith("/agent/clever-raven");
    });
  });
});
```

**Run:** `cd assets && pnpm test pages/NewAgentPage.test.jsx`

---

### 4.3 Chat Page & Custom Hook

**Purpose:** Chat interface using `@llamaindex/chat-ui` with Phoenix Channel.

**Files:**
- `assets/js/hooks/useAgentChat.js` - Custom chat hook
- `assets/js/pages/ChatPage.jsx` - Chat page

**Hook Implementation:**
Implements `ChatHandler` interface:
- `messages` - Array of chat messages
- `status` - 'ready' | 'streaming' | 'submitted' | 'error'
- `sendMessage(content)` - Push message to channel
- `stop()` - Cancel ongoing request

**Test Plan (TDD):**
```javascript
// assets/js/hooks/useAgentChat.test.js
describe("useAgentChat", () => {
  test("initializes with empty messages", () => {
    const { result } = renderHook(() => useAgentChat("clever-raven"));
    expect(result.current.messages).toEqual([]);
    expect(result.current.status).toBe("ready");
  });

  test("sends message via channel", () => {
    const mockPush = vi.fn();
    const { result } = renderHook(() => useAgentChat("clever-raven", mockPush));
    
    act(() => {
      result.current.sendMessage("Hello");
    });
    
    expect(mockPush).toHaveBeenCalledWith("chat:message", { content: "Hello" });
    expect(result.current.status).toBe("submitted");
  });

  test("receives streaming deltas", () => {
    const { result } = renderHook(() => useAgentChat("clever-raven"));
    
    // Simulate incoming delta
    act(() => {
      result.current.handleDelta({ content: "Hello" });
    });
    
    expect(result.current.messages).toHaveLength(1);
    expect(result.current.messages[0].role).toBe("assistant");
  });

  test("completes message on final response", () => {
    const { result } = renderHook(() => useAgentChat("clever-raven"));
    
    act(() => {
      result.current.handleMessage({ role: "assistant", content: "Hello there!" });
    });
    
    expect(result.current.status).toBe("ready");
    expect(result.current.messages).toHaveLength(1);
  });
});
```

**Run:** `cd assets && pnpm test hooks/useAgentChat.test.js`

---

### 4.4 About Page

**Purpose:** About page with mascot and flip feature.

**File:** `assets/js/pages/AboutPage.jsx`

**Implementation:**
- Move current `NestLanding.jsx` content here
- Mascot image with flip toggle button

**Test Plan (TDD):**
```javascript
// assets/js/pages/AboutPage.test.jsx
describe("AboutPage", () => {
  test("renders mascot image", () => {
    render(<AboutPage />);
    expect(screen.getByAltText("Nest Mascots")).toBeInTheDocument();
  });

  test("toggles image flip on button click", () => {
    render(<AboutPage />);
    const image = screen.getByTestId("mascot-image");
    const button = screen.getByTestId("toggle-button");
    
    expect(image).toHaveStyle({ transform: "scaleX(1)" });
    
    fireEvent.click(button);
    expect(image).toHaveStyle({ transform: "scaleX(-1)" });
    
    fireEvent.click(button);
    expect(image).toHaveStyle({ transform: "scaleX(1)" });
  });
});
```

**Run:** `cd assets && pnpm test pages/AboutPage.test.jsx`

---

## Phase 5: Integration & E2E Testing

### 5.1 Channel Integration Tests

**Test full flow:** Socket → Channel → Agent → Response

```elixir
# test/nest_web/channels/integration_test.exs
describe "full chat flow" do
  test "user creates agent and sends message", %{socket: socket} do
    # Join lobby
    {:ok, %{"agents" => [], "models" => models}, _} = 
      subscribe_and_join(socket, LobbyChannel, "lobby")
    
    assert length(models) > 0
    
    # Create agent
    ref = push(socket, "create_agent", %{"model" => List.first(models)})
    assert_reply ref, :ok, %{"id" => id}
    
    # Join agent channel
    {:ok, _, agent_socket} = subscribe_and_join(socket, AgentChannel, "agent:#{id}")
    
    # Send message
    ref = push(agent_socket, "chat:message", %{"content" => "Hello"})
    assert_reply ref, :ok, %{}
    
    # Receive streaming response
    assert_broadcast "chat:delta", %{"content" => _}
    assert_broadcast "chat:message", %{"role" => "assistant"}
  end
end
```

**Run:** `mix test test/nest_web/channels/integration_test.exs`

---

### 5.2 Frontend Integration Tests

**Test React Router + Store + Components:**

```javascript
// assets/js/App.test.jsx
describe("App Integration", () => {
  test("full user flow", async () => {
    // 1. Render app
    render(<App />);
    
    // 2. Land on New Agent page
    expect(screen.getByText("Create New Agent")).toBeInTheDocument();
    
    // 3. Select model and create
    fireEvent.change(screen.getByLabelText("Select Model"), {
      target: { value: "gpt-4" }
    });
    fireEvent.click(screen.getByText("Create Agent"));
    
    // 4. Navigate to chat page
    await waitFor(() => {
      expect(screen.getByTestId("chat-section")).toBeInTheDocument();
    });
    
    // 5. Send message
    fireEvent.change(screen.getByPlaceholderText("Type a message..."), {
      target: { value: "Hello" }
    });
    fireEvent.click(screen.getByText("Send"));
    
    // 6. Verify message appears
    expect(screen.getByText("Hello")).toBeInTheDocument();
  });
});
```

**Run:** `cd assets && pnpm test App.test.jsx`

---

## Running All Tests

### Backend Tests
```bash
# Run all tests
mix test

# Run specific test file
mix test test/nest/agents/agent_test.exs

# Run tests with coverage
mix coveralls
```

### Frontend Tests
```bash
cd assets

# Run all tests
pnpm test

# Run with watch mode
pnpm test:watch

# Run specific file
pnpm test store/index.test.js
```

### Full Test Suite
```bash
# Run precommit (lint + tests)
mix precommit
```

---

## Implementation Order

1. **Phase 1** - Agent backend (GenServer → Supervisor → Context)
2. **Phase 2** - Channels (Socket → Lobby → Agent)
3. **Phase 3** - Frontend core (Socket → Store → Router)
4. **Phase 4** - UI components (Layout → Sidebar → Pages)
5. **Phase 5** - Integration & polish

**Each phase should be fully tested before moving to the next.**

---

## Dependencies

### Elixir
Add to `mix.exs`:
```elixir
{:unique_names_generator, "~> 0.2.0"}
```

### JavaScript
Already installed:
- `react-router`
- `@llamaindex/chat-ui`
- `zustand` (if not, add it)

Add:
```bash
cd assets && pnpm add zustand
```

---

## Notes

- **No persistence**: Agent state is lost on server restart
- **Streaming**: Deltas broadcast in real-time for typing effect
- **Error handling**: LLM errors broadcast as `chat:error` events
- **Reconnection**: Channels auto-rejoin on socket reconnect
