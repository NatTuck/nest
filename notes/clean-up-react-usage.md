# Clean Up React Usage — Plan

## Goal

Eliminate the architectural mismatch between Phoenix Channels + Zustand + React Router v7 by:

1. Moving invite CRUD from HTTP REST to Phoenix Channels (invites are channel events, not data fetches).
2. Replacing the React Router v7 data API (`createBrowserRouter` + `RouterProvider` in production; `createMemoryRouter` + `RouterProvider` in tests) with `<BrowserRouter>` / `<MemoryRouter>` + `<Routes>` + `<Route>`. No data API.
3. Consolidating `useAuthStore` into the single `useStore`.
4. Removing HTTP `logout` (server no-op; token lives on client).
5. Letting `InvitesPage` become a pure renderer reading from `useStore`, eliminating the component-fetches-in-`useEffect` pattern that causes `act` warnings.
6. Letting `LoginPage` / `RegisterPage` keep their transient form state in `useState` (per-page, ephemeral), fixing test-side `act` warnings with the `createDeferred` pattern.
7. Resetting the whole `useStore` on logout so a new session starts clean.

## Architecture after this change

| Layer | Owns | Forbidden |
|---|---|---|
| Phoenix Channels | Wire: push events into Zustand; receive pushes from UI | `useState`, `useEffect` async fetch |
| Zustand (`useStore`) | All app state: auth, agents, messages, invites, connection | Async logic inside store (keep in services) |
| React | Render Zustand state + URL params | `useLoaderData`, `useEffect` fetch, component state for server data |
| React Router | URL → component mapping only | `clientLoader`, `clientAction`, `<Form>`, `RouterProvider`, `createBrowserRouter`, `createMemoryRouter` |

## File-by-file change list

### Backend (Elixir)

1. **Create `lib/nest_web/invite_json.ex`** with `public_invite/1`:
   - Includes `token` (plaintext) so the user can always see tokens they created.
   - Used by the lobby channel; not by the deleted HTTP controller.
   ```elixir
   defmodule NestWeb.InviteJSON do
     def public_invite(invite) do
       %{
         id: invite.id,
         created_by_user_id: invite.created_by_user_id,
         token: invite.token,
         expires_at: invite.expires_at,
         used_by_user_id: invite.used_by_user_id,
         used_at: invite.used_at,
         revoked_at: invite.revoked_at,
         inserted_at: invite.inserted_at
       }
     end
   end
   ```

2. **Edit `lib/nest/accounts.ex`**:
   - Add `count_user_invites/1`:
     ```elixir
     def count_user_invites(user_id) when is_integer(user_id) do
       from(i in InviteSchema, where: i.created_by_user_id == ^user_id)
       |> Repo.aggregate(:count, :id)
     end
     ```
   - Update `create_invite/1` to enforce the 10-invite limit:
     ```elixir
     def create_invite(user_id) when is_integer(user_id) do
       if count_user_invites(user_id) >= 10 do
         {:error, :too_many_invites}
       else
         token = generate_token()
         expires_at =
           DateTime.utc_now()
           |> DateTime.add(@invite_ttl_seconds, :second)
           |> DateTime.truncate(:second)

         %InviteSchema{}
         |> InviteSchema.new_changeset(%{
           token: token,
           created_by_user_id: user_id,
           expires_at: expires_at
         })
         |> Repo.insert()
         |> case do
           {:ok, invite} -> {:ok, invite, token}
           {:error, cs} -> {:error, cs}
         end
       end
     end
     ```
   - `redeem_invite/2` is unchanged. The `token` column has always stored plaintext (no hash was ever applied); redemption does `Repo.get_by(InviteSchema, token: token)`, which is a direct string match.

