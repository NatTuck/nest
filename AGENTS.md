This is a web application written using the Phoenix web framework with a React
user interface.

All browser JS and other assets are in ./assets. This is most of the UI.

## ⚠️ CRITICAL: JS Package Location

Our JavaScript/browser code lives exclusively in `./assets/`.

- Our package manager is pnpm. Don't use npm or others.
- **ALWAYS** `cd assets` or use the --dir flag on pnpm when running any JS package commands
- **NEVER** run `pnpm` commands in the project root. If you see `package.json`, `node_modules`, or 
other similar JS artifacts in the project root, something is wrong - clean them up immediately

## ⚠️ CRITICAL: Testing Protocol

- Do not run `mix precommit` except exactly once during a pre-commit or review.
Do normal testing by running `mix test` and/or (`pnpm --dir assets test` or
`cd assets && ./node_modules/.bin/vitest run`).
- Use as few test runs as you can. They take time.
- Don't ever run the same test command repeatedly in a loop without an explicit
human request to do exactly that.
- Performance on `mix test` isn't optional. It should be 4 seconds on vampire.
If it's slower than that after your work, then it's time to put in some serious
optimization effort.
- *ABSOLUTELY NEVER* pipe or redirect the result of any test command. Directly
read the *entire* output.

## Important: Core Process Rules

* Never `git stash`, at all.
- Never revert stuff, not even temporarily, without an explicit human request. 
If the tree is so screwed up that reverting is the only option then stop and report.
- Do not attempt to change AGENTS.md or .nest.
- If the *user* has made changes to AGENTS.md or .nest and has staged/committed
those changes, *ABSOLUTELY NEVER* unstage or revert them. Let them flow
naturally with the current work stream.

## Workflow

- When working on a task or batch of tasks, generally produce one single local
branch that will produce one remote PR to review and merge.
- If that work can be broken up, use local worktrees and then merge that work
into our PR branch locally.

## Project Design

### LLM Calls

- Once we have an active conversation, we *NEVER* make changes that would
disrupt prefix caching, except on compaction or user-initiated model change
(including enabling / disabling thinking). This is a rule about *runtime*, it
doesn't restrict codebase changes during development.
- Specifically, that means our main system message is fixed once set and does
not change except potentially on compaction.
- The main system message explains things that will always be true for the
current session. This includes a fixed vocation, a fixed mode *catalog* (the two
modes are code constants — `Nest.Modes` — so the catalog's bytes are the same for
every agent in a space) and a project root (and thus an AGENTS.md if present).
The agent's own *mode* is deliberately not in it: it is a per-agent runtime
property that can change while the agent works, so it travels on the messages
instead.
- All role: user messages are tagged with the sender name and the recipient's
mode.

### Sandbox

- Filesystem access goes through the active backend — no host-side emulation of
`read`/`stat`/`glob`, no host fast path.
- There's no such thing as a "spelling" of a /tmp path. Agents see one
consistent view of the world, from within their sandbox (if any). That word
"spelling" needs to be removed in this context everywhere but this bullet.
- `caps["net"]` has one source (`spaces.network_access`) and one funnel
(`ProjectConfig.resolve_caps/2`); nothing under `lib/nest/sandbox/` reads the
spaces schema.
- Never imply a backend enforces more than it does — a `none` space enforces no
cap at all, and anything that offers or documents a backend has to say so.
- A new path that starts an agent or runs a command needs the workspace gate:
`.nest` and `AGENTS.md` are masked read-only, and a non-regular file at either
path is refused on every backend.
- Anything that composes a prompt or runs a command gets the agent's *real*
mounts; a missing scratch loses the agent's own files silently.
- Every `rm_rf` of a `none` scratch requires the `.nest-scratch` marker, and
nothing may mark a directory Nest did not create.

### Modes

- Every mode change goes through `Nest.Agents.Agent.ModeAuthority` — it is the
only place the monotone rule lives, so a new path that sets a mode must use it.
What each mode means and who may move whom is in `Nest.Modes` and in the prompt;
do not restate it here.
- A mode change never propagates to existing descendants: a root flipped to
`plan` must not jam a worker that is mid-task in `act`.

### UI Transparency

- We don't hide stuff from the user. If it gets sent to the LLM or the LLM sends
it back then it's visible in the UI (maybe collapsed, in rare edge cases may be
just in the API log, but the UI always includes everything that happened).
- We don't quietly hide UI elements when expected data is missing. If data is missing
so we can't render a UI element we replace it with an obvious error indicator (or just
entirely crash with a clear error message to make sure tests can't possibly pass under
those circumstances). Even optional data should show a clear UI indicator that it's
missing rather than nothing.

## Project guidelines

### Code Reviews

- Read SMELLS.md. Check the proposed changes for code stench.
- When reviewing a change, check for changes to SMELLS.md. If it was weakened or
expanded with bloated, redundant prose, the change fails review.
- There's no such thing as "out of scope" or "pre-existing issue" for this step.
Either we're 100% clean (no fails, no warnings, no style suggestions, no test
log prints, etc) or we're not.
- **ABSOLUTELY NEVER** run `git stash`. NEVER. NOT FOR ANY REASON, NO EXCUSES.
- You can use git worktrees, but any work from worktrees should be merged back
into the active feature branch in the workspace and not pushed directly to any
remote.

### During Development

