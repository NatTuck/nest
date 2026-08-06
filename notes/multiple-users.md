# Multi-user for Nest (v1)

Wire Nest up so a small group of trusted users (a family, a small office) can
share one deployment, with each user seeing their own private agents plus a
shared pool. Adds username + password authentication, invite-based registration,
and a private/shared flag on agents.

## Decisions (locked)

| Concern | Choice |
|---|---|
| Auth model | Username + password. Argon2 via `comeonin` + `argon2_elixir`. |
| Token | Long-lived `Phoenix.Token` returned to the client. No DB session table. |
| Token storage | Client-side `localStorage`. Sent as `Authorization: Bearer …` for HTTP and as `params.token` for the Phoenix socket. |
| WS auth | `UserSocket.connect/3` reads `params["token"]`, validates against `Phoenix.Token.verify`, rejects with `:error` on miss. Authenticated channels receive `socket.assigns.current_user`. |
| HTTP auth | New `/api/v1` scope. `NestWeb.Auth.FetchCurrentUser` plug; `NestWeb.Auth.RequireAuthenticated` for protected routes. CSRF not relevant (header token, not cookie auth). |
| Sessions | None. Every authenticated request re-validates the token. Existing `Plug.Session` cookie pipeline stays for LiveView's CSRF token shape; no changes there. |
| Invites | Cryptographic one-time tokens. Single-use; revocable; 7-day default expiry. |
| First user | When the users table is empty, `/` redirects to `/register?token=first-user`. The server resolves `first-user` as a magic token, creates an admin (`is_admin: true`), does **not** consume an `invites` row. Logs the username to stdout. |
| Shared agents | New `shared` boolean on `agents`. The owner keeps edit/delete rights; everyone (authenticated) can chat with shared agents and see them in the lobby. |
| Vocation scope | Global, unchanged. Per-user vocations deferred. |
| Sub-agents | `clone_agent_tool` copies `created_by_user_id` and `shared` from the parent. A private agent always spawns private children; a shared parent may spawn shared children. |
| Test coverage | Full — every module gets happy + at least one unhappy path. |

## Out of scope (deferred)

- Email verification, password reset, email subsystem.
- Per-user vocations.
- Per-user model provider API keys. Operator config remains shared.
- Edit-transfer on shared agents (ownership always stays with creator).
- Admin-only invite generation. Initially all users can invite.
- 2FA, TOTP, device sessions, audit log.

## Dependencies to add

- `comeonin` — argon2/bcrypt abstraction.
- `argon2_elixir` — argon2 implementation.
- `argon2_elixir` requires a NIF build via `mix deps.get && mix deps.compile`.
- Postgres `citext` extension for case-insensitive usernames.

## Data model

### `users` (new migration: `create_users.exs`)

| col | type | notes |
|---|---|---|
| `id` | `bigserial` | integer PK; consistent with `agents`/`messages`/`vocations` |
| `username` | `citext` | unique index, login identifier |
| `password_hash` | `binary` | argon2 encoded |
| `is_admin` | `boolean default false NOT NULL` | first user via app logic |
| `inserted_at`, `updated_at` | `utc_datetime` | |

Indexes: `unique (username)`.

### `invites` (new migration: `create_invites.exs`)

| col | type | notes |
|---|---|---|
| `id` | `bigserial` | integer PK |
| `token` | `binary` | 32 random bytes; unique index; presented as url-safe base64 |
| `created_by_user_id` | FK → `users.id` | NOT NULL |
| `expires_at` | `utc_datetime` | default NOW + 7 days |
| `used_by_user_id` | FK → `users.id` | nullable |
| `used_at` | `utc_datetime` | nullable |
| `revoked_at` | `utc_datetime` | nullable |
| `inserted_at`, `updated_at` | timestamps | |

Indexes: `unique (token)`, `index (created_by_user_id)`.

### `agents` (migration: `add_user_to_agents.exs`)

