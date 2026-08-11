# Spaces and Sub-agents Design Document

## Overview
The goal is to move from a simple "Collection of Agents" to "Collaborative Environments" (Spaces). This architecture supports complex, multi-step workflows (like Tabletop RPGs or Grading Systems) where a Coordinator agent manages a group of specialist sub-agents.

## Decisions captured during Phase 1 closeout

- **No synthetic default space.** Every `space_id` is a real `Space.id`. The migration does not seed a fallback row.
- **No "active space" state.** Every operation that touches an agent carries `{space_id, agent_id}` explicitly. The LobbyChannel never infers a space from "the current session."
- **No "new agent" flow.** The unit of creation is a space. `Spaces.create_space_with_root_agent/2` creates the space and its root agent in a single transaction. The lobby's old `create_agent` push is replaced by `create_space`.
- **Required args are positional.** `space_id` is the first positional argument on every public API (`Agents.create_agent(space_id, model, opts)`, `Agents.chat(space_id, name, content)`, etc.). It does not live in `opts`.
- **Identity is `{space_id, agent_name}` everywhere.** PubSub topics, Channel topics, Registry keys, and Persistence lookups all use the composite key.
- **`ChildRegistry` is space-scoped.** Parent→children maps are keyed by `{space_id, name}` so children with the same name in different spaces don't collide.
- **No primary space.** Spaces are never auto-created on connect (`Spaces.ensure_primary_space/1` was removed). A user starts with zero spaces and creates one explicitly. Every channel operation requires an explicit `space_id` in the payload — there is no `primary_space_id` fallback. The lobby's `init` payload loads agents across **all** the user's spaces (not a single primary one).

---

## What Already Exists

The current codebase already has significant infrastructure that this plan builds on — **do not rebuild these**:

### Sub-agents via `clone_agent`
- `SubAgent.handle_clone_request/3` spawns children, tracks them in `pending_children`
- `SubAgent.handle_child_completed/4` routes results back, merges usage totals
- `ToolLoop.run_clone_agent/2` blocks the tool worker, waits for child result, returns as tool output
- `ChildRegistry` tracks parent↔children with DOWN-monitor self-cleanup
- `Supervisor.start_agent_with_parent/2` handles the full spawn pipeline (name gen, attrs build, pre-spawn DB, register)
- `Supervisor.stop_agent/2` cascade-terminates subtrees
- `PersistedAgent` schema carries `parent_id`, `depth`, `created_by_user_id`, `shared`
- System prompt already has a `[Delegation]` section documenting `clone_agent` semantics
- Depth-based tool filtering removes `clone_agent` from agents at `max_depth`
- Frontend already renders agent tree in sidebar (`parentId`, `depth`, `parentName`)

### Workspace
- Agents have `workspace_path` used by `read_file`, `write_file`, `edit`, `shell_cmd`
- Per-agent `tmp_path` via `TmpSpace`
- File tools resolve relative paths against workspace root

### Vocations with modes
- Schema has `system_prompt`, `tools`, `modes` (with "caps" sandbox profiles)
- System prompt composition merges vocation + mode catalog + workspace + delegation section

### Multi-user
- `created_by_user_id`, `shared` on agents
- Visibility filter in lobby
- `LobbyChannel.Authz` for ownership checks

---

## 1. The "Space" Concept

A **Space** is a container for an agent group and their shared environment.

### Space Blueprints
Spaces are created from **Blueprints**, which define the "rules of engagement":
- **Root Vocation**: The default vocation for the Coordinator/Root agent.
- **Spawnable Vocations**: A whitelist of vocations that the Coordinator is permitted to spawn as sub-agents.
- **Workspace Defaults**: The initial directory structure and files created for the space.
- **Main View Logic**: Defines the curated UI for the "Main View" of the space.

### Space Identity & Naming
- **Spaces**: Named per-user. A user's spaces are visible only to them. Each user's space `name` is unique within that user's catalog.
- **Agents**: Names are unique **within a space**, not globally. The composite key `{space_id, name}` is the unique agent identifier everywhere.
- **Hierarchies**: Agents can be named using slashes (e.g., `guard_1`, `npc/bard`) to represent logical hierarchy. Since names are per-space, `guard_1` in one space is unrelated to `guard_1` in another.

### Space Selection
There is no primary space. Spaces are never auto-created on connect; a user starts with zero spaces and creates one via `Spaces.create_space_with_root_agent/2`. The lobby's `:after_join` loads the user's spaces and the agents across all of them. The frontend's "selected space" (`currentSpaceId`) is client-side state, seeded from the first space in the `init` `spaces` payload for the initial sidebar highlight.

---

## 2. Technical Architecture

