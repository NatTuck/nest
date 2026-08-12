This is a web application written using the Phoenix web framework with a React
user interface.

All browser JS and other assets are in ./assets. This is most of the UI.

## ⚠️ CRITICAL: JS Package Location

Our JavaScript/browser code lives exclusively in `./assets/`.

- Our package manager is pnpm. Don't use npm or others.
- **NEVER** run `pnpm` commands in the project root
- **ALWAYS** `cd assets` first before running any JS package commands
- If you see `package.json`, `node_modules`, or other similar JS artifacts in the project
root, something is wrong - delete them immediately

## ⚠️ CRITICAL: Testing Protocol

- **ABSOLUTELY NEVER** run a test command and throw away the output with grep,
head, or tail. This behavior is **NEVER** acceptable. If you do it even once,
stop running commands for *any reason*, explain how to avoid the error in the
future, and stop.

## Project Design

### LLM Calls

- Once we have an active conversation, we *NEVER* make changes that would
disrupt prefix caching, except on compaction.
- Specifically, that means our main system message is fixed once set and does
not change except potentially on compaction.
- The main system message explains things that will always be true for the
current session. This includes a fixed vocation (and thus mode list) and a
project root (and thus an AGENTS.md if present).
- If stuff like vocation or project root were to change, that'd necessarily
be a new session, although it could be built (like a compaction) from a previous
session if that made sense.
- User messages are tagged with a `[mode: $MODE]\n` prefix.
- We are *very* careful with any sort of transient message.

### UI Transparency

- We don't hide stuff from the user. If it gets sent to the LLM or the LLM sends
it back then it's visible in the UI (maybe collapsed, in rare edge cases may be
just in the API log, but the UI always includes everything that happened).

## Project guidelines

### Before Commit

- Read SMELLS.md. Check the proposed changes for code stench.
- Run `mix precommit` and read the *full* output. No head/tail/grep, read the
whole thing.
- There's no such thing as "out of scope" or "pre-existing issue" for this step.
Either we're 100% clean (no fails, no warnings, no style suggestions, no test
log prints, etc) or we're not.
- **ABSOLUTELY NEVER** run `git stash`. NEVER. NOT FOR ANY REASON, NO EXCUSES.

### During Development

- Never run any dev servers, neither `mix phx.server` nor `npx vite`. The user will manage that manually.
- Code must pass lints (credo, biome). Do not modify lint configs or bypass the lints. 
FIX THE LINT ISSUES. ALWAYS. NO EXCUSES. IT DOES NOT MATTER IF IT WAS ALREADY THERE.
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
- **NEVER** run tests and throw away the output by piping to tail, head, grep or
similar. If you expect long output, redirect to a temporary file (e.g.
/tmp/opencode/test-runs/test-run.log).
- **ALL** test run output should go under notes/test-runs.
- The Elixir test suite must take less than 5 seconds to run. If it ever takes
longer, that's a major issue that needs to be addressed immediately.
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

<!-- usage-rules-start -->

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

- Phoenix PubSub does *not* deduplicate multiple subscriptions to the same
topic. Two subs means two copies of each message.

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->
<!-- usage-rules-end -->