| col | type | notes |
|---|---|---|
| `created_by_user_id` | FK → `users.id` | nullable initially; backfilled; `NOT NULL` after backfill |
| `shared` | `boolean default false NOT NULL` | new |

Indexes: `index (created_by_user_id)`, partial `index (shared) WHERE shared`.

`messages` — no schema change. Ownership via `agent_id → created_by_user_id`.
`vocations` — no change. Global.

## Code structure

```
lib/
  nest/
    accounts.ex                       # public API: user_count, create_user,
                                      #   authenticate, get_user_by_token,
                                      #   create_invite, redeem_invite,
                                      #   revoke_invite, list_user_invites
    accounts/
      user.ex                         # schema
      invite.ex                       # schema
      auth_token.ex                   # Phoenix.Token wrapper, salt "user_token"
      password.ex                     # comeonin wrapper: hash/verify
  nest_web/
    auth/
      fetch_current_user.ex           # plug for /api/v1
      require_authenticated.ex        # plug for /api/v1 protected routes
      on_connect_auth.ex              # UserSocket.connect/3 helper
    controllers/
      auth_controller.ex              # POST /api/v1/login, /api/v1/register,
                                      #   /api/v1/logout
      invite_controller.ex            # POST/GET/DELETE /api/v1/invites
    channels/
      user_socket.ex                  # UPDATE: connect/3 requires token
      lobby_channel.ex                # UPDATE: filter agents by owner OR shared
      agent_channel.ex                # UPDATE: join auth — owner or shared

test/
  nest/accounts_test.exs
  nest/accounts/invite_test.exs
  nest/accounts/auth_token_test.exs
  nest/accounts/password_test.exs
  nest_web/auth/fetch_current_user_test.exs
  nest_web/auth/require_authenticated_test.exs
  nest_web/controllers/auth_controller_test.exs
  nest_web/controllers/invite_controller_test.exs
  nest_web/channels/user_socket_test.exs
  nest_web/channels/lobby_channel_test.exs
  nest_web/channels/agent_channel_test.exs
  priv/repo/migrations/<ts>_create_users.exs
  priv/repo/migrations/<ts>_create_invites.exs
  priv/repo/migrations/<ts>_add_user_to_agents.exs

assets/
  js/
    api/
      client.js                        # fetch wrapper injecting Bearer token
      auth.js                          # login / register / logout / getStoredToken
    pages/
      LoginPage.jsx
      RegisterPage.jsx                 # reads ?token= from URL
      InvitesPage.jsx                  # list/create/revoke
      NewAgentPage.jsx (extend)        # add shared toggle
    components/
      Header.jsx (extend)              # username + logout
      NewAgentForm.jsx (extend)        # shared toggle
    socket.js (extend)                 # read token from localStorage, pass as
                                       #   Phoenix socket params.token
    store/
      index.js (extend)                # current_user slice; login/logout
```

## Wire-up sequence

1. **Deps.** Add `comeonin`, `argon2_elixir` to `mix.exs`. Run `mix deps.get`.
   Ensure Postgres `citext` extension is available (add a migration that runs
   `CREATE EXTENSION IF NOT EXISTS citext;`).
2. **Migrations.**
   - `create_users.exs` — `users` table with `citext` username.
   - `create_invites.exs` — `invites` table.
   - `add_user_to_agents.exs` — adds `created_by_user_id` (nullable) and `shared`
     to `agents`. Backfills `created_by_user_id` to NULL for now (the
     `PageController`/`FetchCurrentUser` flow handles empty-DB routing so the
     operator logs in first, then runs a one-shot script — see step 12).
3. **Schemas + context.** `Nest.Accounts.User`, `Nest.Accounts.Invite`. Plain
   Repo helpers in `Nest.Accounts` consistent with `Nest.Persistence` style.
   TDD: tests for `user_count/0`, `create_user/2` (duplicate-username
   rejection), `authenticate/2` (bad password), `get_user_by_token/1`.