### BEAM Process Tree (Deferred)
Per-space supervisors are **deferred** for now. The current single `Nest.Agents.Supervisor` (DynamicSupervisor with `:one_for_one` strategy) is sufficient because:
- A crash in one agent does not affect siblings (`:one_for_one`).
- Cascade-terminate already works via `Supervisor.stop_agent/2` walking the child tree, which is now space-scoped via `ChildRegistry`.
- "Terminate all agents in a space" = query agents by `space_id`, stop each via existing cascade walk.

Per-space supervisors may be added later if per-space fault isolation becomes a real requirement (e.g., OOM in one space affecting others). The current per-agent context limits make this unlikely.

### Workspace (Shared, No Permissions)
Agents in a space share a common working directory. All agents have full read-write access to the shared workspace.

**Path-based permissions are deferred.** The original plan had access-control rules (read-only for `/rules/`, coordinator-only for `/state/`, private for `/agents/[name]/`). This adds significant complexity to every file tool and requires a policy engine. For now, the shared workspace is flat — all agents in a space can read and write any file. Path-based permissions can be added later as a blueprint-configurable policy.

### Workspace Structure
The workspace is organized conventionally rather than by enforcement:
- `/rules/` — Context files, system rules (conventionally read-only, enforced by the coordinator's system prompt)
- `/state/` — Shared state files (coordinator-managed)
- `/workspace/` — General working files

---

## 3. Sub-agent API (`agents/*` namespace)

Coordinator agents interact with their sub-agents via a standardized logical namespace. Most interactions are **synchronous request-response** cycles.

The existing `clone_agent` tool covers "fork context + spawn + wait for result." The new `agents/*` tools extend this with more structured operations.

### API endpoints:

- `agents/spawn(name, vocation_id)`: Creates a new agent within the space with a **fresh** context (system prompt + spawn instruction only, no parent message history). Different from `clone_agent` which inherits the parent's full context.
  - `name` must be unique within the space.
  - Returns the child's `name` on success.

- `agents/query(name, prompt)`: Sends a prompt to an **existing** agent in the same space and waits for the response synchronously.
  - Resolves `name` within the calling agent's space.
  - Reuses the `Agents.chat/3` path (`space_id`, `name`, `content`) under the hood.
  - Blocks until the agent completes its turn (same pattern as `clone_agent`'s wait in `ToolLoop`).
  - Result returned as tool output.
  - Allows the Coordinator to gather multiple "expert opinions" before synthesizing a final response.

- `agents/list()`: Returns all agents in the current space with their `name`, status, role, and depth.
  - Simple DB query: `FROM agents WHERE space_id = ^space_id`.

### Deferred tools:

- ~~`agents/clone(source_name, new_name)`~~ — Covered by existing `clone_agent`. No change needed.
- ~~`agents/archive(name)`~~ — Deferred. "Archive" is essentially "stop + mark as archived." The state is already persisted on every message; this would be a lifecycle state addition.

---

## 4. Turn-Taking & Interaction Model

### The Coordinator Loop
The Coordinator handles the "Event Loop":
1. **Trigger**: Triggered by User Input, System Event, or Timer.
2. **Planning**: Coordinator decides which sub-agents to query.
3. **Execution**: Synchronous calls to `agents/query` or `agents/spawn`.
4. **Synthesis**: Coordinator aggregates results and produces the final output.

### Interaction Model (Deferred: Structured Phases)
Spaces default to **Free-Form** interaction — any user can input to any agent in the space.

Structured turn-taking (e.g., RPG combat rounds where the Coordinator specifies `current_turn_owner` and the UI disables input for others) is **deferred**. It is an RPG-specific feature that requires:
- A `phase` field on the space/coordinator
- Channel-layer rejection of out-of-turn `chat:message` pushes
- UI input disabling based on `current_turn_owner`

This can be added later as a blueprint-specific behavior (only blueprints that need it enable it).

---

## 5. UI/UX Model

### The "Zoom" Metaphor
- **Main View (The Overview)**:
    - Accessed by clicking the Space name.
    - A curated, blueprint-specific experience (e.g., "The Game Table").
    - Filters out the "sausage making" (hidden sub-agent queries).
    - Only this view is shared with non-owner participants by default.
- **Agent View (The Inspection)**:
    - Accessed via an expand widget in the sidebar.
    - Provides 100% transparent, raw access to a specific agent's chat history and tools.
    - Reserved for the Space owner.

### Creation Flow
The user creates a **space** (not an agent). The new-space form is the same UX as the previous new-agent form (name + model + vocation), but the wire payload is `create_space`, and the backend creates a space plus its root agent in one transaction. The new-space form is the home of the model/vocation selector for now; Phase 2 will replace that with a blueprint picker that pre-fills the root agent's characteristics.

---

## 6. Canonical Signatures (Phase 1 Closeout)

These are the function signatures that all of Phase 1 must converge on. No deviation is allowed without updating this list.

### Spaces

```elixir
Nest.Spaces.list_for_user(user_id) :: [%Space{}]
Nest.Spaces.get_space(id) :: %Space{} | nil
Nest.Spaces.get_by_slug(slug) :: %Space{} | nil
Nest.Spaces.create_space(user_id, attrs) :: {:ok, %Space{}} | {:error, Ecto.Changeset.t()}
Nest.Spaces.delete_space(id) :: :ok | {:error, :not_found}
Nest.Spaces.create_space_with_root_agent(user_id, attrs) :: {:ok, %Space{}, String.t()} | {:error, term()}
```

### Agent public API (`Nest.Agents`)

```elixir
Nest.Agents.create_agent(space_id, model, opts \\ []) :: {:ok, String.t()} | {:error, term()}
Nest.Agents.get_info(space_id, name) :: {:ok, map()} | {:error, :not_found}
Nest.Agents.get_agent(space_id, name) :: {:ok, map()} | {:error, :not_found | term()}
Nest.Agents.list_agents_for_space(space_id) :: [String.t()]
Nest.Agents.list_agents_info_for_space(space_id) :: [map()]
Nest.Agents.list_visible_agents_for(space_id, user_id) :: [map()]
Nest.Agents.list_broken_agents(space_id) :: [map()]
Nest.Agents.get_messages(space_id, name) :: {:ok, [map()]} | {:error, :not_found}
Nest.Agents.chat(space_id, name, content, mode \\ nil) :: :ok | {:error, :not_found}
Nest.Agents.stop_chat(space_id, name, from) :: :ok | {:error, :not_found}
Nest.Agents.retry_compaction(space_id, name) :: :ok | {:error, atom()}
Nest.Agents.compaction_loop_detected_ok(space_id, name) :: :ok | {:error, atom()}
Nest.Agents.delete_agent(space_id, name) :: :ok | {:error, :not_found}
Nest.Agents.change_model(space_id, name, new_model) :: :ok | {:error, term()}
```

### Agent supervisor

```elixir
Nest.Agents.Supervisor.fetch_or_start_agent(space_id, attrs) :: {:ok, String.t()} | {:error, term()}
Nest.Agents.Supervisor.get_agent(space_id, name) :: {:ok, pid()} | {:error, :not_found}
Nest.Agents.Supervisor.stop_agent(space_id, name) :: :ok | {:error, :not_found}
Nest.Agents.Supervisor.cascade_children_only(space_id, name) :: :ok
Nest.Agents.Supervisor.start_agent_with_parent(parent_state, instruction) :: {:ok, String.t()} | {:error, term()}
Nest.Agents.Supervisor.generate_unique_name_for_space(space_id) :: String.t()
```

### Agent registry

```elixir
Nest.Agents.Registry.via_tuple(space_id, name) :: {:via, Registry, {atom(), {integer(), String.t()}}}
Nest.Agents.Registry.lookup(space_id, name) :: {:ok, pid()} | {:error, :not_found}
Nest.Agents.Registry.list_for_space(space_id) :: [String.t()]
Nest.Agents.Registry.list_all() :: [{integer(), String.t()}]
```

### Child registry (space-scoped)

```elixir
Nest.Agents.ChildRegistry.register(space_id, parent_name, child_name) :: :ok
Nest.Agents.ChildRegistry.unregister(space_id, child_name) :: :ok
Nest.Agents.ChildRegistry.children_of(space_id, parent_name) :: [String.t()]
Nest.Agents.ChildRegistry.parent_of(space_id, child_name) :: String.t() | nil
```

### Persistence

```elixir
Nest.Persistence.fetch_agent(space_id, name) :: {:ok, %PersistedAgent{}} | {:error, :not_found}
Nest.Persistence.insert_agent(attrs) :: {:ok, %PersistedAgent{}} | {:error, term()}
Nest.Persistence.delete_agent(space_id, name) :: :ok
Nest.Persistence.list_agent_names_for_space(space_id) :: [String.t()]
Nest.Persistence.build_attrs_for_start(space_id, name) :: {:ok, map()} | {:error, :not_found}
Nest.Persistence.insert_message(space_id, agent_name, message) :: {:ok, %PersistedMessage{}} | {:error, term()}
Nest.Persistence.update_agent_model(space_id, name, model) :: {:ok, term()} | {:error, term()}

# Agent-side wrapper:
Nest.Agents.Agent.Persistence.append_message(space_id, agent_id, stamped, new_index) :: :ok
```

### Wire topics

```
PubSub broadcast: "agent:#{space_id}:#{name}"
Lobby channel:    "lobby"
Agent channel:    "agent:#{space_id}:#{name}"
```

---

## Implementation Phases

### Phase 1: Schema, Name Refactor & Data Model  **[DONE]**

**Goal**: Spaces exist as first-class containers. Agent names become unique within a space (`{space_id, name}` composite key). The Registry, Persistence, and Agent API are refactored to use space-scoped lookups. The lobby pushes a `create_space` flow that creates a space + root agent transactionally.

**Status:** All 20 items landed. `mix precommit` exits 0. 1238 tests pass. Zero credo issues.

**Migrations:**
1. **`spaces` table** (`id`, `name` (globally unique), `slug` (globally unique), `blueprint_id` (nullable), `created_by_user_id`, timestamps).
2. **`agents` gets `space_id` FK** (NOT NULL after the migration). NO synthetic default space row.
3. **Unique constraint change**: `(agents.name)` → `(agents.space_id, agents.name)`.

**Core refactor — Registry:**
4. **`Nest.Agents.Registry`** keys by `{space_id, name}` using `Registry.select` (deprecation-fixed).

**Persistence refactor:**
5. **`Persistence.fetch_agent/2(space_id, name)`**, **`insert_agent/1`** (with `space_id` in attrs), **`list_agent_names_for_space/1`**, **`build_attrs_for_start/2`**, **`insert_message/3`**, **`update_agent_model/3`**.

**Supervisor & Agent changes:**
6. **`Supervisor.fetch_or_start_agent/2(space_id, attrs)`**, **`get_agent/2`**, **`stop_agent/2`**, **`generate_unique_name_for_space/1`**.
7. **`Agent.start_link/1`** receives `space_id` in attrs, uses `Registry.via_tuple(space_id, name)`.
8. `Agent` struct gains `space_id` field.
9. **`Agent.persist_system_message/1`** passes `space_id` to `Persistence.insert_message`.
10. **`Init.persist_initial_system_message/1`** passes `space_id` to `AgentPersistence.append_message`.
11. **`ModelHandler.perform_set_model/2`** passes `state.space_id` to `Persistence.update_agent_model`.

**Context module & API:**
12. **`Nest.Spaces`** — `list_for_user/1`, `get_space/1`, `get_by_slug/1`, `create_space/2`, `delete_space/1`, **`create_space_with_root_agent/2`**.
13. **`Nest.Agents` public API** — `space_id` as first positional arg on every function.

**Channel & PubSub changes:**
14. **`AgentChannel`** joins as `"agent:#{space_id}:#{name}"`. Subscribes to PubSub topic of the same name.
15. **`LobbyChannel`** `:after_join` loads the user's spaces and the agents across all of them. Replaces `create_agent` push with `create_space` push. `delete_agent` and `change_model` require an explicit `space_id` in the payload (no fallback).
16. **`LobbyChannel.Authz`** takes `(space_id, name)` as positional args.

**Tests:**
17. Full test suite migration to use `space_id` in all agent operations.
18. Registry partition tests (same name, different spaces → different agents).
19. Space CRUD, space-with-root-agent transactional flow.
20. New test files for Spaces and for the create_space channel handler.

**Phase 1 followups:**

A handful of small cleanups surfaced during the closeout review. **F1–F4 all landed** (see below).

- **[DONE] F1. Restore `parent_name` from the DB on agent restore.** `Persistence.build_attrs_for_start/2` now looks up the parent row's `name` by `parent_id` (same space) and includes it in the returned attrs. Two regression tests in `supervisor_subagent_test.exs` pin the restore path (child carries `parent_name`; root has `parent_name: nil`).
- **[DONE] F2. Strip stale docstrings.** Updated `broadcasts.ex:6` (`agent:<space_id>:<name>`), `agent.ex` (`fetch_agent/2`), `sub_agent.ex` (`via_tuple(space_id, parent_name)`), `persisted_agent.ex` (reach parent via `fetch_agent/2` by `parent_id`), the `create_spaces` migration (removed the synthetic-default paragraph), and `spaces.ex` `delete_space` (docstring now matches the code: caller is responsible for terminating agents first).
- **[DONE] F3. Remove the `primary_space_id` fallback.** The `payload["space_id"] || primary_space_id` fallback in `change_model` and `delete_agent` was removed once the JS client always sent `space_id`. The entire primary-space concept was later deleted (see the "No primary space" note above).
- **[DONE] F4. Unify wire field naming.** Chose **snake_case `space_id`** for all space-id wire fields (`agent:created`, `agent:init`, `chat:status`) and `current_space_id` for the lobby `init` key. Landed in Phase 4. (`current_space_id` was later dropped from the init payload when the primary space was removed; `currentSpaceId` is now client-side state.)

### Phase 2: Blueprints  **[DONE]** (2 items deferred to Phase 3)

**Goal**: Spaces are created from templates. Blueprints define root vocation and spawnable vocations.

**Status:** Core landed. `mix precommit` exits 0; 1261 tests pass; zero credo issues. Two items were deliberately deferred to Phase 3 because they are consumed by the sub-agent API: `workspace_template` seeding and `spawnable_vocation_ids` whitelist enforcement.

1. **[DONE] Migration**: `blueprints` table (`id`, `name`, `slug`, `description`, `root_vocation_id`, `spawnable_vocation_ids` (integer array), `workspace_template` (map/JSON), `main_view_config` (map/JSON)). A second migration promotes `spaces.blueprint_id` to a real FK (`on_delete: :nilify_all`).
2. **[DONE] Seed**: Pre-seed blueprints in `seeds.exs`:
   - "Agent" — single agent, no restrictions (`spawnable_vocation_ids: []`), `Default` root.
   - "Tabletop RPG" — DM root (`Default`), NPC spawnable vocations (placeholder `[]`).
   - "Code Review" — Reviewer root (`Programmer`), language-specialist sub-vocations (placeholder `[]`).
3. **[DONE] `Nest.Blueprints` context module**: `list_blueprints/0`, `get_blueprint/1`, `get_by_slug/1`, `create_blueprint/1`, `update_blueprint/2`, `upsert_blueprint/1`, `delete_blueprint/1`, `root_vocation_id_for/1`.
4. **[DONE] Space creation from blueprint** (in `Spaces.create_space_with_root_agent/2`):
   - Create space row (with `blueprint_id`).
   - Create root agent with the blueprint's `root_vocation_id`.
   - **DEFERRED → Phase 3**: seed workspace files from `workspace_template`.
5. **[DEFERRED → Phase 3] Spawn restrictions**: `agents/spawn` will check `vocation_id` against the blueprint's `spawnable_vocation_ids` whitelist.
6. **[DONE] Tests**: `test/nest/blueprints_test.exs` (14 tests), `test/nest/spaces_test.exs` (5 tests), plus a lobby test asserting a `blueprint_id` drives the root agent's vocation.

**Divergences from the original design (recorded for posterity):**

- **Root-vocation resolution happens BEFORE the space insert.** `resolve_root_vocation/1` validates the blueprint (and requires a vocation) before `create_space`, so a bad `blueprint_id` returns `{:error, :blueprint_missing}` and a caller with neither a vocation nor a blueprint returns `{:error, :missing_vocation}` — both instead of raw FK / `NOT NULL` crashes.
- **Lobby precedence: a `blueprint_id` drives the root vocation over the default.** `LobbyChannel.build_create_space_attrs/4` does not forward the lobby's default `vocation_id` when the payload carries a `blueprint_id`, so the blueprint's `root_vocation_id` wins. Without a blueprint the default-vocation behavior is unchanged.
- **`Space.changeset` hardened** with `foreign_key_constraint(:blueprint_id)` so a direct `create_space` with a bad blueprint id yields a changeset error rather than an `Ecto.ConstraintError`.

### Phase 3: Sub-agent API  **[DONE]** — `spawn_agent`, `query_agent`, `list_agents` all landed (`workspace_template` seeding still deferred)

**Goal**: Coordinators have structured tools to manage sub-agents within their space.

**Status:** All three tools landed (1270 tests pass, credo clean). Two naming decisions: tools are registered as `spawn_agent` / `query_agent` / `list_agents` (flat snake_case, matching `clone_agent`, rather than the doc's `agents/*` conceptual labels), and `spawnable_vocation_ids` `[]`/nil means **unrestricted** (see the semantics note below).

1. **[DONE] `spawn_agent(name, vocation_id)` tool**:
   - `ToolLoop` intercepts `spawn_agent` (parallel to `clone_agent`), sends a `:spawn_agent_request` to the coordinator GenServer, and returns the specialist's name as a synchronous `ToolResult`.
   - `Supervisor.spawn_agent_in_space/3` creates an *independent*, fresh-context specialist: system-prompt-only (no parent message history fork), no `ChildRegistry` link, `depth: 0`. It reuses `Agents.create_agent/3` with the coordinator's model/identity.
   - `name` must be unique within `space_id` (the `(space_id, name)` composite index → `{:error, :duplicate_name}`).
   - **Whitelist enforcement**: `Spaces.spawnable_vocation_ids_for_space/1` + `Blueprints.spawnable_vocation_ids/1` resolve the space's blueprint whitelist; a denied vocation returns `{:error, :vocation_not_spawnable}`.
   - **Semantics decision**: `spawnable_vocation_ids: []` (or `nil`, or a missing/no blueprint) = **unrestricted**. A non-empty list is a strict whitelist. This matches the Phase 2 seed intent ("Agent — no restrictions"). `Blueprint` docstring and seeds updated to match.
2. **[DONE] `query_agent(name, prompt)` tool**:
   - `ToolLoop.run_query_agent/2` sends a chat message to a *peer* agent in the calling agent's space via `Agents.chat/3` and blocks until the target goes idle.
   - **Completion mechanism (no `pending_queries` needed):** the queried agent is a peer, so `clone_agent`'s `pending_children` doesn't apply. Instead the worker subscribes to the target's PubSub topic (`agent:<space_id>:<name>`), triggers the turn, and waits for the `:chat_status` idle broadcast. It captures the target's message count *before* sending and only accepts an idle once a new assistant message (index ≥ pre-count) exists — guarding against reading a stale pre-query response. Bounded by a 60s total wait (250ms poll slices).
   - **Concurrency caveat (documented):** if the target is already mid-turn for a *different* query when a new one arrives, the reader may return the earlier turn's response. Fine for the single-coordinator-per-specialist model; revisit if concurrent queries to one target become a real case.
3. **[DONE] `list_agents()` tool**:
   - `ToolLoop` reads `Agents.list_agents_info_for_space(space_id)` inline (no GenServer round-trip) and serializes `name`, `vocation_id`, `status`, `depth`, truncated to 4000 chars.
4. **[DONE] System prompt updates**: The `[Delegation]` section now renders paragraphs for whichever sub-agent tools are in the agent's filtered tool list — `clone_agent`, `spawn_agent`, `query_agent`, `list_agents`. The section is omitted when none are present (preserving the existing leaf-at-max-depth contract).
5. **[DONE] Tests**:
   - `supervisor_spawn_test.exs` (5 tests): unrestricted spawn, fresh-context count, duplicate name, whitelist allow/deny, empty-whitelist-is-unrestricted.
   - `sub_agent_tools_test.exs` (3 MockClient E2E tests): `spawn_agent`, `list_agents`, `query_agent` (a mocked specialist in the coordinator's space answers the query; the coordinator's tool result carries the answer).
   - Delegation-section system-prompt test.

**Also still open (Phase 2/3 item):**
- **`workspace_template` seeding** (Phase 2 item 4c) remains deferred: seeded blueprints all have empty templates and seeding needs a `workspace_path`, which is often nil. Revisit when a blueprint actually ships files.

### Phase 4: Frontend — Multi-Space UI  **[DONE]**
**Goal**: Sidebar shows spaces with nested agents. Main View and Agent View routes.

**Status:** Multi-space UI landed. `mix precommit` exits 0; 1277 Elixir tests + 871 JS tests pass; credo + biome clean. **F4 (wire-field naming) closed** — all space-id wire fields are snake_case `space_id`.

1. **[DONE] Zustand store**:
   - `spaces` state (list of spaces), `currentSpaceId`, `blueprints`.
   - `setSpaces`/`setCurrentSpaceId`/`setBlueprints`/`addSpace`/`removeSpace`.
   - `addAgent` now carries `space_id`; `_reset`/`logout` clear the new state.
2. **[DONE] Sidebar restructuring**:
   - "New Space" button → `/spaces/new`.
   - Spaces section: each space is a `SpaceRow` (collapsible) showing that space's agent tree (reuses `buildAgentTree`).
   - Agent rows link to `/space/:slug/agent/:name`; delete passes `space_id`.
   - "Needs Repair" + "About" retained, space-scoped.
3. **[DONE] Routing**:
   - `/spaces` → `SpacesIndex` (landing).
   - `/spaces/new` → `NewSpacePage`.
   - `/space/:spaceSlug` → `SpaceView` (Main View).
   - `/space/:spaceSlug/agent/:name` → `ChatPage`.
   - `/` → RootGate → redirects to `/spaces`.
   - Removed `/new_agent` and `/agent/:name`; deleted `NewAgentPage`.
4. **[DONE] Space creation flow**:
   - `NewSpacePage` with space-name input + **blueprint picker** (blueprints from the lobby `init` `blueprints` payload) + model select.
   - `createSpace` channel helper pushes the lobby's `create_space` (space + root agent in one transaction).
   - `space:created` broadcast handled (adds the space to the store).
5. **[DONE] Main View (`SpaceView`)**: default "space overview" showing the space's agents + status with links to each Agent View. Blueprint-driven `main_view_config` layouts remain a future extension (all seeded blueprints have empty `main_view_config`).
6. **[DONE] Agent View (`ChatPage`)**: reads `{spaceSlug, name}` from the route, resolves `space_id` from the store, and joins `agent:<space_id>:<name>` (fixing the pre-Phase-4 broken single-name topic). `changeAgentModel`/`deleteAgent` thread `space_id`; parent back-link is `/space/:slug/agent/:parent`.
7. **[DONE] F4 — wire-field naming unified to snake_case `space_id`**: `agent:created`, `agent:init` (`space_id`), `chat:status` (`space_id`), and the lobby `init` key `current_space_id`. Removed the camelCase `spaceId` variants. (Later, when the primary space was removed, `current_space_id` was dropped from `init`; `currentSpaceId` is now client-side state seeded from the first space.)
8. **[DONE] Backend**:
   - Lobby `init` payload now includes `blueprints: Blueprints.list_blueprints()` (the blueprint picker's data source).
   - All wire `spaceId` → `space_id`.
9. **[DONE] Tests**: store/channels/Sidebar/ChatPage/App tests updated for the space-aware APIs and routes; new pages covered; 871 JS tests green.

### Phase 5: Polish  **[IN PROGRESS]** — space deletion + rename DONE, agent rename DEFERRED

**Goal**: Space lifecycle management, cleanup, multi-participant (optional), and the structural followups identified during Phase 1 review.

**Status:** `Spaces.delete_space/1` now really cascades; `Spaces.rename_space/2` landed; P5-B (compaction_loop payload + AgentTestHelpers cleanup) landed. `Agents.rename_agent/3` is **deferred** (see below). 1277 tests pass, credo clean, zero credo disables.

1. **[DONE] Space deletion**: `Spaces.delete_space/1` now:
   - Enumerates agent names via `Persistence.fetch_all_agents_for_space/1`.
   - Terminates every live agent via `Supervisor.stop_agent/2` (the existing `ChildRegistry` walk covers descendants) *before* the DB work.
   - Deletes all agent rows, then the space row, in one `Repo.transaction`.
   - **FK decision**: kept `agents.space_id` as `on_delete: :nothing` and delete rows in code first — the code-side cascade is observable (per the design's preferred option). Tests: cascade to multiple agents (rows gone + processes stopped + space gone), empty-space delete, `{:error, :not_found}`.
2. **[DONE] Space rename**: `Spaces.rename_space/2` updates `name` (re-derives `slug` via `Space.changeset`) with global `name`/`slug` uniqueness. No agent/process/PubSub changes (topics key off `space_id`, not slug). A changed slug will affect `/space/:slug` routes, but those are a Phase 4 concern. Tests: name + slug re-derive, name collision, `:not_found`.
3. **[DEFERRED] Agent rename** (`name`): Update within-space agent name. Requires:
   - Uniqueness check scoped to `(space_id, name)` (the composite index already covers this).
   - Stop the agent, swap the row, restart it.
   - Update the `Registry` via `Agent.via_tuple(space_id, new_name)`.
   - Update `ChildRegistry` parent/child references (parents can't be renamed live without breaking the child's `parent_name`).
   - **Deferred by decision** in the Phase 5 lifecycle pass: the `ChildRegistry` rekeying for parent/child agents is the risky part; a safe subset (rename a root with no children) is possible but the full child-aware rename needs its own focused effort.
4. **Multi-participant** (optional): Space membership, sharing, role-based access.
5. **Structured turn-taking** (optional): Phase state, `current_turn_owner`, UI input gating.
6. **Tests**: Space-deletion cascade + rename covered in `test/nest/spaces_test.exs`. Lifecycle integration (delete via the channel) is a Phase 4 follow-on.

### Phase 5 followups (structural cleanup from Phase 1 review)

These are pre-existing structural issues that the Phase 1 refactor didn't fix but should land alongside Phase 5 while the data model is fresh.

#### P5-A. Split `ChatState` by persistence boundary

`Nest.Agents.Agent.ChatState` (in `lib/nest/agents/agent/chat_state.ex`) has 17 fields of mixed lifecycle. The `# credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount` annotation is the project's existing compromise for this.

**The leak surface.** Every handler that mutates `chat_state` has to know which fields are persistent (reset on `init/1`) and which are not. Every field on the wrong side of the boundary is a bug:

- **`streaming_acc`** — if a restart leaves a non-nil accumulator pointing at a dead ChatTurn, the next `:chat_delta` append corrupts the message.
- **`crossed_thresholds`** — if a restart preserves the old MapSet, the post-restart conversation never re-fires the 50% / 75% warnings.
- **`pending_children`** — child tools waiting for `:child_completed` are orphaned after a restart; the `:tool_completed` path silently drops `:clone_agent_result` for unknown children.
- **`consecutive_compaction_count`** — non-zero on restart can trip the loop-breaker immediately.

**The plan.** Split into two sub-structs by lifecycle:

```elixir
defmodule Nest.Agents.Agent.ChatState do
  # Persisted across BEAM restarts. `init/1` and `restore` paths
  # touch only this struct. The defaults here are the "fresh agent"
  # state.
  defstruct messages: [],
            history: [],
            last_compaction_index: -1,
            next_message_index: 0,
            pending_children: %{},
            read_files: %{}
end

defmodule Nest.Agents.Agent.ChatState.Live do
  # Per-process state. Always reset to defaults on `init/1`. The
  # ChatTurn spawner, the streaming accumulator, the Stop
  # handler, and the compaction result handler mutate only this.
  defstruct streaming_acc: nil,
            status: :idle,
            active_message_index: 0,
            api_log_sequences: %{},
            pending_api_logs: %{},
            chat_turn_pid: nil,
            cancelled: false,
            pending_user_message: nil,
            mid_turn_entry: nil,
            crossed_thresholds: %MapSet{},
            consecutive_compaction_count: 0,
            tool_index_map: %{},
            mode: "chat"
end
```

The `Agent` struct exposes `chat_state: %ChatState{}` and `live: %ChatState.Live{}`. The persistence boundary becomes explicit; the dangerous-field list is short and visible; the credo warning goes back to zero.

**Migration plan:**
1. Add `Nest.Agents.Agent.ChatState.Live` as a sibling module.
2. Add `live: %ChatState.Live{}` to the `Agent` struct.
3. Move the 11 ephemeral fields from `ChatState` to `Live`.
4. Update every `state.chat_state.X` to read from `state.live.X` (or whichever sub-struct owns the field).
5. Update every `set M, state -> %{state | chat_state: %{state.chat_state | ...}}` to write through the right sub-struct.
6. Update `build_attrs_for_start` to restore only the persistent fields (already does — no change).
7. Drop the `credo:disable-for-next-line` annotation; the new `ChatState` should be 7 fields, `Live` 11 fields.

#### P5-B. Other Phase 5 polish items — **[DONE]**

- **[DONE] Broadcast `compaction_loop` payload**: now carries `attempt_count` and `max_attempts` alongside `content`:

      {:chat_compaction_loop,
       %{content: "<reason>\\n[Source: Module.fn/arity]",
         attempt_count: 3, max_attempts: 3}}

  `ResultHandler.set_compaction_loop/4` threads the consecutive count that already happened and `@max_consecutive_compactions` (3). The payload shape is documented in `Broadcasts.compaction_loop/6`. The channel already forwards the whole payload; `StatusBanner` renders a "Tried X of Y consecutive compactions" line. New tests: `result_handler_test` asserts the broadcast payload carries both counts; `agent_channel_compaction_loop_test` asserts they're forwarded.
- **[DONE] Remove the `Spaces.delete_space` docstring lie.** Implemented the real cascade in Phase 5 #1.
- **[DONE] Eager cleanup of dead `process_dict` keys in `AgentTestHelpers`.** Removed the ineffective `Process.put(:nest_test_agent_pid, test_pid)` from `register_on_exit_cleanup/3` — it ran in the separate ExUnit runner process and could never touch the test pid's dict (dead code). Ownership is now consistent: `:nest_test_agent_pid` / `:nest_test_subscribed_topic` are refreshed at the start of the next `start_agent/1` (via `drop_stale_pubsub_subscription/0` and `bridge_test_to_agent/3`), and the `on_exit` no longer implies it mutates the test pid. The 4-arity cleanup became `register_on_exit_cleanup/3`.

---

## Deferred Features

These are tracked for future consideration but not in scope for the initial implementation:

### Per-space supervisors
Nested DynamicSupervisors per space for fault isolation. Deferred because:
- Current `:one_for_one` supervisor already isolates agent crashes
- Cascade-terminate covers "stop all agents in space"
- Adds complexity without clear benefit until multi-tenant or high-load scenarios

### Path-based workspace permissions
Access-control rules on workspace sub-paths (read-only, coordinator-only, private). Deferred because:
- Adds complexity to every file tool (authorization layer before execution)
- Requires a policy engine (blueprint-configurable rules)
- Shared workspace with conventional organization is sufficient for initial use cases

### `agents/archive` tool
"Dormant state — save state, kill process, don't auto-reload." Deferred because:
- Agent state is already persisted on every message
- "Archive" is primarily a lifecycle state + explicit restore
- Can be added when there's a clear use case (e.g., parking NPCs between sessions)

### Structured turn-taking / phases
"Coordinator specifies `current_turn_owner`, UI disables other input." Deferred because:
- RPG-specific feature, not needed for general coordinator pattern
- Requires channel-layer rejection of out-of-turn messages
- Can be added as blueprint-specific behavior
