# Sandbox Refactor Plan

## Overview
Currently, the sandbox executor is completely hardcoded. Every agent gets the exact same filesystem and network permissions, regardless of its configured `mode`. This refactor will make the sandbox dynamically respect per-mode capabilities (`caps`) defined in the Vocation schema.

## Problem Statement
- `ShellCmd.build_bwrap_args/2` hardcodes `--unshare-net`, `--ro-bind / /`, and workspace/tmp binds.
- The `Tools` module passes `workspace_path` and `tmp_path` directly to execution without checking mode restrictions.
- Agent `mode` is stored but never consulted for permission enforcement.
- No mechanism exists to switch modes at runtime or adjust sandbox profiles accordingly.

## Target Architecture

```
Agent (state.mode) 
  → Vocations.get_mode_caps(agent.mode)
    → Sandbox.build(caps, tmp_path)
      → bwrap args dynamically generated
        → ShellCmd.execute(command, sandbox_args)
```

## Implementation Phases

### Phase 1: Sandbox Module & Dynamic Args Builder
**Goal**: Decouple sandbox arg generation from hardcoded values. Create a dedicated module that builds bwrap arguments based on a `caps` map.

**Changes**:
- Create `lib/nest/sandbox.ex`
- Define `Sandbox.build(caps :: map(), tmp_path :: String.t() | nil) :: [String.t()]`
- `caps` structure:
  ```elixir
  %Sandbox.Caps{
    net: true | false,
    fs: %Sandbox.Fs{
      read: [String.t()] | [:workspace],
      write: [String.t() | :workspace]
    }
  }
  ```
- Implement path resolution: `:workspace` → resolved to actual workspace directory.
- Implement flag generation: `--unshare-net` or `--share-net`, `--ro-bind` vs `--bind` per path.
- Handle `/tmp` bind mount (read-only vs read-write based on `fs.write`).

**Migration**:
- Rename/refactor `Nest.Tools.ShellCmd` to delegate to `Sandbox`.
- `ShellCmd.execute/4` becomes `Sandbox.run(caps, command, workspace_path, tmp_path)`.

### Phase 2: Vocation Modes Schema & Validation
**Goal**: Enforce the correct structure for `vocation.modes` in the database.

**Changes**:
- Add validation in `Vocations.Vocation.changeset/2` for `modes`:
  - Must be a map
  - Each value must be a map containing `caps`
  - `caps` must contain `net`, `fs.read` (list), `fs.write` (list)
- Update DB migration if the JSONB type needs adjustment (currently `:map`, which is fine).
- Add `Sandbox.Caps` struct for type safety when parsing modes.

### Phase 3: Tool Execution Refactoring
**Goal**: Pass sandbox capabilities through the tool execution chain.

**Changes**:
- Update `Tools.get_functions/3` to accept `agent_id` and `vocation` instead of raw `workspace_path` and `tmp_path`.
- LangChain `Function` callbacks will receive a `context` map.
- Store `%{caps: caps, workspace_path: path, tmp_path: tmp}` in the LangChain context when building functions.
- In tool implementations (`read_file`, `write_file`, `shell_cmd`):
  - Extract `caps` from `context`
  - Validate permissions before execution (e.g., block `write_file` if `caps.fs.write` doesn't include `:workspace` or the target path)
  - Pass `caps` to `Sandbox.run/4`

**Refactored Function Signature**:
```elixir
@spec execute(String.t(), Sandbox.caps(), String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
```

### Phase 4: Mode Switching & Agent Integration
**Goal**: Allow agents to change modes at runtime, updating their sandbox context accordingly.

**Changes**:
- Add `set_mode(pid, mode_name)` to `Nest.Agents.Agent`
- Implement `handle_cast({:set_mode, mode_name}, state)`:
  - Validate `mode_name` exists in `state.vocation.modes`
  - Update `state.mode`
  - Rebuild LangChain tools with new `caps` from context (or pass updated caps in runtime context)
  - Broadcast mode change event
- Update `get_public_info/1` to include `mode: state.mode`
- Ensure tmp_path is preserved across mode switches (don't recreate on switch)

### Phase 5: Seeding & UI Hooks
**Goal**: Provide default vocation examples with meaningful modes and wire up the frontend to display/switch modes.

**Changes**:
- Add seed data with sample vocations (e.g., `Planner` with read-only caps, `Builder` with write caps + net)
- Update `LobbyChannel` to expose current agent mode
- Add UI dropdown for mode switching on the agent panel (disabled/hidden for non-mode-enabled vocations)

## Testing Strategy

### Unit Tests
1. **Sandbox.Build**
   - `caps.net = false` → includes `--unshare-net`
   - `caps.fs.read = ["/"]` → includes `--ro-bind / /`
   - `caps.fs.write = [:workspace]` → includes `--bind workspace workspace`
   - `caps.fs.write = []` → no write binds
   - `tmp_path` provided → `--bind tmp_path /tmp`
2. **Caps Validation**
   - Missing `caps` in mode → changeset error
   - Invalid fs paths → changeset error
3. **Tool Enforcement**
   - `write_file` in read-only mode → returns `{:error, "Permission denied"}`
   - `shell_cmd` in offline mode → `caps.net = false`, sandbox blocks network

### Integration Tests
1. Agent spawn with `plan` mode → verify sandbox args match read-only caps
2. Agent spawn with `build` mode → verify sandbox args match write+net caps
3. Mode switch at runtime → verify subsequent commands use new sandbox args
4. Workspace path resolution with `:workspace` symbol

## File Changes Summary
| File | Action | Description |
|------|--------|-------------|
| `lib/nest/sandbox.ex` | **Create** | New module for bwrap args, fs resolution, tmp handling |
| `lib/nest/tools/shell_cmd.ex` | **Modify** | Delegate to `Sandbox`, update signatures |
| `lib/nest/tools.ex` | **Modify** | Pass `caps` via LangChain context, add permission checks |
| `lib/nest/agents/agent.ex` | **Modify** | Add `set_mode`, `handle_cast`, update `get_public_info` |
| `lib/nest/vocations/vocation.ex` | **Modify** | Add `modes` changeset validation |
| `priv/repo/seeds.exs` | **Modify** | Add vocation examples with `modes` populated |

## Open Questions / Decisions
1. **Tmp path handling**: Should `/tmp` be read-only or write per mode? Current design gives all agents a writable `/tmp`. I'll keep it writable but note it in the caps for future read-only modes.
2. **Tool context rebuild on mode switch**: Does switching modes require rebuilding the entire LangChain tool list? Yes, to update the context map. We'll optimize by caching and only rebuilding on `set_mode`.
3. **Network in sandbox**: `--unshare-net` vs `--share-net`. `bwrap` defaults to sharing the host network unless `--unshare-net` is passed. We'll explicitly pass `--unshare-net` when `caps.net == false`.
