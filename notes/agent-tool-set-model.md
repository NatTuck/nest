# Agent Tool: Set Model + Models-List

## Summary

Adds a `models-list` tool so agents can discover which models are
available, and an optional `model` argument to `agents-spawn` so a
parent can spawn a sub-agent on a specific model. Model visibility is
controlled by a new per-provider `expose_models` flag.

## Provider `expose_models` flag

- `Nest.DotConfig.Provider` gains an `expose_models` field, parsed from
  the optional `expose-models` TOML key (boolean; defaults to `false`).
  Invalid values raise at config load (`parse_expose_models/2` in
  `lib/nest/dot_config.ex`).
- `Nest.DotConfig.Writer` serializes `expose-models` back to
  `local.toml`, so the flag survives a GUI save round-trip.
- `NestWeb.LobbyChannel.Providers` serializes/parses `"expose_models"`
  for the GUI; `emptyProvider()` and the ProviderEditor gain the
  "Expose models in list-models" checkbox.

## `models-list` tool

- Definition lives in `Nest.Tools` (`models_list_function/0`), resolved
  like the other `agents-*` tools; its `function` is a stub.
- Real execution is inline in `Nest.Agents.Agent.ToolLoop`
  (`run_models_list/1`), mirroring `agents-list`. It:
  - reads configured providers with `expose_models: true`
    (`DotConfig.load/0`),
  - filters `Models.list/0` to those providers,
  - optionally narrows by a `provider` argument,
  - returns one `"provider/model-name"` line per model (truncated to a
    4k-char cap).
- Model names that themselves contain `/` (e.g.
  `vllm/Qwen/Qwen3.5-122B-A10B-FP8`) are preserved intact.
- Added to the seed vocations' `agents_tools` list (and the matching
  test-support `@agents_tools` invariant) so agents advertise it.

## `agents-spawn` `model` argument

- The tool schema (and its description) documents an optional `model`
  parameter in `"provider/model-name"` format (the same strings
  `models-list` returns).
- `spawn_opts_from_args/1` extracts `model` and carries it in the spawn
  opts.
- `Nest.Agents.Agent.SubAgent.resolve_model_override/1` parses it by
  splitting on the FIRST `/` (provider / model-name); absent/empty means
  "inherit the parent's model"; unparseable values reject the spawn with
  `{:error, {:invalid_model, value}}`.
- `Supervisor.spawn_agent_in_space/4` (fresh) and
  `Supervisor.start_agent_with_parent/3` (clone) accept an optional
  model map, threaded into `build_fresh_child_attrs/6` /
  `Agent.build_child_attrs/5`. Both default to the parent's model.

## Files

- `lib/nest/dot_config.ex` (+ `parse_provider_models/1` extraction)
- `lib/nest/dot_config/writer.ex`
- `lib/nest_web/channels/lobby_channel/providers.ex`
- `lib/nest/tools.ex`
- `lib/nest/agents/agent/tool_loop.ex`
- `lib/nest/agents/agent/sub_agent.ex`
- `lib/nest/agents/supervisor.ex`
- `lib/nest/agents/agent.ex`
- `priv/repo/seeds.exs`
- `assets/js/components/providerConstants.js`, `ProviderEditor.jsx`
- Tests: `tool_loop_models_list_test.exs`, `tools_test.exs`,
  `dot_config_test.exs`, `lobby_channel/providers_test.exs`,
  `supervisor_spawn_test.exs`, `supervisor_subagent_test.exs`,
  `sub_agent_tools_test.exs`, `ProviderEditor.test.jsx`

## Notes

- The dev DB vocations need a re-run of `mix run priv/repo/seeds.exs`
  (idempotent) to advertise `models-list` on existing vocations.
- `models-list` is read-only and stays available at max depth (only
  `agents-spawn` is stripped there).
