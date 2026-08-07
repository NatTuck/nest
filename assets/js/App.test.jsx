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
 * We test `RootGate` in isolation with `renderWithRouter`
 * because the rest of `App.jsx` (the full router config
 * with all pages) is exercised by the existing
 * NewAgentPage / Sidebar / ChatPage test suites. Exporting
 * `RootGate` from App.jsx keeps the test surface small
 * without forcing a full-app render.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { render, screen, waitFor, act } from "@testing-library/react";

import { RootGate, Layout } from "./App";
import { useStore } from "./store";
import { renderWithRouter } from "./test/render_with_router";

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

async function renderGate(initialPath = "/") {
  return renderWithRouter(<RootGate />, {
    route: initialPath,
    routes: [
      { path: "/", element: <RootGate /> },
      { path: "/login", element: <div>Sign in</div> },
      { path: "/new_agent", element: <div>Create agent</div> },
    ],
  });
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

  it("renders a loading screen on first paint when a token is present", async () => {
    localStorage.setItem("nest_token", "valid-token");
    await renderGate();

    expect(screen.getByText(/loading/i)).toBeInTheDocument();
    expect(initChannels).toHaveBeenCalledTimes(1);
  });

  it("redirects to /login when no token is in localStorage", async () => {
    await renderGate();

    await waitFor(() => {
      expect(screen.getByText(/sign in/i)).toBeInTheDocument();
    });
    expect(initChannels).not.toHaveBeenCalled();
  });

  it("navigates to /new_agent when isConnected becomes true", async () => {
    localStorage.setItem("nest_token", "valid-token");
    await renderGate();

    // Loading screen visible before connection lands.
    expect(screen.getByText(/loading/i)).toBeInTheDocument();

    // Simulate the WS handshake completing. Wrap in `act` so
    // the Zustand subscription update that triggers
    // RootGate's `useEffect` lands inside the act boundary.
    await act(async () => {
      useStore.setState({ isConnected: true });
    });

    expect(await screen.findByText(/create agent/i)).toBeInTheDocument();
    expect(screen.queryByText(/loading/i)).toBeNull();
  });

  it("stays on the loading screen if the WS never connects", async () => {
    localStorage.setItem("nest_token", "valid-token");
    await renderGate();

    // isConnected stays false (default) → gate remains on
    // the loading screen. We don't auto-redirect to /login
    // here; only the server can decide the token is invalid.
    expect(screen.getByText(/loading/i)).toBeInTheDocument();
    expect(initChannels).toHaveBeenCalledTimes(1);
  });
});

describe("App default export", () => {
  it("renders without crashing and lands on the RootGate", async () => {
    // The full App wires its own `<BrowserRouter>` +
    // `<Routes>`. We don't reach into its router from
    // here — we render the App in a fresh jsdom window so
    // the production router config (incl. RootGate /
    // LoginPage / NewAgentPage routes) is exercised
    // end-to-end. The detailed navigation behavior is
    // covered by the RootGate describe block above.
    const { default: App } = await import("./App");
    const { container } = render(<App />);

    // RootGate's loading state or one of its redirect
    // targets ("Sign in" on /login) should be visible
    // depending on the token presence. jsdom defaults to
    // `about:blank` so the production router lands on
    // `/`, which the RootGate sees with no token and
    // routes to /login.
    expect(container.textContent).toMatch(/loading|sign in/i);
  });
});

describe("Layout", () => {
  beforeEach(() => {
    act(() => {
      useStore.getState()._reset();
    });
    initChannels.mockClear();
    joinLobby.mockClear();
    leaveLobby.mockClear();
  });

  afterEach(() => {
    vi.clearAllMocks();
    act(() => {
      useStore.getState()._reset();
    });
  });

  it("calls initChannels on mount", async () => {
    // Render `<Layout />` as a parent route with a dummy
    // Outlet child so react-router's router state settles
    // synchronously (a bare `<Layout />` with no outlet
    // match triggers an async re-render after the test's
    // `act` closes).
    await renderWithRouter(<Layout />, {
      routes: [
        {
          path: "/",
          element: <Layout />,
          children: [{ path: "*", element: <div data-testid="outlet" /> }],
        },
      ],
    });

    expect(initChannels).toHaveBeenCalledTimes(1);
  });

  it("calls joinLobby when isConnected is true", async () => {
    setConnected(true);
    await renderWithRouter(<Layout />, {
      routes: [
        {
          path: "/",
          element: <Layout />,
          children: [{ path: "*", element: <div data-testid="outlet" /> }],
        },
      ],
    });

    expect(joinLobby).toHaveBeenCalledTimes(1);
  });

  it("does not call joinLobby when isConnected is false", async () => {
    setConnected(false);
    await renderWithRouter(<Layout />, {
      routes: [
        {
          path: "/",
          element: <Layout />,
          children: [{ path: "*", element: <div data-testid="outlet" /> }],
        },
      ],
    });

    expect(joinLobby).not.toHaveBeenCalled();
  });

  it("calls leaveLobby on unmount", async () => {
    const { unmount } = await renderWithRouter(<Layout />, {
      routes: [
        {
          path: "/",
          element: <Layout />,
          children: [{ path: "*", element: <div data-testid="outlet" /> }],
        },
      ],
    });

    unmount();
    expect(leaveLobby).toHaveBeenCalledTimes(1);
  });
});
