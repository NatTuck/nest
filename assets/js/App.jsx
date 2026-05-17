/**
 * Main React application with React Router.
 *
 * Layout:
 * - Fixed sidebar on the left (navigation, agent list, new agent button)
 * - Main content area on the right (pages)
 *
 * Routes:
 * - / → NewAgentPage (create new agent)
 * - /agent/:id → ChatPage (chat with agent)
 * - /about → AboutPage (about with mascot)
 */

import { useEffect } from "react";
import {
  createBrowserRouter,
  RouterProvider,
  Outlet,
  Navigate,
} from "react-router-dom";
import { useStore } from "./store";
import { initChannels, joinLobby, leaveLobby } from "./channels";
import { Sidebar } from "./components/Sidebar";
import { NewAgentPage } from "./pages/NewAgentPage";
import { ChatPage } from "./pages/ChatPage";
import { AboutPage } from "./pages/AboutPage";

/**
 * Layout component with sidebar and main content
 */
function Layout() {
  const isConnected = useStore((state) => state.isConnected);

  useEffect(() => {
    // Initialize channels
    initChannels();
  }, []);

  useEffect(() => {
    // Join lobby when socket connects
    if (isConnected) {
      joinLobby();
    }
  }, [isConnected]);

  useEffect(() => {
    // Cleanup on unmount
    return () => {
      leaveLobby();
    };
  }, []);

  return (
    <div className="flex h-screen bg-gray-50">
      {/* Sidebar */}
      <Sidebar />

      {/* Main content */}
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
    path: "/",
    element: <Layout />,
    children: [
      {
        index: true,
        element: <NewAgentPage />,
      },
      {
        path: "agent/:id",
        element: <ChatPage />,
      },
      {
        path: "about",
        element: <AboutPage />,
      },
      {
        path: "*",
        element: <Navigate to="/" replace />,
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

export default App;
