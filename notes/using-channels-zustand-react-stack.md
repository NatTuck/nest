 The correct architecture, in priority order:

**Phoenix Channels** own the wire. **Zustand** owns the state. **React** renders snapshots. **React Router** is demoted to a URL parser.

If React Router v7's data API (loaders, actions, `useLoaderData`) conflicts with that, **delete the data API**, not the other three. Here is the current correct pattern for each layer.

---

## 1. Phoenix Channels — Service Layer, Not React State

Channels are long-lived, bidirectional, and push-based. They do not belong in React component state.

```ts
// services/channel.ts
import { Socket, Channel } from 'phoenix';
import { useLobbyStore } from '../store/lobby';

class ChannelService {
  private socket = new Socket('/socket', { params: { token: window.token } });
  private channels = new Map<string, Channel>();

  connect() {
    this.socket.connect();
  }

  join(topic: string) {
    if (this.channels.has(topic)) return;

    const channel = this.socket.channel(topic);
    channel.on('new_msg', (msg) => useLobbyStore.getState().addMessage(msg));
    channel.on('presence_diff', (diff) => useLobbyStore.getState().updatePresence(diff));

    channel
      .join()
      .receive('ok', () => useLobbyStore.getState().setConnected(topic, true))
      .receive('error', (err) => useLobbyStore.getState().setError(topic, err));

    this.channels.set(topic, channel);
  }

  push(topic: string, event: string, payload: unknown) {
    this.channels.get(topic)?.push(event, payload);
  }

  leave(topic: string) {
    this.channels.get(topic)?.leave();
    this.channels.delete(topic);
  }
}

export const channels = new ChannelService();
```

**Key rule:** Channels write to Zustand via `getState()`. They never call `setState` on a React component.

---

## 2. Zustand — The Actual Source of Truth

All state lives here. React Router's `useLoaderData` is forbidden.

```ts
// store/lobby.ts
import { create } from 'zustand';

interface LobbyState {
  messages: Message[];
  presence: PresenceMap;
  connected: Set<string>;
  addMessage: (msg: Message) => void;
  updatePresence: (diff: PresenceDiff) => void;
  setConnected: (topic: string, v: boolean) => void;
}

export const useLobbyStore = create<LobbyState>((set) => ({
  messages: [],
  presence: {},
  connected: new Set(),

  addMessage: (msg) =>
    set((s) => ({ messages: [...s.messages, msg] })),

  updatePresence: (diff) =>
    set((s) => ({ presence: syncPresence(s.presence, diff) })),

  setConnected: (topic, v) =>
    set((s) => {
      const next = new Set(s.connected);
      v ? next.add(topic) : next.delete(topic);
      return { connected: next };
    }),
}));
```

**Why this matters:** Zustand uses `useSyncExternalStore`, which is the React 19 blessed pattern for external stores. It does not have the async scheduler issues that `useEffect` + `setState` has. Components re-render when Zustand notifies them, and that notification is synchronous and act-safe.

---

## 3. React — Pure Renderer

Components read from Zustand. They do not fetch. They do not hold async state.

```tsx
// pages/LobbyPage.tsx
import { useParams } from 'react-router-dom';
import { useLobbyStore } from '../store/lobby';
import { channels } from '../services/channel';
import { useEffect } from 'react';

export default function LobbyPage() {
  const { lobbyId } = useParams<{ lobbyId: string }>();
  const messages = useLobbyStore((s) => s.messages);
  const connected = useLobbyStore((s) => s.connected.has(`lobby:${lobbyId}`));

  useEffect(() => {
    const topic = `lobby:${lobbyId}`;
    channels.join(topic);
    return () => channels.leave(topic);
  }, [lobbyId]);

  return (
    <div>
      <ConnectionBadge connected={connected} />
      <MessageList messages={messages} />
      <MessageInput onSend={(text) => channels.push(`lobby:${lobbyId}`, 'new_msg', { text })} />
    </div>
  );
}
```

