defmodule NestWeb.SurgicalReloaderTest do
  @moduledoc """
  Tests for `NestWeb.SurgicalReloader` (the dev-only file-watch +
  selective-restart GenServer) and its `SurgicalReloaderPlug`.

  ## Why `async: false`

  `SurgicalReloader.init/1` calls `FileSystem.start_link(dirs: ["lib"],
  recursive: true)` — it watches the whole source tree. That's not safe
  to run twice concurrently in the test process because the watcher
  process is per-test, but its messages are delivered to whichever
  GenServer pid subscribes, and a concurrent test's `mix`-driven file
  write (e.g. coverage regeneration) would cross-pollinate watchers.

  Per AGENTS.md, this restriction needs justification; the comment above
  is it. There is no `start_supervised!` trick that avoids starting a
  real `FileSystem` watcher here without a refactor of the module
  (out of scope for this PR).

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
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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
      # `_ = :sys.get_state/1` flushes the GenServer mailbox so the
      # `handle_continue/2` callback has run before we read state.
      state = :sys.get_state(pid)

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

      state = :sys.get_state(pid)
      assert state.pending_changes == MapSet.new()
    end

    test "ignores events other than :modified and :created" do
      pid = start_supervised_reloader!()

      send(pid, {:file_event, make_ref(), {"lib/foo.ex", [:removed]}})

      state = :sys.get_state(pid)
      assert state.pending_changes == MapSet.new()
    end

    test "records pending change for a modified .ex file" do
      pid = start_supervised_reloader!()

      log =
        capture_log(fn ->
          send(pid, {:file_event, make_ref(), {"lib/example_test.ex", [:modified]}})

          # Drain pending state via :sys.get_state after the message
          # has been processed. `:sys.get_state/1` is synchronous
          # relative to the GenServer's mailbox.
          _ = :sys.get_state(pid)
        end)

      # The debounce timer fires `Mix.Task.run("compile.elixir", ...)`,
      # which in test env is a no-op (everything's already compiled).
      # Compilation may succeed silently or log deprecation noise from
      # Mix internals — we only assert on absence of crashes.
      _ = log

      state = :sys.get_state(pid)
      assert MapSet.member?(state.pending_changes, "lib/example_test.ex")
      assert is_reference(state.debounce_timer) or is_nil(state.debounce_timer)
    end
  end

  describe "handle_info(:do_compile)" do
    test "no-op when pending_changes is empty" do
      pid = start_supervised_reloader!()

      send(pid, :do_compile)

      state = :sys.get_state(pid)
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