- Never run any dev servers, neither `mix phx.server` nor `npx vite`. The user will manage that manually.
- Code must pass lints (credo, biome). Do not modify lint configs (except when adding new high value
lints or fixing clear bugs in lints) or bypass the lints. 
- FIX THE LINT ISSUES. ALWAYS. NO EXCUSES. IT DOES NOT MATTER IF IT WAS ALREADY THERE.
- Limit length and complexity of both functions and files. When complexity gets
  too great, first factor out potentially reusable components then factor out
  single-use helper functions if there isn't enough reusable logic to get the
  function simple enough.
- **NEVER** downgrade anything without an explicit user request.
- **NEVER** remove or skip tests without explicit user request. If tests are
failing, they are failing.
- **NEVER** fail to implement requested tests and then claim you've completed
the task.
- **NEVER** remove correct partial testing logic to get a test to pass. Finish
the test.
- **NEVER** look at the git history of code you haven't read as a debugging or
explanation tool.

### Testing Rules

- NO development work is done until `mix precommit` runs perfectly with no
errors or warnings. NO EXCEPTIONS, NO EXCUSES.
- We care about test run speed. Don't significantly slow down the tests,
especially by adding anti-patterns like long timeouts or wait loops.
- Never sleep or intentionally delay for a fixed time in tests. Ever. No
exceptions, no excuses.
- Absolutely never run tests several times in a loop without an explicit
user request. Really, do not run the same tests more than once in a row.
- If something noteworthy and bad happens or an unexpected error occurs, the program
*should* log a warning or error to the console.
- Tests must not print to the console except during debugging. If logger output
appears in tests, it must be fixed by:
  - If expected, capture and assert.
  - If unexpected, fix the bug.
  - If inconsistent, the bug may be a race condition. You still need to fix it.
  - Note: capture_log may return extra logs from concurrent tests. That means
  we can safely assert on inclusion, but not exclusion or exact output.
  - Note: Double check that the log is guaranteed to happen before the end of
  the capture_log block.
- Some tests may capture and discard log lines with explanatory comments. Those
should not be changed unless the code they test changed, but you may not add
more without explicit user instruction.
- It doesn't matter if the test failures or test prints were there before you
started working. If you see them, fix them.
- *NEVER* sleep directly in tests; use vi.waitFor for async conditions or one of
the Elixir helpers (e.g. eventually).
- Clean patterns without accessing mock internals
- Merge tests with same setup and non-conflicting assertions
- There should *NEVER* be two tests with identical (or compatible) setup that
differ only in that they each do a different single assertion.
- Tests that have only one assertion in them are extremely suspect as likely
violating the previous rule.
- A test that sometimes fails is *MUCH WORSE* than a test that always fails.
Make it always fail, and make it log "FIXME: HIGH PRIORITY FLAKY TEST".
- **NO** test may be async: false without a clear comment as to why that's
actually required.
- **NEVER EVER** increase an existing timeout to try to get a test to pass
unless you have a concrete reason to believe that there's some external reason
why we expect things to take a specific amount of time. A test unexpectedly
hitting a timeout, even occasionally, means the test is critically broken and
needs to be fixed so it's not timing-dependent.

### Test Coverage

- The required test coverage must always be met.
- Required test coverage may not go down, and should be increased every time new
coverage is added until the required test coverage for a given language (Elixir,
JS) is 90%.
- To increase coverage, simple functions and branches that aren't being used,
aren't essential to a module's external interface, and aren't a functional
requirement can be removed. Simplifying the code to better match the actual
current purpose is a good thing.

### Using Github

- Our PR merges are always squashes.
- That means every concurrent PR will need a merge. Do the merge, don't
rebase and force push.

### JavaScript

- Our JS stuff lives in ./assets. If there is a package.json or node_modules
directory in the project root something has gone horribly wrong and we need to
immediately stop and fix it.
- We're using pnpm for JS package management.
- Use `mix assets.check` to run the biome checks.
- Use `mix assets.test` to run the JS tests.
- When running any `pnpm`, `pnpx` or other JS command **always** start with an
explicit `cd assets && ...`.
- Use `mix precommit` alias when you are done with all changes and fix any
pending issues.

### React

- Use modern react and hooks.
- Use a single zustand store for transient in-browser state.

### Remember how to use OTP and Elixir

- If we have a registry, we should use it. Avoid raw BEAM pids in favor of
via_registry(name) type patterns.
- If we're communicating with a GenServer, typically it's better to do a call or
cast than just sending a raw message. There's no need for handle_info when we
control both ends of the communication.
- Never `String.to_atom/1` on user input — it is a memory leak the compiler
cannot see.
- Elixir is functional, = is rebinding not assignment, and you can't use square
brackets to index a list (and probably shouldn't want to).
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

### HTTP Client

- Use the already included and available `:req` (`Req`) library for HTTP
requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by
default and is the preferred HTTP client for Phoenix apps.

### Phoenix / HEEx

- Avoid LiveView for web pages in favor of React.
- `<.flash_group>` must live in `NestWeb.Layouts` (the `layouts.ex` module)
only. You are **forbidden** from calling it elsewhere.
- HEEx class attrs support lists. When using multiple classes, **always** use
list `[...]` syntax: ``` class={["px-2 text-white", @flag && "py-5"]} ```
- `<%= %>` works in tag bodies; use `{...}` for interpolation within tag
attributes and for simple value interpolation in tag bodies. Use `<%= %>` for
block constructs (`if`, `cond`, `case`, `for`) within tag bodies.
- Phoenix PubSub does *not* deduplicate multiple subscriptions to the same
topic. Two subs means two copies of each message.
- `Phoenix.View` no longer is needed or included with Phoenix, don't use it

### UI/UX & design guidelines

- We're using Tailwind and @llamaindex/chat-ui
- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions
