defmodule NestWeb.SurgicalReloaderTest do
  @moduledoc """
  Tests for `NestWeb.SurgicalReloader` (the dev-only file-watch +
  selective-restart GenServer) and its `SurgicalReloaderPlug`.

  ## Concurrency

  Safe to run concurrently: the file watcher is started **per test and
  anonymously** (`FileSystem.start_link/1` is called with no `:name`, and
  `FileSystem.Worker` fans events out only to its own subscribers), and the
  server under test is started under a private `@test_name` rather than the
  module's registered name. Nothing here is process-global, so no test can
  observe another's events — note that holds for *events* only: a real
  filesystem write under `lib/` during the async phase would be observed by
  any live watcher here (and would break the `pending_changes` equality
  assertions below).

  ## What we cover

  - `SurgicalReloaderPlug.init/1` returns opts; `call/2` passes the conn
    through unchanged. Trivial but covers 100% of the plug.
  - `SurgicalReloader.start_link/1` starts the GenServer, `init/1` sets
    state and defers module-map building via `{:continue,
    :build_module_map}`, and `handle_continue/2` populates the module
    map by walking `Nest.Supervisor`.
  - `handle_info({:file_event, ...})` accepts a synthetic `.ex`-suffix
    event without crashing and updates `pending_changes` (covers the
    file-extension guard branch).
  - `handle_info(:do_compile)` with an empty pending set takes the
    no-op branch (covers the guard that returns without compiling).
  - `handle_info({:file_event, ...})` for a non-Elixir file extension
    takes the early-return branch (covers the else-if).

  Branches not exercised by these tests (and why):
  - Compilation error path (`Mix.Task.run("compile.elixir")` returns
    `{:error, _}`): requires a broken `.ex` file on disk; messy.
  - `restart_module_subtree/2` truthy branch (immune supervisor, real
    module restart): requires a child supervisor with a tracked module
    to be alive mid-test, which fights with the existing supervision
    tree; deferred.
  - `find_parent_supervisor/1` and `restart_supervisor/1`: exercised
    only via the broken-restart fallback path above.
  """
  use ExUnit.Case, async: true

  alias NestWeb.SurgicalReloaderPlug

  # Use a test-local name so we don't collide with the (non-running in
  # test) `NestWeb.SurgicalReloader` registered name. Bypass `start_link/1`
  # because it hardcodes `name: __MODULE__` and we want a private name
  # to avoid global state.
  @test_name :"#{__MODULE__}.Server"

  describe "SurgicalReloaderPlug" do
    test "init/1 returns its argument unchanged" do
      assert SurgicalReloaderPlug.init([:anything]) == [:anything]
      assert SurgicalReloaderPlug.init([]) == []
    end

    test "call/2 returns the conn unchanged" do
      conn = %Plug.Conn{}
      assert SurgicalReloaderPlug.call(conn, []) == conn
    end
  end

  describe "init/1 + handle_continue/2" do
    test "start_link/1 succeeds and handle_continue builds the module map" do
      pid = start_supervised_reloader!()

      # `init/1` returns `{:ok, state, {:continue, :build_module_map}}`,
      # so the module map is built asynchronously after init returns.
      # `_ = :sys.get_state/2` flushes the GenServer mailbox so the
      # `handle_continue/2` callback has run before we read state.
      state = :sys.get_state(pid, 500)

      assert is_map(state)
      assert is_map(state.module_map)
      assert state.compiling == false
      assert state.pending_changes == MapSet.new()
      # The watcher pid comes from `FileSystem.start_link/1` inside
      # `init/1` and is non-nil once `init` returns.
      assert is_pid(state.watcher)
    end
  end

  describe "handle_info({:file_event, ...})" do
    test "ignores non-Elixir file extensions" do
      pid = start_supervised_reloader!()

      send(pid, {:file_event, make_ref(), {"README.md", [:modified]}})

      state = :sys.get_state(pid, 500)
      assert state.pending_changes == MapSet.new()
    end

    test "ignores events other than :modified and :created" do
      pid = start_supervised_reloader!()

      send(pid, {:file_event, make_ref(), {"lib/foo.ex", [:removed]}})

      state = :sys.get_state(pid, 500)
      assert state.pending_changes == MapSet.new()
    end

    test "records pending change for a modified .ex file" do
      pid = start_supervised_reloader!()

      # Hold the compiler busy first. `handle_info(:do_compile, ...)` only
      # compiles — and only then clears `pending_changes` — when `compiling`
      # is false, so with it true the debounce timer firing is harmless and
      # the assertion below cannot race it. It also keeps the real
      # `Mix.Task.run("compile.elixir", ...)` path out of a concurrent test.
      :sys.replace_state(pid, fn state -> %{state | compiling: true} end, 500)

      send(pid, {:file_event, make_ref(), {"lib/example_test.ex", [:modified]}})

      # `:sys.get_state/2` is synchronous relative to the server's mailbox and
      # the event was sent first, so this observes the state after the event.
      state = :sys.get_state(pid, 500)

      assert MapSet.member?(state.pending_changes, "lib/example_test.ex")
      assert is_reference(state.debounce_timer) or is_nil(state.debounce_timer)
    end
  end

  describe "handle_info(:do_compile)" do
    test "no-op when pending_changes is empty" do
      pid = start_supervised_reloader!()

      send(pid, :do_compile)

      state = :sys.get_state(pid, 500)
      assert state.pending_changes == MapSet.new()
      assert state.compiling == false
      assert state.debounce_timer == nil
    end
  end

  # === HELPERS ===

  defp start_supervised_reloader! do
    spec = %{
      id: @test_name,
      start: {GenServer, :start_link, [NestWeb.SurgicalReloader, [name: @test_name]]},
      restart: :transient
    }

    {:ok, pid} = start_supervised(spec)
    pid
  end
end
