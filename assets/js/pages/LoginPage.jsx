/**
 * LoginPage — username + password sign-in form.
 *
 * On success, the API helper stores the auth token in
 * `localStorage` and we route to `/spaces`. The WS
 * connection is then established when the destination
 * route mounts, and the lobby's `init` payload populates
 * `useAuthStore.currentUser`. On failure we render the
 * server's error string as an inline form error.
 *
 * Login/register pages intentionally don't check
 * `currentUser` or `isConnected` to bounce already-authed
 * users: if you landed here, you wanted to log in or
 * register. The RootGate at `/` handles "you had a token
 * but the connection failed" by staying on its loading
 * screen; logout's destination is explicitly `/login`, so
 * a re-login flow is always reachable.
 */

import { useState } from "react";
import { useNavigate } from "react-router-dom";

import { ApiError } from "../api/client";
import { login } from "../api/auth";

export function LoginPage() {
  const navigate = useNavigate();

  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState(null);
  const [submitting, setSubmitting] = useState(false);

  async function handleSubmit(e) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);

    try {
      await login(username, password);
      navigate("/spaces", { replace: true });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Login failed");
      setSubmitting(false);
    }
  }

  return (
    <div className="flex h-screen items-center justify-center bg-gray-50">
      <form
        onSubmit={handleSubmit}
        className="w-full max-w-sm rounded-lg bg-white p-6 shadow-md"
      >
        <h1 className="mb-4 text-xl font-semibold text-gray-900">Sign in</h1>

        <label className="mb-3 block">
          <span className="text-sm text-gray-700">Username</span>
          <input
            type="text"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            autoComplete="username"
            required
            className="mt-1 block w-full rounded border border-gray-300 px-3 py-2 text-gray-900 outline-none focus:border-blue-500"
          />
        </label>

        <label className="mb-4 block">
          <span className="text-sm text-gray-700">Password</span>
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="current-password"
            required
            className="mt-1 block w-full rounded border border-gray-300 px-3 py-2 text-gray-900 outline-none focus:border-blue-500"
          />
        </label>

        {error ? (
          <p className="mb-3 rounded bg-red-50 px-3 py-2 text-sm text-red-700">
            {error}
          </p>
        ) : null}

        <button
          type="submit"
          disabled={submitting}
          className="w-full rounded bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
        >
          {submitting ? "Signing in…" : "Sign in"}
        </button>

        <p className="mt-4 text-center text-xs text-gray-500">
          New here?{" "}
          <a className="text-blue-600 hover:underline" href="/register">
            Register
          </a>
        </p>
      </form>
    </div>
  );
}

export default LoginPage;