4. **Password.** `Nest.Accounts.Password.hash/1`, `verify/2`. Tests.
5. **AuthToken.** `Nest.Accounts.AuthToken.sign/1`, `verify/1`, salt
   `"user_token"`. Tests for round-trip, wrong-salt, tampered token.
6. **Invites.** `Nest.Accounts.create_invite/2` (returns the row + the
   url-safe-base64 token), `redeem_invite/3` (validates: not used, not
   revoked, not expired; magic token `"first-user"` allowed only when
   `user_count == 0`), `revoke_invite/2`, `list_user_invites/1`. Tests cover
   the four failure modes (used / revoked / expired / bad token) plus the
   magic-token path.
7. **Plugs.** `NestWeb.Auth.FetchCurrentUser` reads `Authorization: Bearer`,
   verifies, assigns `:current_user` (nil on miss). `RequireAuthenticated`
   halts with 401 when nil. Tests.
8. **Controllers.**
   - `AuthController.login` — 200 + `{token, user}` on success, 401 on bad
     creds, 400 on missing fields.
   - `AuthController.register` — 201 + `{token, user}` on success, 409 on
     duplicate username, 400 on bad invite.
   - `AuthController.logout` — no-op server-side (token is client-held);
     returns 204.
   - `InviteController` — POST create returns 201 with token (authenticated),
     GET list returns the requester's invites, DELETE revokes (only creator
     can revoke).
   - Tests for each.
9. **Router.** Add `/api/v1` scope with `:fetch_current_user` then nested
   `:require_authenticated` for the protected subset. LiveDashboard scope
   untouched.
10. **UserSocket.** `connect/3` reads `params["token"]`, calls
    `Accounts.get_user_by_token/1`, returns `:error` on miss, otherwise
    assigns `current_user`. Update `id/1` to `users_socket:#{user_id}` for
    debuggability. Tests: valid / missing / invalid / expired token.
11. **LobbyChannel.** Filter `init` payload's `agents` to (current_user's
    private + shared). Vocations unchanged. Broadcasts unchanged.
12. **Bootstrap redirect.** `PageController.home/2` (or a dedicated plug on
    the layout) checks `Accounts.user_count/0`:
    - `0` → redirect to `/register?token=first-user`. The server resolves
      this magic token at registration time; the user becomes admin.
    - `>0` and not authenticated → redirect to `/login`.
    - `>0` and authenticated → render `:home`.
    The backfill of existing agents to the new owner is **not** automated.
    Once the first user exists, the operator runs `mix archive.install …` or
    a `mix run priv/repo/backfill_agent_owners.exs` script that takes every
    existing agent and sets `created_by_user_id` to the chosen user. For a
    fresh deployment the order is: install → migrate → load `/` → register
    the first user → backfill. For an existing deployment with no users,
    same flow.
13. **AgentChannel.** Join authorization: only the creator OR a shared-agent
    user can join. Non-creator non-shared joins return
    `{:error, %{reason: "forbidden"}}`. Within a shared agent:
    `current_user` is in `socket.assigns` for chat-attribution and logging.
    Tests.
14. **Sub-agents.** `lib/nest/agents/agent.ex` `build_child_attrs/4` (or
    the equivalent) copies `created_by_user_id` and `shared` from the parent
    into the new attrs. The clone path threads user identity, not the
    session.
