/**
 * Main React application with React Router.
 *
 * Layout:
 * - Fixed sidebar on the left (navigation, agent list, new agent button)
 * - Main content area on the right (pages)
 *
 * Routes:
 * - / → RootGate (transitional: checks for a token, attempts
 *         to connect the WS, then redirects to /spaces or
 *         /login depending on outcome)
 * - /spaces → SpacesIndex (the user's spaces)
 * - /spaces/new → NewSpacePage (create new space)
 * - /space/:spaceSlug → SpaceView (the space's Main View: by default its
 *                       note feed, or the blueprint's own page if it names
 *                       one — a campaign space gets `RpgPlayInterface`)
 * - /space/:spaceSlug/agent/:name → ChatPage (chat with agent)
 * - /about → AboutPage (about with mascot)
 * - /login, /register → standalone auth pages (no sidebar)
 * - /invites → InvitesPage (sidebar visible; invite CRUD via
 *              Phoenix Channel, not HTTP)
 *
 * The RootGate pattern exists because the WebSocket
 * connection is the source of truth for "logged in". A user
 * who hits `/` directly (bookmark, refresh, external link)
 * may have a token in `localStorage` but no in-memory
 * `currentUser`. The gate reads the token, opens the
 * connection, and follows the connection's outcome to land
 * the user on the right page: `/spaces` when the handshake
 * lands, `/login` when it fails (issue #95).
 *
 * The failure case is deliberately coarse, and we do NOT clear the token. The
 * browser's WebSocket API does not expose the handshake's HTTP status, so a
 * token the server rejected and a server we could not reach are
 * indistinguishable to us — Phoenix reports both as a bare error event plus a
 * `1006` close. Landing on `/login` beats stranding the user on a spinner, and
 * keeping the token means a refresh recovers if the server was only briefly
 * unreachable. The login page says why it is being shown.
 */

import { useEffect, useRef } from "react";
import {
  BrowserRouter,
  Routes,
  Route,
  Outlet,
  useNavigate,
} from "react-router-dom";
import { useStore } from "./store";
import { initChannels, joinLobby, leaveLobby } from "./channels";
import { readAuthToken } from "./socket";
import { useDocumentTitle } from "./hooks/useDocumentTitle";
import { Sidebar } from "./components/Sidebar";
import { ChatPage } from "./pages/ChatPage";
import { SpaceView } from "./pages/SpaceView";
import { NewSpacePage } from "./pages/NewSpacePage";
import { SpacesIndex } from "./pages/SpacesIndex";
import { AboutPage } from "./pages/AboutPage";
import { LoginPage } from "./pages/LoginPage";
import { RegisterPage } from "./pages/RegisterPage";
import { InvitesPage } from "./pages/InvitesPage";
import { ProvidersPage } from "./pages/ProvidersPage";

/**
 * Transitional route at `/`.
 *
 * On mount:
 *  - If there's no token in `localStorage`, redirect to
 *    `/login` immediately — no point dialing `/socket`.
 *  - Otherwise, call `initChannels()` which connects the
 *    socket. The connection's outcome is reflected in the
 *    `isConnected` and `connectionFailed` store flags.
 *
 * On `isConnected` becoming true (i.e. the server accepted
 * our token), navigate to `/spaces`. The user is now in
 * an authenticated session.
 *
 * On `connectionFailed` becoming true, navigate to `/login`.
 * This replaces the old "stay on the loading screen"
 * behaviour (issue #95): a spinner that never resolves tells
 * the user nothing and offers no way forward. We add no
 * timeout of our own — the socket's own close or error is the
 * event, not elapsed time — and we do not clear the token,
 * because a rejected token and an unreachable server cannot be
 * told apart (see the module doc).
 */
function RootGate() {
  const navigate = useNavigate();
  const isConnected = useStore((s) => s.isConnected);
  const connectionFailed = useStore((s) => s.connectionFailed);

  // No page-specific parts yet: the tab just names the host.
  useDocumentTitle([]);

  // We use a ref to capture `navigate` so the mount-once
  // effect can stay dependency-free. `navigate` is a stable
  // function reference from react-router and doesn't need
  // to be in the dep list.
  const navigateRef = useRef(navigate);
  navigateRef.current = navigate;

  useEffect(() => {
    if (!readAuthToken()) {
      navigateRef.current("/login", { replace: true });
      return;
    }
    initChannels();
  }, []);

  useEffect(() => {
    if (isConnected) {
      navigate("/spaces", { replace: true });
    }
  }, [isConnected, navigate]);

  // A dial that closed or errored without connecting. `isConnected` cannot
  // express this on its own — it is also `false` before the handshake lands —
  // so the two are separate flags, and they are mutually exclusive because
  // `initChannels` clears this one on open.
  useEffect(() => {
    if (connectionFailed) {
      navigate("/login", { replace: true });
    }
  }, [connectionFailed, navigate]);

  return (
    <div className="flex h-screen items-center justify-center bg-gray-50">
      <div className="text-sm text-gray-500">Loading…</div>
    </div>
  );
}

/**
 * Layout component with sidebar and main content.
 *
 * Mounts only for authenticated routes (`/spaces`, `/space/:slug`,
 * `/space/:slug/agent/:name`, `/about`, `/invites`). The WS
 * connection is established via `initChannels` and the lobby is joined
 * once `isConnected` flips true.
 *
 * This is the second of the two `initChannels` call sites (`RootGate` is the
 * other, and a direct hit on `/spaces` — a bookmark — mounts only this one).
 * `initChannels` is idempotent, so neither ordering stacks a second set of
 * socket handlers; see its doc.
 */
function Layout() {
  const isConnected = useStore((state) => state.isConnected);

  useEffect(() => {
    initChannels();
  }, []);

  useEffect(() => {
    if (isConnected) {
      joinLobby();
    }
  }, [isConnected]);

  useEffect(() => {
    return () => {
      leaveLobby();
    };
  }, []);

  return (
    <div className="flex h-screen bg-gray-50">
      <Sidebar />
      <main className="flex-1 overflow-auto p-6">
        <Outlet />
      </main>
    </div>
  );
}

/**
 * Main App component. Uses `<BrowserRouter>` + `<Routes>`
 * + `<Route>` directly — no data API (`createBrowserRouter`
 * / `RouterProvider`). URL is parsed by react-router;
 * everything else (state, data fetching, side effects)
 * lives in Zustand + Phoenix Channels.
 */
export function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/login" element={<LoginPage />} />
        <Route path="/register" element={<RegisterPage />} />
        <Route path="/" element={<RootGate />} />
        <Route path="/" element={<Layout />}>
          <Route path="spaces" element={<SpacesIndex />} />
          <Route path="spaces/new" element={<NewSpacePage />} />
          <Route path="space/:spaceSlug" element={<SpaceView />} />
          <Route path="space/:spaceSlug/agent/:name" element={<ChatPage />} />
          <Route path="about" element={<AboutPage />} />
          <Route path="invites" element={<InvitesPage />} />
          <Route path="providers" element={<ProvidersPage />} />
        </Route>
      </Routes>
    </BrowserRouter>
  );
}

export { RootGate, Layout };

export default App;
