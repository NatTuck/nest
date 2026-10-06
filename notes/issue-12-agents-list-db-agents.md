# Issue #12 — `agents-list` tool only lists loaded agents (plan)

> Produced by a planning minion, read-only. Pending team-lead review.

## Goal
Make the `agents-list` tool enumerate every **non-archived** agent in the calling agent's space (running *or* persisted-only), using the same registry-plus-DB merge the sidebar already uses.

## Root cause (evidence)
- The tool handler `run_list_agents/2` reads only the registry:
  - `lib/nest/agents/agent/tool_loop.ex:244-263` — calls `Nest.Agents.list_agents_info_for_space(ctx.space_id)` (line 246) and serializes `name` / `vocation` / `status` / `depth`.
- `Nest.Agents.list_agents_info_for_space/1` is registry-only:
  - `lib/nest/agents.ex:218-226` — `list_agents_for_space/1` → `Registry.list_for_space/1` (`lib/nest/agents.ex:210-212`, `lib/nest/agents/registry.ex:44-50`). A persisted row with no live pid is invisible.
- The sidebar does **not** have this bug. It renders `Nest.Agents.list_visible_agents_for/2`:
  - `lib/nest_web/channels/lobby_channel.ex:263-266` (`visible_agents_across_spaces/2`).
  - `lib/nest/agents/visibility.ex:36-45` — merges `fetch_from_registry/3` (line 109) with `persisted_visible/2` (line 141), filters `archived == false` (visibility.ex:149), and de-dupes by name (`Enum.uniq_by(& &1.name)`).
- The tool's doc comment/description already *claim* "non-archived agents" but the implementation contradicts it:
  - `lib/nest/tools.ex:364-384` (comment says "non-archived", description says "active sub-agents … running agents").

**What remains / not yet addressed:** nothing partial — the tool is purely registry-sourced today.

## Tasks (ordered)

1. **Add a space-scoped, no-user-filter merge in `Visibility`.**
   - File: `lib/nest/agents/visibility.ex`.
   - Add `list_non_archived_agents_for_space/1`: same body as `list_visible_agents_for/2` (lines 36-45) but without the user predicate.
   - Generalize the two private helpers to accept `user_id == nil` meaning "no filter": in `fetch_from_registry/3` (line 109-139) replace the guard `id == user_id or shared == true` with a shared `visible_to?(info, user_id)` helper (`user_id == nil or id == user_id or shared == true`); in `persisted_visible/2` (line 141-172) skip the owner/shared `where` when `user_id == nil`.
   - Acceptance: `list_visible_agents_for/2` and `list_archived_agents_for/2` behavior is byte-for-byte unchanged (their tests must still pass); the new function returns registry ∪ persisted-non-archived, de-duped by name.

2. **Expose it through the public API and repurpose the registry-only function.**
   - File: `lib/nest/agents.ex`.
   - Change `list_agents_info_for_space/1` (lines 218-226) to delegate to `Visibility.list_non_archived_agents_for_space/1` (or add a new `list_non_archived_agents_for_space/1` wrapper and delete/keep the old — see Open Questions). Update the `@doc` from "all running agents" to "all non-archived agents (running or persisted-only)".
   - Acceptance: the function returns persisted-only rows; running rows still carry full public info.

3. **Point the tool at the merged listing.**
   - File: `lib/nest/agents/agent/tool_loop.ex`, `run_list_agents/2` (lines 244-263).
   - Read via the merged function; change `vocation: info.vocation_slug` (line 250) to `Map.get(info, :vocation_slug)` because `Visibility`'s persisted maps (visibility.ex:158-171) have no `:vocation_slug` key (they have `:depth`, `:status`, `:model`, `:parent_name`, etc.). Update the surrounding comment.
   - Acceptance: no `KeyError` for DB-only agents; running agents keep their vocation slug.

4. **Fix the tool description/comment to match reality.**
   - File: `lib/nest/tools.ex:364-384`.
   - Description should say it lists all non-archived agents in the space (running or not) so the model understands delegation targets. Also update the stale `notes/spaces-and-subagents.md:366` if we touch docs.
   - Acceptance: description no longer implies "running only".

## Tests to add / update
- `test/nest/agents/visibility_test.exs` (new tests for `list_non_archived_agents_for_space/1`):
  - a non-archived, **not-alive** persisted row is included (mirror the existing "pid is dead" setup at visibility_test.exs:124-146, which currently asserts exclusion from `list_visible_agents_for`);
  - an **archived** row is excluded;
  - a running agent appears **once** (registry row + its DB row de-duped by name);
  - archived-only agents never appear.