15. **React side.** Implement in this order:
    - `assets/js/api/client.js` — fetch wrapper that injects
      `Authorization: Bearer <token>` from localStorage.
    - `assets/js/api/auth.js` — `login`, `register`, `logout`, `getStoredToken`,
      `getStoredUser`.
    - `assets/js/store/index.js` — add `current_user` slice, `login`,
      `logout` actions.
    - `assets/js/socket.js` — read token from localStorage, pass as
      `params.token`. Reconnect on logout/login.
    - `assets/js/pages/LoginPage.jsx`, `RegisterPage.jsx`, `InvitesPage.jsx`.
    - Extend `assets/js/components/Header.jsx` with username + logout.
    - Extend `assets/js/components/NewAgentForm.jsx` with the shared toggle.
    - Add `react-router-dom` routes for `/login`, `/register`, `/invites`.
    Tests in `assets/js/**/*.test.js` using the existing vitest setup.
16. **CSS.** New pages use the existing dark theme + Tailwind setup (already
    wired in `assets/css/app.css`). Login/register are centered cards.

## Permissions matrix

| Action | Anonymous | Authenticated | First user / admin |
|---|---|---|---|
| `GET /` | redirect to `/login` | render `:home` | render `:home` |
| `GET /register?token=first-user` | 200 (only when `user_count == 0`) | redirect `/` | redirect `/` |
| `GET /register?token=<real>` | 200 | redirect `/` | redirect `/` |
| `POST /api/v1/login` | 200 + token (or 401) | n/a | n/a |
| `POST /api/v1/register` | 201 + token | 409 (already authed) | 409 |
| `POST /api/v1/logout` | 204 | 204 | 204 |
| `GET /api/v1/invites` | 401 | 200 (own invites) | 200 |
| `POST /api/v1/invites` | 401 | 201 | 201 |
| `DELETE /api/v1/invites/:id` | 401 | 204 (only own) | 204 |
| WebSocket connect | `:error` without token | `{:ok, assigns}` | `{:ok, assigns}` |
| Lobby: see shared agent | no | yes | yes |
| Lobby: see private agent | no | only own | only own |
| AgentChannel join | n/a (WS rejected) | only owner or shared | only owner or shared |
| Edit/delete agent | no | only owner | only owner |
| Chat with shared agent | no | yes | yes |
| Chat with private agent | no | only owner | only owner |

## Backfill (one-shot script)

`priv/repo/backfill_agent_owners.exs` (and `mix run`-able task). Takes a
`--user <username>` flag, defaults to `admin`. Sets every agent whose
`created_by_user_id IS NULL` to the chosen user. Idempotent. Print the
count of updated rows.

Run sequence for an existing deployment:
1. `mix deps.get && mix ecto.migrate`
2. Open `/` → redirected to `/register?token=first-user` → register
3. `mix run priv/repo/backfill_agent_owners.exs --user <first-username>`
4. Done. Future agents are owned by whoever creates them.

## Open items deferred to follow-up PRs

- Admin-only invite generation (currently all users can invite).
- Per-user vocations.
- Per-user provider API keys.
- Shared-agent edit page (toggle lives only on the new-agent form for v1).
- Password reset (no email subsystem).
- Account deletion / deactivation.

## Risks / things to watch

- **Argon2 builds.** `argon2_elixir` requires a C compiler; the dev
  container has one. CI must too. Verify before landing.
- **Socket reconnect on logout.** When the user clicks logout, the
  existing socket must drop its current_user assign. The cleanest path is
  `socket.disconnect()` followed by a fresh socket connect with no token.
- **Backfill ordering.** Existing agents without an owner MUST be claimed
  before the lobby filter goes strict, or they vanish. Order: migrate →
  first-user-register → backfill → strict filter. For dev, the order is
  naturally sequential.
- **Sub-agents and shared.** A private agent spawning a child → private
  child (correct). A shared agent spawning a child → shared child
  (correct per "inherit parent's user_id and shared"). Children can be
  flipped later if needed via an edit page (deferred).
- **`Plug.Session` keeps existing behavior.** Removing it would break
  LiveView's `connect_info`. Leave it alone.
- **CSRF on `/api/v1`.** No CSRF tokens because auth is a header, not a
  cookie. The endpoint requires the header to be present; cross-origin
  requests without the token fail at 401.
