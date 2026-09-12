# agents-batch — implementation plan (working notes)

Fork-join tool: coordinator fans one templated instruction over a set of
items to concurrent sub-agents, gets back ONE aggregated result (JSON list
of each child's final response string, in item order). Model makes ONE tool
call, no bookkeeping, never enumerates prompts.

## API (LOCKED)
```
agents-batch(
  template,            # optional; {item} and {index} substituted. If present must contain {item} or {index} else error.
  items,               # XOR with glob: literal list of item strings
  glob,                # resolved via Sandbox.glob
  vocation_id, model,  # per-child (optional, default inherit parent vocation / model)
  timeout,             # PER-ITEM ms, default 300000
  archive,             # default TRUE (children archived after responding)
  name_prefix,         # optional observability prefix for auto names
  max_concurrency,     # per-call, clamped to ceiling 16 (default from DotConfig = 4)
  on_error,            # "collect" (default) | "fail_fast"
  max_result_tokens    # standard cap/offload
)
```
Result content = JSON array of N strings (item order). Uses standard
max_result_tokens cap: if JSON exceeds effective cap, write full JSON to
`<tmp_path>/agents-batch-<token>.json`, return short pointer+head summary.
Failure slots: failed/timed-out item = marker string in its slot. is_error
TRUE only for whole-call failure (bad glob / no items / missing {item} /
both-or-neither of items+glob).

## Files already DONE this session
- lib/nest/dot_config.ex: @default_max_concurrency 4, merge max_concurrency,
  max_concurrency/1, default_max_concurrency/0, parse_max_concurrency/1, parse
  in load/1. VERIFIED.
- lib/nest/agents/agent/config.ex: added @max_batch_concurrency_ceiling 16,
  configured_max_batch_concurrency/0, clamp_batch_concurrency/1. VERIFIED compiles.
- lib/nest/sandbox.ex: added glob/4 (self-contained expander: *, ?, **).
  @glob_limit 1000 -> {:error, :glob_too_broad}. split_while first-glob split,
  Path.join drops leading "/" so maybe_make_absolute? re-prepends "/".
  do_glob_walk(dir, rest, acc, limit) with ** clause (zero-seg + recurse subdirs),
  normal-seg reduce_while {:cont,...}. seg_match/2 recursive *,? matcher
  (no :fnmatch — not in this OTP). VERIFIED via /tmp scripts: sub/*.txt, sub/*.*,
  sub/**/c.txt, abs, literal, nomatch->[], bad->[] (total matcher, no raise),
  toobroad, caps-filter (denied file filtered), no-ws error.

## STILL TO DO (in order)
1. BatchSizer.Overflow: extract public `write(content, ctx) -> path|nil`
   (the tmp-file write); BatchSizer.write_to_tmp/2 delegates to it.
2. ProjectedSize: add `project(%ToolCall{name:"agents-batch"}, _)` clause
   (project the offload-summary baseline; inline footprint bounded by cap).
   NOTE: also required because BatchSizer preflight projects every regular
   tool; but agents-batch is routed via sub_agent_tool? so it's SPLIT OUT of
   BatchSizer before preflight — so a ProjectedSize clause is NOT strictly
   needed. Still add one for the catch-all honesty / test parity? DECISION:
   add it (cheap, matches "real new tool gets a clause" rule) but it will be
   dead in the sub-agent split path; harmless.
   RE-DECISION after reading run_batch: sub-agent tools are split out BEFORE
   BatchSizer.run, so agents-batch NEVER hits preflight. Do NOT add a
   ProjectedSize clause (it'd be dead code). The existing sub-agent tools
   (agents-spawn etc.) have NO ProjectedSize clause. CONFIRM: no clause.
3. BatchLoop (lib/nest/agents/agent/batch_loop.ex) — NEW module:
   - resolve_items(args, ctx) -> {:ok,[item]}|{:error,reason}
     items XOR glob; glob via Sandbox.glob(glob, caps_of(ctx), workspace_of(ctx));
     empty -> error "no items".
   - render(template|nil, index, item) -> {:ok, text}|{:error, reason}
     nil template => item is the instruction. template present => must contain
     "{item}" or "{index}"; substitute.
   - run(ctx, tc) -> content string (JSON) or raises? NO: return
     {:ok, content} | {:error, reason}. ToolLoop maps to ToolResult is_error.
   - pacer: max_conc = Config.clamp_batch_concurrency(arg); for each item
     (pace to max_conc) GenServer.call(parent_via_tuple,
       {:spawn_agent_request, self(), spawn_opts}); then selective receive
     loop over {:spawn_agent_result,name,resp}/{:spawn_agent_error,name,reason};
     per-item deadline via System.monotonic_time; on deadline ->
     GenServer.call(parent, {:abandon_child, self(), name}) + timeout marker.
     results[index]=string; assemble in index order; offload if over cap.
   - parent_via_tuple = AgentsRegistry.via_tuple(ctx.space_id, ctx.agent_name).
   - name: Supervisor.generate_unique_name_for_space(space_id) then prepend
     name_prefix if given (ensure uniqueness).
4. ToolLoop: add "agents-batch" to sub_agent_tool?/1 list; add
   run_sub_agent_tool clause -> run_agents_batch(ctx, tc) -> build_tool_result
   (is_error from {:error,_}).
5. SubAgent: add handle_abandon_child(state, task_pid, name) — stop child
   (Supervisor.stop_agent), drop from pending_children + archiving.
   callbacks.ex: add handle_call({:abandon_child, task_pid, name}, _from, state)
   -> SubAgent.handle_abandon_child(...).
6. Tools.get_function/3: add "agents-batch" to the sub-agent name list;
   sub_agent_tool_function("agents-batch") -> batch_agent_function() stub.
   Write schema (params above; required: none — items XOR glob validated at
   runtime). Description must carry "one call, one aggregate; use glob for
   large sets" + "archive defaults to true".
7. seeds.exs: add "agents-batch" to agents_tools list.
8. init.ex maybe_exclude_spawn/2: reject both "agents-spawn" AND
   "agents-batch" when exclude_spawn.
9. compaction/result_handler.ex exclude_spawn_at_max_depth/2 (~line 165):
   reject both.
10. Tests:
    - Sandbox.glob unit: test/nest/sandbox_test.exs (append describe).
    - BatchLoop unit: resolve_items, render, assemble, offload (no LLM).
    - E2E MockClient: test/nest/agents/agent/agents_batch_test.exs.
      PATTERN from clone_agent_flow_test.exs: Mimic.stub(Nest.Agents,:chat,
      fn _s,_n,_c -> :ok end) so children don't run LLM; collect N
      agent:created lobby broadcasts (filter parentName) to get child names
      in item order; cast {:child_completed, name, "response-for-<name>", usage}
      to parent for each; assert tool result JSON == N strings in order;
      descendant_usage merged; pending_children empty; children at depth+1.
      N <= max_concurrency so all spawn up front.
      Usage map shape (9 fields) — see clone test cast_child_completed_to_parent.
    - Touch-up: test/support/agent_test_helpers.ex @agents_tools add
      "agents-batch"; test/nest/tools_test.exs (schema/registry); system_prompt
      depth filter test if it enumerates agents tools.
11. Run `mix precommit` full (no head/tail/grep) until 100% clean.

## Key facts / invariants
- ctx (from ChatTurnSpawner) has: agent_pid, agent_name, space_id,
  client_config, tools, tool_choice, caps, context_limit, messages, tmp_path,
  workspace_path, crossed_thresholds. ToolLoop.execute(ctx, state, tool_calls);
  sub-agent handlers get (ctx, tc).
- CapCalculator.usable_remaining(ctx) + effective_max_result_tokens(tc, usable).
- SubAgent pending_children = %{child_name => worker_pid}; multiple batch
  children -> SAME worker pid (distinct names, fine). handle_child_completed
  merges descendant_usage, drops pending, sends {:spawn_agent_result,name,resp}
  to worker pid, archives if in archiving.
- Coordinator GenServer is NOT blocked during batch (batch runs in tool worker
  Task under TaskSupervisor). So it processes :spawn_agent_request /
  :child_completed / :abandon_child normally. No deadlock (coordinator only
  sends to worker, never calls it).
- force_subagent_mock: true in test config — spawned children auto-swap to
  MockClient; but we stub Agents.chat so they never run anyway.
- Config.clamp_batch_concurrency/1 reads DotConfig each call (like other
  configured_* helpers). Ceiling 16.
- Estimator.estimate/1 for token sizes; per_message_overhead ~10.
- Registry.via_tuple(space_id, name) = AgentsRegistry.
- Elixir 1.18.4 / OTP 27. No File.wildcard, no :fnmatch.
- mix deps.get was run. mix compile --warnings-as-errors must pass.

## Design decisions approved (user said "Go")
- failure slot = "[error: ...]" marker string; is_error only for whole-call fail.
- timeout = abandon + stop the child.
- glob returns regular files only.
