This is a web application written using the Phoenix web framework with a React
user interface.

All browser JS and other assets are in ./assets. This is most of the UI.

## ⚠️ CRITICAL: JS Package Location

Our JavaScript/browser code lives exclusively in `./assets/`.

- Our package manager is pnpm. Don't use npm or others.
- **NEVER** run `pnpm` commands in the project root.
- **ALWAYS** `cd assets` or use the --dir flag on pnpm when running any JS package commands
- If you see `package.json`, `node_modules`, or other similar JS artifacts in the project
root, something is wrong - clean them up immediately

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

## Important: Core Process Rules

* Never `git stash`, at all.
- Never revert stuff, not even temporarily, without an explicit human request. 
If the tree is so screwed up that reverting is the only option then stop and report.

### Sandbox reads always go through the active backend

- The sandbox's filesystem view *is* the active backend's view. There is **no
  host-side emulation** of `read`, `stat`, or `glob`: all three execute inside
  the sandbox, so their results come from exactly what the backend exposes and
  can never disagree with what a shell inside it sees.
- Which backend that is, is a **per-space, creation-only** choice
  (`spaces.sandbox_backend`: `bwrap`, `docker` or `none`). It is picked when the
  space is created and cannot be changed afterwards, because changing it would
  mean replacing the environment the space's agents run in. It travels to every
  command on the `Nest.Sandbox.Mounts` value, and `Nest.Sandbox.Backend` is the
  one dispatch point (`Nest.Tools.ShellCmd` is the only caller that matters).
- **Network access is the space's, not a mode's.** `spaces.network_access`
  (boolean, editable) is the only source of `caps["net"]`: it is resolved once at
  agent start and carried on `Nest.Sandbox.Mounts`, and
  `Nest.Sandbox.with_network_access/2` injects it at caps-resolution time (called
  from `Nest.ProjectConfig.resolve_caps/2`, the one funnel both resolution paths
  share). There is no per-mode `net` key left to read: `vocations.modes` is gone,
  and `Nest.Modes`' caps maps carry `net` only as a placeholder nothing reads.
  A value naming no space keeps `default_caps/0`'s `net: false`. Do not add a
  second place that reads either.
- `bwrap` (the default) enforces the mode's caps with binds and namespaces.
  `docker` runs **bwrap inside a container the space shares**, and the two bind
  the *same* list (`Nest.Sandbox.Binds`) — over the host there, over the derived
  image here. The container's root filesystem is the image, so the host's `/` is
  not visible in it and `caps.fs.read` is not what docker binds: **the image is
  the read set**, which makes it *stricter* than bwrap, not looser. `none` runs
  the bare command on the host, so **caps cannot be enforced** for that space
  (nor the read-only mask over `.nest` and `AGENTS.md`). Say all of that
  plainly wherever a backend is offered or documented; never imply otherwise.
  `notes/sandbox-backends.md` has the full table, the container flags bwrap
  needs and what they cost.
- **Two files are masked read-only in a writable workspace, not one**: `.nest`
  and `AGENTS.md`. Both are human-authored project config — one grants host
  access, the other is the project's policy — and an agent that can rewrite
  either drifts its own constraints. When a file is absent, `/dev/null` is
  masked over the path so it cannot be created either. Both are therefore read
  on the **host** by the runtime and *handed* to the sandbox as binds, so an
  agent's view of either is the host's file by construction. On a `none` space
  none of that holds, like every other cap.
- A `docker` space's container is keyed on **the space and the installation**,
  never on a caps signature or on the BEAM: it binds the superset a space can
  need (what a mode that writes the workspace gets) and the bwrap *inside* it
  tightens per call, so a read-only mode keeps its teeth without needing a
  container of its own. The name is therefore stable across restarts — nothing
  per-BEAM is bound any more, since the scratch is the container's own `/tmp` and
  the staging directory is keyed on the space — and the layout travels as a
  `nest.layout` **label** instead, which `ensure_container/3` compares so that a
  `.nest`, workspace, hardware or network change replaces the container rather
  than silently reusing the old environment. There is no sweep and no pid
  parsing: nothing is ever orphaned. `Nest.Sandbox.Installation` keeps two
  installations that share a space id from adopting each other's container.
  `Mounts.scratch` for a docker space is a path *inside* the container, which
  nothing on the host may create or write (`Mounts.host_scratch?/1`).
- Do **not** add a host fast path for any of them. There is no second spelling
  of a path an agent uses: the backend plus the two directories the sandbox
  binds — the workspace and the agent's own scratch directory — live in one
  `Nest.Sandbox.Mounts` value that travels with the turn, and `Nest.Sandbox` is
  what turns it into binds. A module that needs a real directory reads it from
  that value; none of them needs one in order to name a path an agent uses, and
  `/tmp/<agent-name>/...` is the only scratch spelling an agent is ever told
  about or hands back — on **every** backend.
- The path mapping lives in exactly one place: `Nest.Sandbox.Paths`.
- A workspace at or under `/tmp` is rejected **unconditionally**, because the
  space scratch dir is bound at `/tmp` and would shadow it. A workspace can
  never live under `/tmp`. A workspace that does not exist is rejected too.
  Both are rejected at the point the workspace is chosen (create-space,
  create-agent, `set_workspace`, edit-agent) and again at the final gate in
  `Nest.Sandbox.build/4`.