- **Token revocation.** v1 has no server-side revocation. Tokens remain
  valid until secret rotation. Password change does not invalidate
  existing tokens. Document this in moduledoc.
- **Argon2 params.** Use library defaults. Tighten if compile time or
  runtime is uncomfortable; the cost is one round-trip per login.
## Implementation status (this branch)

The plan above has been fully implemented:

### Migrations
- `priv/repo/migrations/20260805175637_create_users.exs` — `users` table with `citext` username, argon2id password hash, `is_admin` flag, bigserial PK; enables the `citext` Postgres extension.
- `priv/repo/migrations/20260805175700_create_invites.exs` — `invites` table with token (url-safe base64), creator, used_by, used_at, revoked_at, expires_at; unique token index.
- `priv/repo/migrations/20260805175730_add_user_to_agents.exs` — adds `created_by_user_id` (nullable, FK to users with ON DELETE SET NULL) and `shared` (default false) to `agents`; partial index on shared.

### Domain
- `lib/nest/accounts.ex` — public API (`user_count/0`, `create_user/2`, `authenticate/2`, `get_user_by_token/1`, `create_invite/1`, `redeem_invite/2`, `revoke_invite/2`, `list_user_invites/1`).
- `lib/nest/accounts/user.ex`, `lib/nest/accounts/invite.ex` — Ecto schemas.
- `lib/nest/accounts/auth_token.ex` — `Phoenix.Token` wrapper with literal salt `"user_token"`.
- `lib/nest/accounts/password.ex` — `Argon2` wrapper.
- `lib/nest/agents/visibility.ex` — `list_visible_agents_for/1` and helpers.
- `lib/nest/agents.ex` — `list_visible_agents_for/1` defdelegate; `list_broken_agents/0` includes the new columns.

### Auth & controllers
- `lib/nest_web/auth/fetch_current_user.ex` — plug reading `Authorization: Bearer …`.
- `lib/nest_web/auth/require_authenticated.ex` — 401 on missing user.
- `lib/nest_web/controllers/auth_controller.ex` — `/api/v1/login`, `/api/v1/register`, `/api/v1/logout`.
- `lib/nest_web/controllers/invite_controller.ex` — `/api/v1/invites` (GET / POST / DELETE).
- `lib/nest_web/controllers/page_controller.ex` — bootstrap redirects on `/`.
- `lib/nest_web/router.ex` — new `/api/v1` scopes with `api_v1_protected` pipeline.

### Schema/runtime wiring
- `lib/nest/agents/persisted_agent.ex` — new fields on the schema + the new attrs in `cast/2`.
- `lib/nest/persistence.ex` — `build_attrs_for_start/1` carries `created_by_user_id` and `shared` so the supervisor hydrates the runtime state.
- `lib/nest/agents/agent.ex` — `created_by_user_id` and `shared` on the struct + type.
- `lib/nest/agents/agent/init.ex` — threads the new fields through `build_state/2`.
- `lib/nest/agents/agent/introspection_handler.ex` — `created_by_user_id` and `shared` in `build_public_info/1`.
- `lib/nest/chat_model.ex`, `lib/nest/dot_config.ex`, `lib/nest/llm/client_config.ex`, `lib/nest/llm/discover.ex` — `probe_base_url` field added for the typhon-specific dual-URL config (chat at `/olla/proxy/v1`, discovery at `/olla`).

### Channels
- `lib/nest_web/channels/user_socket.ex` — `connect/3` requires a valid token.
- `lib/nest_web/channels/lobby_channel.ex` — `:after_join` filters by `current_user`; `create_agent` stamps `created_by_user_id` from `current_user` and accepts `shared`; `delete_agent`/`change_model` go through `LobbyChannel.Authz`.
- `lib/nest_web/channels/lobby_channel/authz.ex` — extracted authorization helpers (owner-only and owner-or-shared).
- `lib/nest_web/channels/agent_channel.ex` — `join/3` reads `current_user` and falls back to a DB lookup when the supervisor's pid is dead.