- `test/nest/agents_test.exs`, describe `list_agents_info/0` (lines 215-279):
  - `"returns list of agent info"` — keep, optionally add a DB-only row assertion.
  - `"skips agents whose process dies during enumeration"` (lines 232-279) must be updated: with the merge, the persisted backfill now returns the two agents even when `Agent.get_public_info/1` exits, so the `== []` assertion (line 264) no longer holds. Rewrite it to assert the call does not raise and still returns both agents (proving the `:exit` is swallowed by `Agents.get_info/2`), or isolate the registry path by deleting the two rows' DB rows before stubbing (messages cascade via `on_delete: :delete_all`).
- `test/nest/agents/agent/sub_agent_tools_test.exs`, `"agents-list tool returns the space's running agents"` (lines 204-259):
  - rename to reflect running + persisted; insert a DB-only non-archived row via `Nest.Persistence.insert_agent/1` and assert its name is in `content`;
  - insert + `Nest.Persistence.archive_agent/1` a row and assert its name is **not** in `content`;
  - keep the existing running-specialist assertion.
- JS: no changes needed (sidebar logic untouched); `Sidebar.test.jsx` should be unaffected.

## Edge cases / risks
- **`vocation_slug` on persisted maps** — must use `Map.get` (task 3); the shipped merge resolves it from the row's `vocation_id` via a batched `Vocations.list_vocations/0` lookup (`Visibility.vocation_slugs_by_id/0`), so DB-only rows report their real slug (`nil` only when the row has no resolvable vocation).
- **De-duplication** — a running agent has both a registry entry and a DB row; `Enum.uniq_by(& &1.name)` (visibility.ex:44) is required or it appears twice.
- **Archived exclusion** — relies on `persisted_visible`'s `archived == false` filter (visibility.ex:149); the generalized no-user version must keep it.
- **Broken agents** — `list_broken_agents/1` (agents.ex:392-394) only reports rows that are *not alive* **and** whose model won't resolve (agents.ex:397-417). Those rows are still non-archived, and the sidebar's main tree already includes them via `persisted_visible`; the amber "Needs Repair" block (`assets/js/components/SidebarSpaceRow.jsx:315-321`) is a separate UI affordance. So the merged listing will include them (matching the sidebar). See Open Questions.
- **Truncation** — still `String.slice(0, @list_agents_max_chars)` (tool_loop.ex:53, 260); a large DB just truncates as before.
- **Scope** — `ctx.space_id` is the caller's space (turn.ex:192), so only that space's agents are listed; other spaces stay invisible.

## Verification (specify, do not run)
1. Targeted: `mix test test/nest/agents/visibility_test.exs test/nest/agents_test.exs test/nest/agents/agent/sub_agent_tools_test.exs` — read the full output.
2. Full suite: `mix test` (must stay < 5s and print nothing unexpected).
3. Lint/CI: `mix precommit` — read the **entire** output (no head/tail/grep); must be 100% clean (credo, biome, tests, coverage).
4. JS is untouched; `mix precommit` covers `mix assets.check`. Optionally `cd assets && pnpm vitest run` / `mix assets.test` to confirm no collateral damage.

## Open questions / decisions for the user
1. **Visibility scope.** The sidebar filters by user (`created_by_user_id == user_id or shared`), but the tool has no user id in `ctx` (turn.ex:186-209) and the sibling tools `agents-query`/`agents-send`/`agents-archive` are already space-scoped (agents.ex:288-296, tool_loop.ex:420-437). **Recommendation:** space-scoped (all non-archived agents in the space) — confirm this is intended over mirroring the per-user filter.
2. **Do broken/`model_missing` agents count?** They are non-archived, so the merge includes them (as the sidebar's main tree does), but they can't be queried. Confirm whether to include them as-is (recommended, consistent) or exclude `status == :model_missing` / unloadable rows from the tool result.
3. **Fate of `Nest.Agents.list_agents_info_for_space/1`.** It is used only by this tool (lib) and tests. Either repurpose it (recommended — single space-listing entry point, no dead code) or keep it registry-only and add a separate `list_non_archived_agents_for_space/1` (leaves a lib-unused function; note AGENTS.md forbids removing tests without your request).
4. **Vocation for DB-only rows — resolved:** `vocation_slug` is resolved from the persisted `vocation_id` (`Visibility.vocation_slugs_by_id/0`), so DB-only rows report the real slug rather than `nil`.

No dependency on other open issues was found; this is self-contained in `Nest.Agents.Visibility`, `Nest.Agents`, `ToolLoop`, and `lib/nest/tools.ex`.