- A `none` space's scratch is the host's real `/tmp/<agent-name>`, so agent
  names are unique across `none` spaces: the creation boundary refuses a
  collision (`{:scratch_name_in_use, other_space_name}`) and the name generator
  never proposes one. The name is client- and model-controlled and cannot
  distinguish Nest's directory from the host's own `/tmp` entries, so a `none`
  scratch carries a `.nest-scratch` marker and **every** `rm_rf` of a `none`
  scratch requires it. Both creators write it — `TmpSpace.create/3` and
  `Nest.Sandbox.Mounts.ensure_scratch!/1`, which stages a transcript before the
  agent starts — and neither will mark a directory that already exists without
  it, because marking a directory Nest did not make is what would license the
  next `rm_rf` to delete it. A name whose path already holds something that is
  not Nest's is refused by name (`{:scratch_path_taken, path}`) rather than
  adopted. A removal that would take a live same-named agent's scratch in
  another space is refused too.
- Anything that composes a prompt or runs a command must be given the agent's
  *real* mounts (`TmpSpace.prompt_mounts/4` builds the prompt's mounts): the
  backend is resolved from them, and under `"docker"` the agent's scratch names a
  path *inside the container* — so a call that leaves the scratch out loses the
  agent's own scratch (its job logs, its offloads) rather than failing loudly.
  `Nest.Sandbox.Backend.Docker.command/3` refuses a call that belongs to no
  space outright.
- Nothing under `lib/nest/sandbox/` reads the spaces schema. `Nest.Sandbox.Backend`
  owns the backend list and the default, `Nest.Spaces.Space` consumes them, and
  the dependency runs schema → sandbox only.

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
instead (see "Modes" below).
- User messages are tagged with a `[mode: $MODE]\n` prefix, and a message from
another agent carries the recipient's mode in its header
(`[Message from agent "$NAME" | mode: $MODE]\n`). Both state the **recipient's**
mode — the mode the turn will run in — which is the only mechanism by which an
agent whose inbox is all peer traffic learns its own mode.
- System notices should be tagged with a `[Nest notice]\n` prefix.

### Modes

- There are exactly two modes, and they are code constants (`Nest.Modes`), not
per-vocation data: `plan` may write only the space's scratch directory, `act` may
also write the workspace, and nothing else varies per call (the network is the
space's). A mode's caps are `Nest.Modes.caps/1`'s map; `plan` mode is about
*effects*, not only writes — an HTTP request that creates something is a change
no sandbox can see, and the prompt says so.
- **A mode is a per-agent runtime property.** It is persisted (`agents.mode`,
seeded from the blueprint's `default_mode`), so a restart cannot silently widen a
child that was spawned read-only. It is inherited at spawn (the spawner may
override it), changeable by the human on any agent (immediately — it does not
have to ride a message) and by an ancestor on a descendant, and it applies from
the agent's **next turn**, never mid-turn, with a `[Nest notice]` announcement
naming who changed it.
- **The monotone rule lives in exactly one place** —
`Nest.Agents.Agent.ModeAuthority`, which every mode-setting path goes through. An
agent may move a *descendant* to a mode it is in itself, or to `plan`; only the
human may raise a mode; **an agent may never set its own mode** (including by
sending itself a `set_mode`). The rule applies to the spawn too: a `plan` parent
must not spawn an `act` child, nor spawn one and then raise it. A refused change
reaches the sender as a tool error naming why.
- **A mode change never propagates** to existing descendants: the user flipping
the root to `plan` for a planning discussion must not jam background workers that
are mid-task in `act`.
- `set_mode` rides the send tools (`agents-query`, `agents-send`,
`agents-batch` — an enum of `"mine" | "plan" | "act"`) rather than being its own
tool, so the change and the instruction that depends on it arrive together.
- **The modes are not in the database.** `vocations.modes` no longer exists: a
vocation is its prompt and its tools, and the modes every agent may be in are
`Nest.Modes.names/0`. A blueprint is where the per-space defaults live —
`default_mode` (the mode a new agent starts in), `default_net` (the space's
`network_access`, used only when the caller names none) and
`default_spawnable_vocation` (what `agents-spawn`/`agents-batch` use when the
caller names no `vocation`; with none set the spawn is **refused**, naming the
missing argument, rather than silently getting the caller's own vocation).
- **A space requires a workspace on create** (`Space.create_changeset/2`): the
workspace is a space property its agents inherit, and `act` mode writes it. The
update path stays permissive, so `rename_space/1` still works on a row a previous
build left without one.


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

### Before Commit

- Read SMELLS.md. Check the proposed changes for code stench.
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

### Remember how to use OTP

- If we have a registry, we should use it. Avoid raw BEAM pids in favor of
via_registry(name) type patterns.
- If we're communicating with a GenServer, typically it's better to do a call or
cast than just sending a raw message. There's no need for handle_info when we
control both ends of the communication.

### HTTP Client

- Use the already included and available `:req` (`Req`) library for HTTP
requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by
default and is the preferred HTTP client for Phoenix apps.

### Phoenix / HEEx

- Avoid LiveView for web pages in favor of React.
- `<.flash_group>` must live in `NestWeb.Layouts` (the `layouts.ex` module)
only. You are **forbidden** from calling it elsewhere.
- HEEx class attrs support lists. When using multiple classes, **always** use
list `[...]` syntax:
  ```
  class={["px-2 text-white", @flag && "py-5"]}
  ```
- `<%= %>` works in tag bodies; use `{...}` for interpolation within tag
attributes and for simple value interpolation in tag bodies. Use `<%= %>` for
block constructs (`if`, `cond`, `case`, `for`) within tag bodies.

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/nest_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**
- We're using Tailwind and @llamaindex/chat-ui

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
- Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

- Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Phoenix PubSub does *not* deduplicate multiple subscriptions to the same topic. Two subs means two copies of each message.
- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.
- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->