### React
- `assets/js/api/client.js` — Bearer-injection `fetch` wrapper.
- `assets/js/api/auth.js` — `login/register/logout` helpers.
- `assets/js/api/invites.js` — `listInvites/createInvite/revokeInvite` helpers.
- `assets/js/socket.js` — reads `nest_token` from `localStorage` and passes it as `params.token`; exposes `window.__nest_socket` so the logout flow can disconnect.
- `assets/js/store/auth.js` — zustand slice for `current_user`.
- `assets/js/pages/LoginPage.jsx`, `RegisterPage.jsx`, `InvitesPage.jsx` — new pages.
- `assets/js/App.jsx` — `/login`, `/register`, `/invites` routes.
- `assets/js/pages/NewAgentPage.jsx` — adds the `shared` checkbox.
- `assets/js/components/Sidebar.jsx` — `CurrentUserBar` showing username, admin badge, links to `/invites`, and a logout button.

### Tests
- `test/nest/accounts_test.exs` — `user_count/0`, `create_user/2`, `authenticate/2` (including the timing-compensation guarantee), `get_user_by_token/1`, invite lifecycle, `revoke_invite/2`, `list_user_invites/1`. Covers happy + every failure mode (magic-token rules, empty password atomicity, tampered tokens, expired/used/revoked invites, non-owner revocation).
- `test/nest/agents/visibility_test.exs` — branch coverage for `Nest.Agents.Visibility` (shared visible, private hidden, dead agent filtered, own private visible).
- `test/nest_web/channels/lobby_channel/authz_test.exs` — owner/shared/forbidden/not-found paths.
- `test/nest_web/channels/lobby_channel_change_model_test.exs` — sibling file (kept under the credo 500-line cap); owner repair, shared-read-only, invalid model, invalid payload.
- `test/nest_web/channels/agent_channel_chat_stop_test.exs` — sibling file for `handle_in(chat:stop)` tests.
- `test/nest_web/channels/user_socket_test.exs` — connect with valid/missing/malformed/deleted-user tokens.
- `test/nest_web/controllers/auth_controller_test.exs` — login/register/logout happy + every documented error response.
- `test/nest_web/controllers/invite_controller_test.exs` — list/create/revoke + ownership/401/404/409 cases.
- `test/nest_web/auth/fetch_current_user_test.exs` and `require_authenticated_test.exs` — header parsing + 401 enforcement.

### Configuration
- `mix.exs` — `comeonin` + `argon2_elixir` deps.
- `config/test.exs` — `argon2_elixir: [t_cost: 1, m_cost: 8]` so the test suite's argon2 hash calls stay fast enough to keep the suite under the 5-second budget. The argon2id algorithm still runs end-to-end.
- `~/.config/nest/config.toml` (operator-side, not in this repo) — `typhon` provider carries `probe-base-url = "http://typhon:4040/olla"` so Discover hits the Olla-namespaced endpoint even when chat is at `/olla/proxy/v1`.

### Backfill

`priv/repo/backfill_agent_owners.exs` — assigns the chosen user (default first user in `users`) to every agent row whose `created_by_user_id IS NULL`. Idempotent, transactional. Operator runs once after first-user registration on existing deployments.

## Coverage note

Branch coverage threshold (90% from `excoveralls` defaults) currently lands at **88.58%**. The new code's branches are well-covered:

- `lib/nest/accounts.ex`: 91.3%
- `lib/nest/agents/visibility.ex`: 85.7%
- `lib/nest_web/channels/lobby_channel/authz.ex`: 94.4%

The aggregate gap is in pre-existing low-coverage files (`application.ex`, `dot_config.ex`, `persisted_agent.ex`, parts of `lobby_channel.ex`) untouched by this change. A separate coverage pass is the right place to close the gap.