**No `useState` for data. No `useEffect` with async fetch. No `useLoaderData`.** The component is a pure function of Zustand state + URL params.

---

## 4. React Router — URL Mapper Only

React Router v7's data API (loaders, actions, `clientLoader`, `Form`) is designed for HTTP request/response cycles. It is hostile to:
- WebSocket push (Phoenix Channels)
- External stores (Zustand)
- Long-lived subscriptions

**Do not use the data API.** Use React Router as a URL → component mapper only.

### Option A: Keep React Router, ignore the data API

```tsx
// main.tsx
import { BrowserRouter, Routes, Route } from 'react-router-dom';

<BrowserRouter>
  <Routes>
    <Route path="/" element={<Layout />}>
      <Route path="lobby/:lobbyId" element={<LobbyPage />} />
      <Route path="invites" element={<InvitesPage />} />
    </Route>
  </Routes>
</BrowserRouter>
```

Use `useParams()`, `useNavigate()`, `useSearchParams()`. Never use `useLoaderData()`, `useActionData()`, or `<Form>`.

This eliminates the `act` warnings in tests because `<BrowserRouter>` does not have the internal async state machine that `RouterProvider` + `createMemoryRouter` has.

### Option B: Replace React Router (if you want type safety or smaller bundle)

**TanStack Router** is the correct replacement if you want a modern router that does not fight external stores.

```tsx
// router.ts
import { createRouter } from '@tanstack/react-router';
import { routeTree } from './routeTree.gen';

export const router = createRouter({
  routeTree,
  context: { store: useLobbyStore }, // pass Zustand in context
});
```

TanStack Router is designed to work with external stores. It does not force you to use loaders. It has type-safe `useParams()`. It does not have the React 19 `act` issues because it does not use `startTransition` for initial route commits.

**Wouter** is the correct replacement if you want minimalism (1.5KB, zero opinions about data).

---

## What This Fixes in Your Tests

With this architecture, your tests become trivial:

```tsx
// LobbyPage.test.tsx
import { render, screen } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import { useLobbyStore } from '../store/lobby';

it('shows messages from store', () => {
  // Seed Zustand directly — no async, no mocks, no act warnings
  useLobbyStore.setState({
    messages: [{ id: '1', text: 'hello', user: 'alice' }],
  });

  render(
    <MemoryRouter initialEntries={['/lobby/123']}>
      <Routes>
        <Route path="lobby/:lobbyId" element={<LobbyPage />} />
      </Routes>
    </MemoryRouter>
  );

  // Synchronous assertion
  expect(screen.getByText('hello')).toBeInTheDocument();
});
```

No deferred promises. No `act` flushes. No `await render()`. The component has no async effects — it reads from Zustand on mount. Zustand is already populated.

For testing the channel service itself:

```tsx
// services/channel.test.ts
it('pushes messages into the store', () => {
  channels.connect();
  channels.join('lobby:test');

  // Simulate a Phoenix push
  const store = useLobbyStore.getState();
  store.addMessage({ id: '1', text: 'hi' });

  expect(useLobbyStore.getState().messages).toHaveLength(1);
});
```

This is a unit test of the service, not a component test. No React, no router, no `act`.

---

## Summary

| Layer | Ownership | Forbidden |
|---|---|---|
| **Phoenix Channels** | Socket lifecycle, push events to Zustand | `useState`, `useEffect` async fetch |
| **Zustand** | All application state | Async logic inside store (keep it in services) |
| **React** | Render Zustand state + URL params | `useLoaderData`, `useEffect` fetch, component state for server data |
| **React Router** | URL → component mapping only | `clientLoader`, `clientAction`, `<Form>`, data revalidation |

If you adopt this, delete `RouterProvider` and `createMemoryRouter`. Use `<BrowserRouter>` or switch to TanStack Router. The 19 warnings disappear because there are no async state updates in components to warn about.
