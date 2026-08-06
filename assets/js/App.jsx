/**
 * Main React application with React Router.
 *
 * Layout:
 * - Fixed sidebar on the left (navigation, agent list, new agent button)
 * - Main content area on the right (pages)
 *
 * Routes:
 * - / → RootGate (transitional: checks for a token, attempts
 *         to connect the WS, then redirects to /new_agent or
 *         /login depending on outcome)
 * - /new_agent → NewAgentPage (create new agent; sidebar visible)
 * - /agent/:name → ChatPage (chat with agent)
 * - /about → AboutPage (about with mascot)
 * - /login, /register → standalone auth pages (no sidebar)
 *
 * The RootGate pattern exists because the WebSocket
 * connection is the source of truth for "logged in". A user
 * who hits `/` directly (bookmark, refresh, external link)
 * may have a token in `localStorage` but no in-memory
 * `currentUser`. The gate reads the token, opens the
 * connection, and follows the connection's outcome to land
 * the user on the right page. If the connect fails, the
 * gate stays in a loading state — the user can refresh or
 * navigate manually; we don't clear their token or pretend
 * to know it's invalid (only the server can reject).
 */

import { useEffect, useRef } from "react";
import {
  createBrowserRouter,
  RouterProvider,
  Outlet,
  useNavigate,
} from "react-router-dom";
import { useStore } from "./store";
import { initChannels, joinLobby, leaveLobby } from "./channels";
import { readAuthToken } from "./socket";
import { Sidebar } from "./components/Sidebar";
import { NewAgentPage } from "./pages/NewAgentPage";
import { ChatPage } from "./pages/ChatPage";
import { AboutPage } from "./pages/AboutPage";
import { LoginPage } from "./pages/LoginPage";
import { RegisterPage } from "./pages/RegisterPage";
import { InvitesPage } from "./pages/InvitesPage";

/**
 * Transitional route at `/`.
 *
 * On mount:
 *  - If there's no token in `localStorage`, redirect to
 *    `/login` immediately — no point dialing `/socket`.
 *  - Otherwise, call `initChannels()` which connects the
 *    socket. The connection's success is reflected in the
 *    `isConnected` store flag.
 *
 * On `isConnected` becoming true (i.e. the server accepted
 * our token), navigate to `/new_agent`. The user is now in
 * an authenticated session.
 *
 * We intentionally do NOT add a timeout: a stale or
 * rejected token is the server's problem to detect, not the
 * client's to pre-empt. If the WS can't connect, the user
 * stays on the loading screen and can refresh or navigate
 * manually.
 */
function RootGate() {
  const navigate = useNavigate();
  const isConnected = useStore((s) => s.isConnected);

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
      navigate("/new_agent", { replace: true });
    }
  }, [isConnected, navigate]);

  return (
    <div className="flex h-screen items-center justify-center bg-gray-50">
      <div className="text-sm text-gray-500">Loading…</div>
    </div>
  );
}

/**
 * Layout component with sidebar and main content.
 *
 * Mounts only for authenticated routes (`/new_agent`,
 * `/agent/:name`, `/about`, `/invites`). The WS connection
 * is established via `initChannels` and the lobby is joined
 * once `isConnected` flips true.
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
 * Router configuration
 */
const router = createBrowserRouter([
  {
    path: "/login",
    element: <LoginPage />,
  },
  {
    path: "/register",
    element: <RegisterPage />,
  },
  {
    path: "/",
    element: <RootGate />,
  },
  {
    path: "/",
    element: <Layout />,
    children: [
      {
        path: "new_agent",
        element: <NewAgentPage />,
      },
      {
        path: "agent/:name",
        element: <ChatPage />,
      },
      {
        path: "about",
        element: <AboutPage />,
      },
      {
        path: "invites",
        element: <InvitesPage />,
      },
    ],
  },
]);

/**
 * Main App component
 */
export function App() {
  return <RouterProvider router={router} />;
}

export { RootGate, Layout };

export default App;