3. **Edit `lib/nest_web/channels/lobby_channel.ex`**:
   - Add `invites` to the `init` push payload:
     ```elixir
     push(socket, "init", %{
       agents: agents,
       broken_agents: [],
       models: models,
       vocations: vocations,
       current_user: public_current_user(user),
       invites:
         Accounts.list_user_invites(user.id)
         |> Enum.map(&NestWeb.InviteJSON.public_invite/1)
     })
     ```
   - Add `handle_in("create_invite", _payload, socket)`:
     ```elixir
     def handle_in("create_invite", _payload, socket) do
       user = socket.assigns.current_user

       case Accounts.create_invite(user.id) do
         {:ok, invite, _token} ->
           public = NestWeb.InviteJSON.public_invite(invite)
           push(socket, "invite:created", public)
           {:reply, {:ok, public}, socket}

         {:error, :too_many_invites} ->
           {:reply, {:error, %{error: "too_many_invites"}}, socket}

         {:error, _cs} ->
           {:reply, {:error, %{error: "failed_to_create_invite"}}, socket}
       end
     end
     ```
   - Add `handle_in("revoke_invite", %{"id" => id}, socket)`:
     ```elixir
     def handle_in("revoke_invite", %{"id" => id}, socket) do
       user = socket.assigns.current_user

       with {int_id, _} <- Integer.parse(id),
            :ok <- Accounts.revoke_invite(int_id, user.id) do
         push(socket, "invite:revoked", %{id: int_id})
         {:reply, :ok, socket}
       else
         {:error, reason} ->
           {:reply, {:error, %{error: Atom.to_string(reason)}}, socket}

         :error ->
           {:reply, {:error, %{error: "invalid_id"}}, socket}
       end
     end
     ```

4. **Delete `lib/nest_web/controllers/invite_controller.ex`** entirely. The file is 105 lines; no other code imports from it (the lobby channel now uses `InviteJSON`).

5. **Edit `lib/nest_web/controllers/auth_controller.ex`**:
   - Delete `def logout(conn, _params)` (lines ~166-171). The server has no session to clear; the client owns the token.

