/**
 * RegisterPage — username + password + invite token.
 *
 * Reads the `?token=…` query string. The token is either
 * a real invite (from a friend or family member) or the
 * magic `"first-user"` token the server accepts only when
 * the users table is empty. The bootstrap path lands here
 * via the `PageController.home/2` redirect.
 *
 * On successful registration we navigate to `/spaces`.
 * The WS connection establishes when that route mounts.
 *
 * Login/register pages intentionally don't check
 * `currentUser` or `isConnected` to bounce already-authed
 * users: if you landed here, you wanted to log in or
 * register.
 */

import { useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";

import { ApiError } from "../api/client";
import { register } from "../api/auth";

export function RegisterPage() {
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();

  const initialToken = searchParams.get("token") ?? "";
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [token] = useState(initialToken);
  const [error, setError] = useState(null);
  const [submitting, setSubmitting] = useState(false);

  async function handleSubmit(e) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);

    try {
      await register({ username, password, token });
      navigate("/spaces", { replace: true });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Registration failed");
      setSubmitting(false);
    }
  }

  const usingBootstrap = token === "first-user";

  return (
    <div className="flex h-screen items-center justify-center bg-gray-50">
      <form
        onSubmit={handleSubmit}
        className="w-full max-w-sm rounded-lg bg-white p-6 shadow-md"
      >
        <h1 className="mb-1 text-xl font-semibold text-gray-900">
          {usingBootstrap ? "Create the first admin" : "Create an account"}
        </h1>
        <p className="mb-4 text-sm text-gray-600">
          {usingBootstrap
            ? "Pick a username and password — you'll be the first admin."
            : "Use the invite token someone sent you."}
        </p>

        {!usingBootstrap ? (
          <label className="mb-3 block">
            <span className="text-sm text-gray-700">Invite token</span>
            <input
              type="text"
              value={token}
              readOnly
              className="mt-1 block w-full rounded border border-gray-200 bg-gray-50 px-3 py-2 font-mono text-xs text-gray-700"
            />
          </label>
        ) : null}

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
            autoComplete="new-password"
            required
            minLength={8}
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
          disabled={submitting || !token}
          className="w-full rounded bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
        >
          {submitting ? "Creating account…" : "Create account"}
        </button>

        <p className="mt-4 text-center text-xs text-gray-500">
          Already have an account?{" "}
          <a className="text-blue-600 hover:underline" href="/login">
            Sign in
          </a>
        </p>
      </form>
    </div>
  );
}

export default RegisterPage;
