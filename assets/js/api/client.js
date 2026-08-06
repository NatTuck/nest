/**
 * Tiny wrapper around `fetch` that:
 *
 *   - Injects `Authorization: Bearer <token>` when a token is
 *     present in `localStorage` under the key `nest_token`.
 *   - Serializes JSON bodies and sets `Content-Type` when
 *     given an object.
 *   - Surfaces server JSON error responses by throwing
 *     `ApiError` so callers can `catch` and render toasts.
 *
 * The HTTP paths (`/api/v1/...`) live next to the WS server
 * but use header auth instead of socket params. The CSRF
 * token is irrelevant on these endpoints because they
 * accept Bearer tokens, not cookie sessions.
 */

const TOKEN_KEY = "nest_token";

export const TOKEN_STORAGE_KEY = TOKEN_KEY;

export function getStoredToken() {
  try {
    return localStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

export function setStoredToken(token) {
  try {
    localStorage.setItem(TOKEN_KEY, token);
  } catch {
    // localStorage may be disabled (private mode); we still
    // continue in-memory so the API call succeeds this tab.
  }
}

export function clearStoredToken() {
  try {
    localStorage.removeItem(TOKEN_KEY);
  } catch {
    // ignore
  }
}

export class ApiError extends Error {
  constructor(status, body) {
    const message =
      typeof body === "object" && body !== null && "error" in body
        ? String(body.error)
        : `HTTP ${status}`;
    super(message);
    this.status = status;
    this.body = body;
  }
}

/**
 * Issue a JSON request to the API. Returns the parsed JSON
 * response on a 2xx status. Throws `ApiError` otherwise so
 * callers can `try { … } catch (err) { … }` uniformly.
 */
export async function apiFetch(path, opts = {}) {
  const { method = "GET", body, headers = {}, token } = opts;

  const finalHeaders = {
    Accept: "application/json",
    ...headers,
  };

  const authToken = token ?? getStoredToken();
  if (authToken) {
    finalHeaders.Authorization = `Bearer ${authToken}`;
  }

  let payload;
  if (body !== undefined) {
    finalHeaders["Content-Type"] = "application/json";
    payload = JSON.stringify(body);
  }

  const response = await fetch(path, {
    method,
    headers: finalHeaders,
    body: payload,
    credentials: "same-origin",
  });

  let parsed = null;
  const text = await response.text();

  if (text) {
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = text;
    }
  }

  if (!response.ok) {
    throw new ApiError(response.status, parsed);
  }

  return parsed;
}