6. **Edit `lib/nest_web/router.ex`**:
   - Remove `post "/logout", AuthController, :logout` from the `/api/v1` scope.
   - Remove the entire `/api/v1` scope with `/invites`, `/invites/:id` routes.
   - The `login` and `register` endpoints remain (they're real session-establishment operations).

### Frontend — store consolidation

7. **Edit `assets/js/store/index.js`**:
   - Merge `useAuthStore` content: add `currentUser: null` to initial state.
   - Add actions:
     - `setCurrentUser: (user) => set({ currentUser: user })`.
     - `logout: () => set({ currentUser: null, agents: [], agentsCache: {}, currentMode: null, messages: [], partial: null, isConnected: false, invites: [], invitesError: null, …all top-level fields cleared })`.
   - Add invite fields to initial state: `invites: []`, `invitesError: null`.
   - Add invite actions:
     - `setInvites: (invites) => set({ invites })`.
     - `setInvitesError: (error) => set({ invitesError: error })`.
   - Update `_reset` to call `logout()` (which is the comprehensive reset). All test setups that rely on `_reset` continue to work; tests will need to call `_reset()` after logging out via the API.

8. **Delete `assets/js/store/auth.js`**.

9. **Grep `assets/js` for `useAuthStore`** and update each consumer to import `currentUser` / `setCurrentUser` from `useStore` instead.
   - Likely files: `Sidebar.jsx`, possibly `RootGate`-related code in `App.jsx`, the `currentUserBar` section.

### Frontend — channels

10. **Edit `assets/js/channels.js`**:
    - Find the existing `lobbyChannel.on("init", ...)` handler (handles `agentId` for now). Add `if (payload.invites) useStore.getState().setInvites(payload.invites);`.
    - Add `lobbyChannel.on("invite:created", (invite) => { useStore.getState().setInvites([invite, ...useStore.getState().invites]); });`.
    - Add `lobbyChannel.on("invite:revoked", (payload) => { useStore.getState().setInvites(useStore.getState().invites.filter((i) => i.id !== payload.id)); });`.
    - Add `export function createInvite()` — pushes `"create_invite"`, on `error` reply sets `invitesError` in store:
      ```js
      export function createInvite() {
        lobbyChannel
          .push("create_invite", {})
          .receive("error", (err) => {
            useStore.getState().setInvitesError(err?.error || "Failed to create invite");
          });
      }
      ```
    - Add `export function revokeInvite(id)`:
      ```js
      export function revokeInvite(id) {
        lobbyChannel
          .push("revoke_invite", { id })
          .receive("error", (err) => {
            useStore.getState().setInvitesError(err?.error || "Failed to revoke invite");
          });
      }
      ```
    - Delete the `logout()` HTTP call (was `import { logout } from "../api/auth"`). No replacement; logout is now pure client-side cleanup.

### Frontend — components

11. **Rewrite `assets/js/pages/InvitesPage.jsx`** as a pure renderer:
    - Remove `useState` (invites, loading, error, freshToken). Remove `useEffect`.
    - Import `createInvite`, `revokeInvite` from `../channels` (not from `../api/invites`).
    - Read `invites`, `invitesError`, `isConnected` from `useStore`.
    - Render the invite list with a `token` column visible for every row.
    - Add a `CopyButton` next to each token (reuse `assets/js/components/CopyButton.jsx`).
    - `handleCreate` → `setInvitesError(null)` then `createInvite()`.
    - `handleRevoke(id)` → `revokeInvite(id)`.
    - Render invite creation/revocation errors inline via `invitesError`.
    - "bounces to /login when the WS is not connected" via `<Navigate>` if `!isConnected`.

12. **Rewrite `assets/js/components/Sidebar.jsx`**:
    - Replace `import { logout } from "../api/auth";` — delete that import.
    - In `handleLogout`:
      ```js
      async function handleLogout() {
        const sock = window.__nest_socket;
        if (sock && typeof sock.disconnect === "function") {
          sock.disconnect();
        }
        useStore.getState().logout();
      }
      ```
    - Remove `await logout()` and `setCurrentUser(null)`. `logout()` is now the comprehensive store action.
    - Update `useStore.getState().currentUser` references to read from the merged store.
    - Update `setCurrentUser` references to use the store action.

### Frontend — production routing

13. **Edit `assets/js/App.jsx`**:
    - Replace `createBrowserRouter` + `RouterProvider` with `<BrowserRouter>` + `<Routes>` + `<Route>`.
    - Match the test-side structure: `<BrowserRouter><Routes><Route path="..." element={...} /></Routes></BrowserRouter>`.
    - Remove the `router` constant and the `createBrowserRouter` import.
    - The component tree (`RootGate`, `Layout`, all pages) stays the same.

### Frontend — test helper

14. **Edit `assets/js/test/render_with_router.jsx`** to use `<MemoryRouter>` + `<Routes>` + `<Route>`:
    ```jsx
    import { render } from "@testing-library/react";
    import { MemoryRouter, Routes, Route } from "react-router-dom";

    export function renderWithRouter(
      ui,
      { route = "/", routes, ...renderOptions } = {},
    ) {
      const resolvedRoutes = routes ?? [{ path: "*", element: ui }];
      return render(
        <MemoryRouter initialEntries={[route]}>
          <Routes>
            {resolvedRoutes.map((r) => (
              <Route key={r.path} path={r.path} element={r.element} />
            ))}
          </Routes>
        </MemoryRouter>,
        renderOptions,
      );
    }
    ```

### Frontend — tests

15. **Rewrite `assets/js/pages/InvitesPage.test.jsx`**:
    - All tests use store-driven state: `useStore.getState().setInvites([...])`, `setInvitesError(...)`, `setIsConnected(true | false)`.
    - Mock `../channels` with `vi.fn()` for `createInvite` and `revokeInvite`. Delete HTTP mock.
    - Click handlers assert the mock was called with the right args.
    - No deferred promises, no `act` flushes (component has no async effects).
    - Test cases:
      - "bounces to /login when the WS is not connected"
      - "renders the empty state when there are no invites"
      - "renders the populated table with status badges and formatted dates"
      - "renders the token column for every invite"
      - "calls createInvite when the create button is clicked"
      - "calls revokeInvite with the invite id when the revoke button is clicked"
      - "surfaces a 'too_many_invites' error when createInvite returns that"

16. **Edit `assets/js/pages/LoginPage.test.jsx`**:
    - For the "Signing in…" test, use `createDeferred`:
      ```js
      import { createDeferred } from "../test/create_deferred";

      it("shows a 'Signing in…' label while the request is in flight", async () => {
        const deferred = createDeferred();
        login.mockReturnValueOnce(deferred.promise);
        renderPage();

        fireEvent.change(screen.getByLabelText(/username/i), { target: { value: "alice" } });
        fireEvent.change(screen.getByLabelText(/password/i), { target: { value: "x" } });
        fireEvent.click(screen.getByRole("button", { name: /sign in/i }));

        await act(async () => {
          deferred.resolve({ token: "t", user: {} });
          await deferred.promise;
          await new Promise((r) => setTimeout(r, 0));
        });

        expect(screen.getByRole("button", { name: /signing in/i })).toBeDisabled();
      });
      ```
    - Other LoginPage tests stay the same (no warnings today).

17. **Edit `assets/js/pages/RegisterPage.test.jsx`**:
    - Same pattern for "Creating account…" test.

18. **Verify `assets/js/App.test.jsx`** Layout tests pass with the new `renderWithRouter`. If they still warn:
    - Switch Layout tests to use `<MemoryRouter>` directly (no helper):
      ```jsx
      render(
        <MemoryRouter>
          <Layout />
        </MemoryRouter>,
      );
      ```
    - If `<Outlet />` causes warnings, add an empty `act` flush after `render`.

### Frontend — file deletions

19. **Delete `assets/js/api/invites.js`** and `assets/js/api/invites.test.js`.
20. **Edit `assets/js/api/auth.js`**: delete the `logout()` function. Keep `login()` and `register()`.
21. **Edit `assets/js/api/auth.test.js`**: delete `logout` tests. Keep `login` / `register` tests.

## Risks and open issues

- **`App.jsx` migration to `<BrowserRouter>`** is a structural change. The current `createBrowserRouter` config may have features (loaders, future data flow) that the simple `<BrowserRouter>` version doesn't support. Since this codebase doesn't currently use any of those features (the data API is unused in production code), the migration should be safe. Verification: load `/new_agent`, `/agent/:name`, `/about`, `/invites` and confirm routing works.

- **`useStore.logout()` reset scope**: must clear every top-level field. Missing a field means stale data after logout. I'll grep for all top-level fields in `useStore` before writing the reset action.

- **`copyButton` next to token** reuses `assets/js/components/CopyButton.jsx`. Need to verify the existing `CopyButton` accepts an arbitrary string to copy (not tied to a specific content type).

- **Backend `count_user_invites` query** — I need to verify the alias `from` is in scope at the call site. If not, add `import Ecto.Query, only: [from: 1, ...]` or similar.

- **The "App default export" test** in `App.test.jsx` renders `<App />` which now uses `<BrowserRouter>` internally. The test should continue to work.

- **Migrations**: the `invites.token` column already exists and stores plaintext. No schema migration needed. The `count_user_invites` query uses the existing schema.

## Verification steps (after all changes)

1. `mix precommit` — backend changes, Elixir tests, credo, format.
2. `pnpm vitest run --no-color --reporter=verbose > /tmp/vitest-final.log 2>&1` — JS tests. Grep `^stderr |` to count warnings.
3. Manual smoke: load each route (`/`, `/login`, `/register`, `/new_agent`, `/agent/foo`, `/about`, `/invites`) and verify routing, login, register, invite list/create/revoke, logout.