/**
 * Tests for App.jsx — focused on the `RootGate` component
 * that handles the bare `/` route.
 *
 * The contract under test:
 *   - No token in `localStorage` → redirect to `/login`.
 *   - Token present + WS not yet connected → render a
 *     loading screen and call `initChannels()`.
 *   - Token present + WS becomes connected → navigate to
 *     `/new_agent`.
 *
 * We test `RootGate` in isolation with a `MemoryRouter`
 * because the rest of `App.jsx` (the full router config
 * with all pages) is exercised by the existing
 * NewAgentPage / Sidebar / ChatPage test suites. Exporting
 * `RootGate` from App.jsx keeps the test surface small
 * without forcing a full-app render.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { render, screen, waitFor, act } from "@testing-library/react";
import { MemoryRouter, Routes, Route } from "react-router-dom";

import { RootGate, Layout } from "./App";
import { useStore } from "./store";

// `vi.mock` is hoisted, so the import path must be a
// literal — Vitest will replace the module before any test
// code runs.
vi.mock("./channels", () => ({
  initChannels: vi.fn(),
  joinLobby: vi.fn(),
  leaveLobby: vi.fn(),
}));

import { initChannels, joinLobby, leaveLobby } from "./channels";

function setConnected(value) {
  act(() => {
    useStore.setState({ isConnected: value });
  });
}

function renderGate(initialPath = "/") {
  // The MemoryRouter's `<Routes>` here is just so the
  // navigation triggered by `RootGate` actually renders
  // *something* observable. We don't need the full
  // production router — just enough to land on a page
  // distinct from the loading screen.
  return render(
    <MemoryRouter initialEntries={[initialPath]}>
      <Routes>
        <Route path="/" element={<RootGate />} />
        <Route path="/login" element={<div>Sign in</div>} />
        <Route path="/new_agent" element={<div>Create agent</div>} />
      </Routes>
    </MemoryRouter>,
  );
}

describe("RootGate", () => {
  beforeEach(() => {
    localStorage.removeItem("nest_token");
    useStore.getState()._reset();
    initChannels.mockClear();
  });

  afterEach(() => {
    vi.clearAllMocks();
    localStorage.removeItem("nest_token");
    useStore.getState()._reset();
  });

  it("renders a loading screen on first paint when a token is present", () => {
    localStorage.setItem("nest_token", "valid-token");
    renderGate();

    expect(screen.getByText(/loading/i)).toBeInTheDocument();
    expect(initChannels).toHaveBeenCalledTimes(1);
  });

  it("redirects to /login when no token is in localStorage", async () => {
    renderGate();

    await waitFor(() => {
      expect(screen.getByText(/sign in/i)).toBeInTheDocument();
    });
    expect(initChannels).not.toHaveBeenCalled();
  });

  it("navigates to /new_agent when isConnected becomes true", async () => {
    localStorage.setItem("nest_token", "valid-token");
    renderGate();

    // Loading screen visible before connection lands.
    expect(screen.getByText(/loading/i)).toBeInTheDocument();

    // Simulate the WS handshake completing.
    setConnected(true);

    await waitFor(() => {
      expect(screen.getByText(/create agent/i)).toBeInTheDocument();
    });
    expect(screen.queryByText(/loading/i)).toBeNull();
  });

  it("stays on the loading screen if the WS never connects", () => {
    localStorage.setItem("nest_token", "valid-token");
    renderGate();

    // isConnected stays false (default) → gate remains on
    // the loading screen. We don't auto-redirect to /login
    // here; only the server can decide the token is invalid.
    expect(screen.getByText(/loading/i)).toBeInTheDocument();
    expect(initChannels).toHaveBeenCalledTimes(1);
  });
});

describe("App default export", () => {
  it("renders without crashing and lands on the RootGate", async () => {
    // The full production App wires its own
    // `createBrowserRouter`. We can't reach into it from
    // outside, so this test only confirms that the App
    // component mounts without throwing. The detailed
    // navigation behavior is exercised by the RootGate
    // describe block above with its own minimal router.
    const { default: App } = await import("./App");
    const { container } = render(<App />);

    // RootGate's loading state or one of its redirect
    // targets ("Sign in" on /login, "Create agent" on
    // /new_agent) should be visible depending on the
    // token presence. jsdom defaults to `about:blank` so
    // the production router lands on `/`, which the
    // RootGate sees with no token and routes to /login.
    expect(container.textContent).toMatch(/loading|sign in/i);
  });
});

describe("Layout", () => {
  beforeEach(() => {
    useStore.getState()._reset();
    initChannels.mockClear();
    joinLobby.mockClear();
    leaveLobby.mockClear();
  });

  afterEach(() => {
    vi.clearAllMocks();
    useStore.getState()._reset();
  });

  it("calls initChannels on mount", () => {
    render(
      <MemoryRouter>
        <Layout />
      </MemoryRouter>,
    );

    expect(initChannels).toHaveBeenCalledTimes(1);
  });

  it("calls joinLobby when isConnected is true", () => {
    useStore.setState({ isConnected: true });

    render(
      <MemoryRouter>
        <Layout />
      </MemoryRouter>,
    );

    expect(joinLobby).toHaveBeenCalledTimes(1);
  });

  it("does not call joinLobby when isConnected is false", () => {
    useStore.setState({ isConnected: false });

    render(
      <MemoryRouter>
        <Layout />
      </MemoryRouter>,
    );

    expect(joinLobby).not.toHaveBeenCalled();
  });

  it("calls leaveLobby on unmount", () => {
    const { unmount } = render(
      <MemoryRouter>
        <Layout />
      </MemoryRouter>,
    );

    unmount();
    expect(leaveLobby).toHaveBeenCalledTimes(1);
  });
});
