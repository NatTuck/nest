# Test Plan for Agent Status and Creation Issues

## Issues Identified

### Issue 1: Agent status not appearing for existing agents
**Root Cause:** The `Supervisor.list_agents()` function returns agents with atom keys in Elixir. When serialized to JSON and sent to the browser, these become string keys. The Sidebar component expects `agent.status` to display the status indicator.

**Verification Needed:**
- Check that `init` event payload from lobby channel has correct structure
- Verify `setAgents` properly handles the data
- Ensure `agent.status` is accessible in Sidebar

### Issue 2: Creating new agents returns undefined ID
**Root Cause:** The `createAgent()` function in `channels.js` expects `resp.id` from the server reply. The server sends `%{"id" => id}` with string keys. Need to verify Phoenix is correctly serializing and the client is accessing the response properly.

**Verification Needed:**
- Confirm `lobbyChannel.push("create_agent").receive("ok")` returns `{id: "..."}`
- Check that `resp.id` is not undefined
- Verify the response is properly awaited

### Issue 3: Agent:created broadcast payload structure
**Root Cause:** When `agent:created` is broadcast, the payload has the shape `{"id" => id, "model" => %{"name" => model_name}}`. The `store.addAgent(agent)` method creates an agent with `status: "idle"`.

**Verification Needed:**
- Test that broadcast payload matches expected structure
- Verify `addAgent` handles the payload correctly
- Ensure agent appears in list with correct data

## Tests to Write

### 1. Store Tests (`assets/js/store/index.test.js`)

#### Test: setAgents with server payload
```javascript
it("sets agents list from init payload", () => {
  const store = useStore.getState();
  
  const agents = [
    { id: "agent-1", model: { name: "gpt-4", provider: "openai" }, status: "idle" },
    { id: "agent-2", model: { name: "claude-3", provider: "anthropic" }, status: "streaming" },
  ];
  
  store.setAgents(agents);
  
  expect(useStore.getState().agents).toHaveLength(2);
  expect(useStore.getState().agents[0].id).toBe("agent-1");
  expect(useStore.getState().agents[0].status).toBe("idle");
});
```

#### Test: addAgent with broadcast payload
```javascript
it("adds new agent from broadcast payload", () => {
  const store = useStore.getState();
  
  // Simulate agent:created broadcast payload from Phoenix
  const payload = {
    id: "new-agent",
    model: { name: "gpt-4" },
  };
  
  store.addAgent(payload);
  
  const agents = useStore.getState().agents;
  expect(agents).toHaveLength(1);
  expect(agents[0].id).toBe("new-agent");
  expect(agents[0].status).toBe("idle");
});
```

### 2. Channels Tests (`assets/js/channels.test.js`)

#### Test: createAgent returns correct ID
```javascript
it("returns the agent id from response", async () => {
  // Setup mock to return {id: "new-agent-123"}
  const result = await createAgent({ name: "gpt-4", provider: "openai" });
  
  expect(result).toBe("new-agent-123");
  expect(result).not.toBeUndefined();
});
```

#### Test: createAgent handles response correctly
```javascript
it("handles create_agent response with id", async () => {
  const model = { name: "gpt-4" };
  const id = await createAgent(model);
  
  expect(typeof id).toBe("string");
  expect(id.length).toBeGreaterThan(0);
});
```

### 3. Sidebar Tests (add to Sidebar.test.jsx)

#### Test: Agent status display
```javascript
it("displays agent status indicator", () => {
  const mockStore = {
    agents: [
      { id: "agent-1", model: { name: "gpt-4" }, status: "streaming" },
      { id: "agent-2", model: { name: "claude-3" }, status: "idle" },
    ],
  };
  
  render(<Sidebar />);
  
  // Status indicators should show
  const statusIndicators = screen.getAllByRole("generic").filter(
    el => el.className.includes("rounded-full")
  );
  expect(statusIndicators.length).toBe(2);
});
```

## Implementation Steps

1. **Create store tests** - Test `setAgents`, `addAgent`, `removeAgent` with realistic payloads
2. **Create channels tests** - Test `createAgent`, `joinLobby` event handlers
3. **Run tests** - Identify actual bugs from test failures
4. **Fix bugs** - Address any issues found in store or channels
5. **Add integration tests** - Test Sidebar agent display, NewAgentPage creation flow

## Key Data Structures

### Server `list_agents()` returns:
```elixir
[
  %{
    id: "clever-raven",
    model: %{name: "gpt-4", provider: "openai"},
    status: :idle
  }
]
```

### After JSON serialization (client receives):
```javascript
[
  {
    id: "clever-raven",
    model: {name: "gpt-4", provider: "openai"},
    status: "idle"
  }
]
```

### Server `agent:created` broadcast:
```elixir
%{
  "id" => id,
  "model" => %{"name" => model_name}
}
```

### Client receives:
```javascript
{
  id: "clever-raven",
  model: {name: "gpt-4"}
}
```

## Potential Fixes

If tests reveal issues:

1. **addAgent accessing wrong property:**
   ```javascript
   // Current:
   addAgent: (agent) => {
     // agent might have wrong structure
   }
   
   // Fix - handle both structures:
   addAgent: (payload) => {
     const agent = {
       id: payload.id,
       model: payload.model,
       status: "idle"
     };
     // ...
   }
   ```

2. **createAgent response handling:**
   ```javascript
   // Current:
   return resp.id;
   
   // Might need to check:
   const resp = await lobbyChannel.push("create_agent", { model }).receive("ok");
   if (!resp || !resp.id) {
     throw new Error("Invalid response from server");
   }
   return resp.id;
   ```

3. **Agent status not set:**
   ```javascript
   // Ensure init payload has status
   store.setAgents(payload.agents || []);
   // agents should already have status from server
   ```
