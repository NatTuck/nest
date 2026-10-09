# The Elixir coverage gate

**The gate lives in `./coveralls.json`, not in `mix.exs`.** It is
`coverage_options.minimum_coverage` there, currently **85**.

## The gate's input used to swing across its own threshold

An earlier version of this note claimed the `[TOTAL]` was unchanged before and
after the gate was introduced. That was wrong: the total was **not** stable,
and with the gate armed the suite failed intermittently on it:

```
1984 tests, 0 failures
[TOTAL]  84.9%
FAILED: Expected minimum coverage of 85%, got 84.9%.      # exit 1
```

reproducible with `--seed 617239`, at roughly one full-suite run in five.
The whole swing was one module: `lib/nest/chat_model.ex` reported **65.0%**
(37 missed) on the failing profile and 84.9–88.6% on passing ones, and the
functions that flipped together (`from_provider/2`, `find_by_provider`,
`find_by_tag`, `list_models/1`, `new!/1`'s raise clauses) were either all
counted or all missed.

**Root cause.** `test/nest/agents/agent/config_test.exs` called
`Mimic.copy(Nest.ChatModel)` from a per-test `setup` in an `async: true`
module. `Mimic.copy/1` swaps the module for its proxy and re-imports coverdata
around the swap, so a copy that runs *during* the suite makes that module's
counting depend on where the copying test lands relative to the tests that
exercise the module for real (`ChatModelTest`, the probe/list tests, the
channel and agent tests that use it).

**Fix.** `Nest.ChatModel` is now copied once in `test/test_helper.exs`, beside
the other global copies, and the per-test copy is gone. The same audit turned
up `Nest.Agents.Registry` copied per-test from `wait_loop_test.exs`'s
`stub_live/1`; it is exercised by other tests too, so it was hoisted the same
way. (The remaining per-test `Mimic.copy` calls — `Nest.Agents.Agent` in
`agents_test.exs`, `Nest.Agents` in the clone/batch/tool-loop tests — are
no-ops: `Mimic.copy/1` returns `:ok` for a module that is already copied
(`deps/mimic/lib/mimic.ex:378`), and those modules are in `test_helper.exs`
already. They were left alone as harmless.)

Determinism is checked by running the full `--cover` suite under several
explicit seeds (including `617239`) and the default seed; the runs and their
totals are recorded in the W1 round's `notes/test-runs/` logs.

## Why it is not in `mix.exs`

`test_coverage` in `mix.exs` carries `[tool: ExCoveralls, summary: [threshold: 80]]`,
and it is tempting to add `minimum_coverage: 85` next to it. That key is
**inert** for `mix test --cover` in ExCoveralls 0.18.5:

* `ExCoveralls.Stats.ensure_minimum_coverage/1` reads `coverage_options` from
  `ExCoveralls.Settings`, which reads a `coveralls.json` file
  (`~/.excoveralls/coveralls.json` merged with `<project root>/coveralls.json`),
  never the mix project config.
* Only the `mix coveralls*` report tasks call it. `mix test --cover` reaches
  `ExCoveralls.Local.execute/2` and thus the check, but with the settings read
  from that JSON file.
* Verified: with only the `mix.exs` key present, a subset run at `[TOTAL] 18.6%`
  exited **0**. With `coveralls.json` present the same run exits **1** with
  `FAILED: Expected minimum coverage of 85%, got 18.6%.`

`summary: [threshold: 80]` is likewise not read by ExCoveralls 0.18.5
(`ExCoveralls.Local.format_total/1` prints the total with no colour and nothing
in `Local` reads `options[:summary]`), so the `mix.exs` block is left exactly as
it was and the JSON file is the single source of the gate.

## The margin, as a checkable statement

The gate is a comparison against the whole tree, so what matters is how much
jitter it takes to cross it:

* 7850 relevant lines, so 85% means at most **1177 missed**; the gate fails at
  **≥ 1178 missed** (`(7850 - 1178) / 7850 = 84.99%`).
* A clean run misses **1153** (`[TOTAL] 85.3%`), i.e. the margin is **25 missed
  lines** — roughly 0.3 percentage points.
* The observed jitter is **1–2 lines per run**, from **two** sources, and
  neither is seed-stable:
  * `lib/nest/llm/mock_client.ex` — `91.3%` (9 missed) or `92.3%` (8 missed);
    seen in one of the six runs.
  * `test/support/agent_test_lifecycle.ex` — `88.5%` (4 missed) or `85.7%`
    (5 missed); seen in one of the reviewers' runs, **not** reproduced in those
    six.

  So the attribution of either to a *specific* seed is not reproducible — the
  pair is the honest description, and both are far inside the 25-line margin.
* Which is why six consecutive `--cover` runs (including the seed that
  reproduced the original failure) all report `85.3%` and exit 0. The earlier
  instability was not jitter inside the margin: it was a single module
  (`lib/nest/chat_model.ex`) dropping from ~88% to 65% — 37 missed lines at
  once — which is the bug fixed above.

## Why every key in the file is mirrored from the dependency

`Settings.read_config/2` returns the project file's `coverage_options` map
**instead of** the dependency's default map
(`deps/excoveralls/lib/conf/coveralls.json`) — it does not merge the two. So
`coveralls.json` mirrors that default map verbatim and changes exactly one
value:

| key | value | why |
| --- | --- | --- |
| `treat_no_relevant_lines_as_covered` | `false` | dep default: a file with no relevant lines still reports `0.0%` |
| `output_dir` | `"cover/"` | dep default: the HTML report directory (`mix coveralls.html`) |
| `minimum_coverage` | `85` | **the only change** (dep default `0`) |
| `floor_coverage` | `true` | dep default: percentages are floored, not ceiled |
| `terminal_options.file_column_width` | `40` | dep default: the `FILE` column width |

`default_stop_words` / `custom_stop_words` are deliberately absent: an absent
key falls back to the dependency's default file, so the stop-word set is
unchanged. That matters because stop words decide which lines count as
"relevant" and would move every reported number.

Resolved settings, checked without running the suite
(`MIX_ENV=test mix run --no-start -e 'ExCoveralls.Settings.get_coverage_options() |> IO.inspect()'`):

    %{"floor_coverage" => true, "minimum_coverage" => 85,
      "output_dir" => "cover/", "treat_no_relevant_lines_as_covered" => false}
    stop words (from dep default): 8    print_files: true    file_column_width: 40

The mirrored keys are what make the file a pure addition: the resolved settings
below are the dependency's defaults with `minimum_coverage` raised from 0 to 85,
so the gate changes whether the run *fails*, not what it measures.

## JS side

There is no `assets/vitest.config.js`; the Vitest config is `assets/vite.config.ts`
(`test.coverage.thresholds` = `{lines: 90, functions: 90, branches: 90, statements: 90}`),
and `mix assets.test` runs `pnpm vitest run --coverage`, so JS coverage is
already gated (stricter, all four metrics).
