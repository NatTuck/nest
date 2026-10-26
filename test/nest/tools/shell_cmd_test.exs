defmodule Nest.Tools.ShellCmdTest do
  @moduledoc """
  Tests for `Nest.Tools.ShellCmd` and the `shell-cmd` tool's `timeout`
  argument. Focus: the `{:stop_chat, _}` clause in `collect_output/5`
  that kills the bwrap OS process when the user clicks Stop
  mid-execution, the wall-clock deadline that kills a command at its
  bound (in milliseconds for `execute/5`, in seconds for the tool), and
  the erlexec pid that keeps one call's `:DOWN` from ending another's.

  Uses real bwrap + `:exec.run/2` (no mocks) — the tool is
  exercised end-to-end. The stop test pre-seeds the calling
  process's mailbox with `{:stop_chat, self()}` so that
  `collect_output/5`'s `receive` matches it on the first
  iteration instead of waiting for the command to complete
  naturally; that message cannot outlive its worker (a Stop
  kills it), so pre-seeding is sound there. A `{:cancel_tool, _}`
  *can* outlive one — it is sent to a worker that may not be
  inside `collect_output/5` at all — so its tests deliver it to a
  running command instead, and pin that a leftover is discarded.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Nest.Test.TmpCleanup
  import Eventually

  alias Nest.Sandbox.Mounts
  alias Nest.Tools
  alias Nest.Tools.ShellCmd
  alias Nest.Tools.ShellCmd.Transcript

  setup do
    # A workspace outside /tmp: the scratch dir is bound at /tmp, so a
    # /tmp-rooted workspace is rejected unconditionally.
    ws =
      Path.join([
        File.cwd!(),
        "_build",
        "tmp",
        "nest_shellcmd_ws_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(ws)
    on_exit(fn -> if String.contains?(ws, "nest_shellcmd_ws"), do: File.rm_rf(ws) end)
    %{ws: ws}
  end

  @tag :bwrap
  test "collect_output/5's {:stop_chat, _} clause calls :exec.stop and returns exit 130", %{
    ws: ws
  } do
    # Pre-seed the mailbox so the receive clause matches on
    # the first iteration. Without this, `collect_output/5`
    # would block on `:stdout` / `:stderr` / `:DOWN` until
    # the command's natural exit (or the 60s default timeout).
    send(self(), {:stop_chat, self()})

    # Use `true` (a no-op builtin) so we don't depend on a
    # specific toolchain being installed. bwrap still spawns
    # the process and `:exec.run/2` returns the os_pid —
    # that's what `collect_output/5` needs to forward to
    # `:exec.stop/1`.
    log =
      capture_log(fn ->
        assert {:error, message} = ShellCmd.execute("true", Mounts.new(ws, nil), nil, [])

        assert message =~ "Exit code 130"
        assert message =~ "[Command cancelled]"
      end)

    # The bwrap non-zero exit on cancel is a deliberate
    # diagnostic — assert on it so the test's intent is
    # self-documenting and the log doesn't escape. (The
    # `exit_code=` field it carries is the 130 the message
    # above already asserts.)
    assert log =~ "ShellCmd.execute: bwrap exited non-zero"
  end

  @tag :bwrap
  test "collect_output/5's {:cancel_tool, _} clause stops the command and returns a tool error",
       %{ws: ws} do
    # The space's environment changed under the command: the space edit cancelled
    # it. The message has to arrive while the command is *running* — that is the
    # only case the clause exists for, and one that finds the worker between two
    # commands is discarded rather than carried into the next (`flush_cancel_tool/0`,
    # pinned by the test below). So the command proves it started by touching a
    # marker and only then is it cancelled: a barrier, not a sleep.
    #
    # 1s on the marker: bwrap start is ~100ms and erlexec's own boot is the
    # hardcoded ~350ms `mix.exs` documents, so this is that first-call worst
    # case plus margin rather than a guess. (Erlexec is started at boot now, so
    # the 350ms is normally already paid — the margin is kept because this is a
    # timeout, not a synchronisation.)
    reason = "The space's environment changed; this call did not run."
    marker = Path.join(ws, "started")

    task =
      Task.async(fn ->
        ShellCmd.execute("touch #{marker}; sleep 30", Mounts.new(ws, nil), nil, [])
      end)

    eventually(fn -> File.exists?(marker) end, timeout: 1_000)
    send(task.pid, {:cancel_tool, reason})

    # Not a Stop: a Stop is the human ending the turn and reports the command's
    # own cancelled exit code. This is not a result at all — the agent gets the
    # reason as its tool error, so it can re-issue the call against the space's
    # new values — and it is not logged, because nothing failed. (`Task.yield`
    # plus `shutdown` rather than `await`: a cancel that failed to land must fail
    # the test rather than leave a `sleep 30` running.)
    assert {:ok, {:cancelled, ^reason}} =
             Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)
  end

  @tag :bwrap
  test "execute_raw/4 reports a cancellation as its error string", %{ws: ws} do
    # `execute_raw/4`'s contract is `{:ok, code, stdout, stderr} | {:error, string}`
    # — the sandbox helpers (`stat`, `glob`) have no place to put a cancellation of
    # their own, so it comes back as the error. Nothing cancels one today; this is
    # the shape being total, and it is the same message the tool path reports.
    reason = "The space's environment changed; this call did not run."
    marker = Path.join(ws, "raw-started")

    task =
      Task.async(fn ->
        ShellCmd.execute_raw("touch #{marker}; sleep 30", Mounts.new(ws, nil), nil, [])
      end)

    eventually(fn -> File.exists?(marker) end, timeout: 1_000)
    send(task.pid, {:cancel_tool, reason})

    assert {:ok, {:error, ^reason}} =
             Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)
  end

  @tag :bwrap
  test "a cancellation left over from between commands does not stop the next one", %{ws: ws} do
    # The stale message this discards: a worker parked at the space's gate (or
    # between two calls of a batch) is not inside `collect_output/5`, so the
    # cancel it was sent sits in its mailbox until the *next* command starts.
    # Matched there, it would stop a command that began in the new environment
    # and hand the agent a cancellation it never asked for — and a command that is
    # not idempotent would be half-run, which is the state the latch exists to
    # prevent.
    reason = "The space's environment changed; this call did not run."
    send(self(), {:cancel_tool, reason})

    assert {:ok, "after\n"} = ShellCmd.execute("echo after", Mounts.new(ws, nil), nil, [])
  end

  # The bug this pins: `collect_output/5`'s `after` used to be an *idle*
  # timer, so every stdout chunk re-armed it and a command that wrote at
  # least once per `timeout` was never killed. Concrete timings: the loop
  # writes every 50ms for 12 iterations (~600ms of continuous output)
  # against a 300ms bound, so an idle timer never fires while output keeps
  # arriving — the command runs to completion and the call returns `{:ok}`
  # with all 12 ticks (measured against the idle-timer code: `{:ok, ...}`
  # after ~0.6s). With the deadline, the kill lands at ~300ms after 5-6
  # ticks, so fewer than the 12 ticks the loop would produce if it were never
  # killed is the observable kill. The loop is finite on purpose — a
  # regression is a clean, fast failure (~0.6s) rather than a stuck suite.
  # There is deliberately no lower bound on the tick count: the bound starts
  # before bwrap spawns, so on a loaded host the kill can land before the
  # command writes anything, and `ticks > 0` would flake. There is no flooding
  # case here either: on this host erlexec delivers stdout in 4 KiB chunks and
  # a loop with no pause at all drains them faster than the port fills them, so
  # the mailbox empties and the pre-fix `after`-only check fires near the bound
  # too — a flood test would pass with the bug present and pin nothing.
  @tag :bwrap
  test "a command that keeps writing is killed at its wall-clock deadline", %{ws: ws} do
    started = System.monotonic_time(:millisecond)

    log =
      capture_log(fn ->
        assert {:error, output} =
                 ShellCmd.execute(
                   "for ((i = 0; i < 12; i++)); do echo tick; sleep 0.05; done",
                   Mounts.new(ws, nil),
                   nil,
                   timeout: 300
                 )

        assert output =~ "[Command timed out after 300ms]"

        ticks = output |> String.split("tick") |> length() |> Kernel.-(1)
        assert ticks < 12
      end)

    elapsed = System.monotonic_time(:millisecond) - started

    # The deadline is fixed when the command starts, so the kill cannot
    # happen before it: this is the one timing assertion that is
    # structurally guaranteed (no amount of scheduler slack can fail it).
    assert elapsed >= 300

    # bwrap's non-zero exit on the kill is a deliberate diagnostic.
    assert log =~ "ShellCmd.execute: bwrap exited non-zero"
  end

  # The `timeout` argument is documented as having no upper limit, but
  # `receive ... after` only accepts up to 4_294_967_295 ms. The whole
  # remaining interval used to go into `after` on the first iteration, so a
  # large enough `timeout` raised `ErlangError: :timeout_value`:
  # `Nest.LLM.Tools.invoke/4` rescued it into "Tool `shell-cmd` crashed: ..."
  # and `handle_timeout`/`:exec.stop` never ran, leaving the bwrap process
  # running with nothing left to stop it. 86400000 is one day expressed in
  # *milliseconds* — the number a model that learned the unit from
  # `agents-wait`/`agents-batch` (both milliseconds) passes by habit — so
  # this is the reachable form of the bug: 8.64e10 ms of bound.
  @tag :bwrap
  test "a `timeout` past `receive`'s `after` ceiling still runs the command", %{ws: ws} do
    function = Tools.get_function("shell-cmd", Mounts.new(ws, nil))

    assert {:ok, output} =
             function.function.(%{"command" => "echo hi", "timeout" => 86_400_000}, nil)

    # The command ran to completion and its real output came back: the
    # `{:ok, ...}` can only be produced by this call's own erlexec `:DOWN`,
    # i.e. the process exited and was reaped. The crash returned
    # `{:error, "Tool `shell-cmd` crashed: ..."}` with the process still
    # running.
    assert output == "hi\n"
  end

  # Two calls in one process — the way a batch's calls run in one tool worker
  # — so the first call's undrained `:DOWN` lands in the same mailbox the
  # second call collects from. `handle_timeout/3` returns without draining
  # erlexec's `:DOWN` for the killed command, and `collect_output/5`'s
  # `:DOWN` clause used to match *any* process: the second call consumed the
  # first call's stale `:DOWN` and returned `{:ok, "[Command executed
  # successfully with no output]"}` in ~5ms (measured against the pre-fix
  # code) while its own bwrap was still running, silently discarding
  # "second". The clause now matches the erlexec pid this call started, as
  # `Nest.Sandbox.ShellJobs.job_by_erl_pid/2` already does.
  #
  # `timeout: 50` rather than the `shell-cmd` tool's 1-second minimum: the
  # whole suite shares a 5s wall-clock budget, and the tool path would spend
  # a full second here for the same mailbox. The stale `:DOWN` is waited for
  # by arrival and then re-sent, so the second call's outcome is deterministic
  # rather than a race against its arrival, which is measured at ~5-15ms
  # after `:exec.stop/1`.
  @tag :bwrap
  test "a timed-out call does not swallow the next call's result", %{ws: ws} do
    log =
      capture_log(fn ->
        assert {:error, first} =
                 ShellCmd.execute("echo first; sleep 5", Mounts.new(ws, nil), nil, timeout: 50)

        assert first =~ "[Command timed out after 50ms]"

        # `:exec.stop/1` is asynchronous, so the killed command's `:DOWN` is a
        # real arrival rather than a frame already in the mailbox. Taking it and
        # re-sending it puts the stale `:DOWN` ahead of anything call 2's own
        # command adds, so "call 2 ignores it" is a fact, not a race.
        assert_receive {:DOWN, _ref, :process, _pid, _reason} = stale_down, 1000
        send(self(), stale_down)

        # Call 2's own output. With the stale `:DOWN` it is the empty-output
        # placeholder instead, returned before its command had finished.
        assert {:ok, second} = ShellCmd.execute("echo second", Mounts.new(ws, nil), nil, [])
        assert second == "second\n"
      end)

    # The timed-out call's non-zero exit is a deliberate diagnostic.
    assert log =~ "ShellCmd.execute: bwrap exited non-zero"
  end

  # The `shell-cmd` *tool*'s `timeout` argument is seconds of wall-clock
  # time; `Nest.Tools` validates it and hands milliseconds to `execute/5`.
  # These exercise the tool, not just the module, so the argument's schema
  # and its conversion are covered too.
  test "the tool leaves a command that finishes before its bound alone, output intact", %{ws: ws} do
    function = Tools.get_function("shell-cmd", Mounts.new(ws, nil))

    # Explicit: `timeout: 1` is one second, and the command runs ~0.1s, so
    # the bound must not truncate it (a broken conversion — e.g. seconds
    # handed to `ShellCmd` as milliseconds — would kill it at once). `{:ok, _}`
    # is itself the "not truncated" claim: a timeout comes back as `{:error, _}`
    # with exit code 1.
    assert {:ok, output} =
             function.function.(
               %{"command" => "echo one; sleep 0.1; echo two", "timeout" => 1},
               nil
             )

    assert output =~ "one"
    assert output =~ "two"
  end

  test "the tool's contract: `timeout` in seconds, and the umask every command runs under", %{
    ws: ws
  } do
    tool = Tools.get_function("shell-cmd", Mounts.new(ws, nil))
    timeout = tool.parameters_schema["properties"]["timeout"]

    # `default_timeout_ms/0` is the single source of truth for the default;
    # both model-visible strings interpolate it, so the prose cannot drift
    # from the constant. 60s is the documented default.
    assert ShellCmd.default_timeout_ms() == 60_000
    default_seconds = div(ShellCmd.default_timeout_ms(), 1000)

    # The model-visible contract: seconds, default 60, no cap, and optional
    # (omitting it is what applies the default). The unit is spelled out
    # because `agents-wait` and `agents-batch` take milliseconds.
    assert timeout["type"] == "integer"
    assert timeout["description"] =~ "Wall-clock limit in seconds"
    assert timeout["description"] =~ "default #{default_seconds}"
    assert timeout["description"] =~ "no upper limit"
    assert timeout["description"] =~ "milliseconds"
    assert tool.description =~ "default #{default_seconds}"
    refute Map.has_key?(timeout, "maximum")
    assert tool.parameters_schema["required"] == ["command"]

    # The umask the transcript's preamble sets, stated to the model. 0022 is the
    # policy (a directory an agent creates must never be world-writable) and the
    # literal is deliberate: the description interpolates `Transcript.umask/0`,
    # so a change to the constant has to be a visible change to this line rather
    # than a silent drift between what the model is told and what the script
    # runs with.
    assert tool.description =~ "umask 0022"
  end

  test "the tool rejects a non-positive or non-integer `timeout` as a tool error", %{ws: ws} do
    function = Tools.get_function("shell-cmd", Mounts.new(ws, nil))

    # Rejected before anything runs, so the tool error is the whole result.
    # The shape is the one `agents-wait`'s `timeout` rejection uses, so the
    # model is told what it got wrong instead of silently getting the
    # default. One value per way the guard can be wrong: `0` and `-1` pin the
    # `> 0` arm, `1.5` a guard that only checked `is_number`, and `"5"` one
    # that skipped `is_integer` (which would raise in the multiplication).
    for bad <- [0, -1, 1.5, "5"] do
      assert {:error, message} =
               function.function.(%{"command" => "echo nope", "timeout" => bad}, nil)

      assert message ==
               "Invalid `timeout` argument: expected a positive integer of seconds, " <>
                 "got: #{inspect(bad)}."
    end
  end

  test "the tool refuses to pipe output into head or tail", %{ws: ws} do
    function = Tools.get_function("shell-cmd", Mounts.new(ws, nil))

    # One representative: `Nest.Tools.ShellPipes.check/1`'s own suite covers the
    # detection and the message in full, so this only has to pin that the tool
    # *calls* it — rejected before anything runs, so no bwrap is needed.
    assert {:error, message} = function.function.(%{"command" => "ls | head"}, nil)
    assert message =~ "will not pipe command output into"

    # `background: true` does not get a discarded pipe past it either.
    assert {:error, message} =
             function.function.(
               %{"command" => "sort | uniq -c | head", "background" => true},
               nil
             )

    assert message =~ "will not pipe command output into"
  end

  test "the tool rejects a detached-background marker, even with `background: true`", %{ws: ws} do
    function = Tools.get_function("shell-cmd", Mounts.new(ws, nil))

    # The check is a pure function of the command string, so `background: true`
    # does not get a marker past it: a `&` still makes the staged script exit at
    # once (reporting "exited 0" with no output), and bwrap has no controlling
    # terminal for `nohup`/`setsid`. `Nest.Tools.ShellBackground.check/1`'s own
    # suite covers the detection, the markers and the false positives; this pins
    # only that the tool calls it, on the argument combination that could bypass
    # it.
    assert {:error, message} =
             function.function.(%{"command" => "setsid sleep 1", "background" => true}, nil)

    assert message =~ "never runs a command detached"
    assert message =~ "background: true"
  end

  @tag :bwrap
  test "the tool runs a command whose pipe into grep the filter allows (issue #106)", %{ws: ws} do
    function = Tools.get_function("shell-cmd", Mounts.new(ws, nil))
    File.write!(Path.join(ws, "sample.txt"), "alpha\nbeta\n")

    # `ShellPipes`' own suite pins that a pipe into `grep` is allowed (and that
    # `head`/`grep` used directly are); this is the end-to-end half — the
    # allowed pipeline really runs under bwrap and its filtered output comes
    # back.
    assert {:ok, output} = function.function.(%{"command" => "cat sample.txt | grep beta"}, nil)
    assert output == "beta\n"
  end

  @tag :bwrap
  test "a symlinked workspace is bound at its canonical path, so a write through the symlink lands there",
       %{ws: base} do
    # Include the OS pid so paths are unique across BEAM runs — a
    # previously killed run can leave these behind, and
    # `System.unique_integer/1` restarts per BEAM so it can collide.
    uniq = "#{System.pid()}_#{System.unique_integer([:positive])}"
    real = Path.join(base, "nest_bwrap_#{uniq}_real")
    link = Path.join(base, "nest_bwrap_#{uniq}_link")

    # `System.unique_integer/1` restarts per BEAM, so a previously
    # killed run can leave these paths behind and make `ln_s!` fail.
    # Clear any stale entries first; `rm_tmp!/2` refuses to touch a path
    # that does not carry the fixture's `nest_bwrap` marker.
    rm_tmp!(real, "nest_bwrap")
    rm_tmp!(link, "nest_bwrap")
    File.mkdir_p!(real)
    File.ln_s!(real, link)

    on_exit(fn ->
      rm_tmp!(real, "nest_bwrap")
      rm_tmp!(link, "nest_bwrap")
    end)

    # Default caps bind the canonical workspace read-write; --chdir
    # targets the user's symlinked path. A write through the symlink must
    # resolve to the canonical writable mount and land in the real
    # directory — the read half would pass off the root ro-bind alone, so
    # the write is what pins the bind.
    assert {:ok, _} = ShellCmd.execute("echo written > out.txt", Mounts.new(link, nil), nil, [])
    assert File.read!(Path.join(real, "out.txt")) =~ "written"
  end

  test "a missing workspace is refused", %{ws: ws} do
    missing = Path.join(ws, "nest_missing_#{System.unique_integer([:positive])}")

    # The workspace is validated before bwrap runs, so a missing
    # directory surfaces as a clean error.
    assert {:error, message} = ShellCmd.execute("true", Mounts.new(missing, nil), nil, [])
    assert message =~ "does not exist"
  end

  # The point of staging a script: the shell reads a file, so nothing in the
  # command text has to survive as one quoted argv element.
  test "a multi-line command runs unescaped: quotes, dollars and pipes survive", %{ws: ws} do
    command = """
    greeting='hello "world" ${UNSET_VAR}'
    echo "$greeting" | tr a-z A-Z
    """

    assert {:ok, output} = ShellCmd.execute(command, Mounts.new(ws, nil), nil, [])
    assert output =~ ~s{HELLO "WORLD" }
  end

  test "stdin is delivered over a pipe, and an absent stdin gives an immediate EOF", %{ws: ws} do
    assert {:ok, output} = ShellCmd.execute("wc -c", Mounts.new(ws, nil), nil, stdin: "abcde")
    assert String.trim(output) == "5"

    assert {:ok, output} = ShellCmd.execute("wc -c", Mounts.new(ws, nil), nil, [])
    assert String.trim(output) == "0"
  end

  test "a timeout places its annotation in stderr so raw callers see it", %{ws: ws} do
    # `execute_raw` discards the combined output; the marker must reach it via
    # stderr, or a timed-out glob/read would classify as an empty `:read_failed`
    # with no signal at all.
    assert {:ok, 1, _stdout, stderr} =
             ShellCmd.execute_raw("sleep 5", Mounts.new(ws, nil), nil, timeout: 50)

    assert stderr =~ "[Command timed out after 50ms]"
  end

  test "the transcript is staged in the scratch staging dir (visible as /tmp/.cmds) and removed after",
       %{ws: ws} do
    tmp =
      Path.join([
        System.tmp_dir!(),
        "nest_stage_#{System.unique_integer([:positive])}",
        "space-1",
        "agent"
      ])

    File.mkdir_p!(tmp)

    on_exit(fn ->
      if String.contains?(tmp, "nest_stage"), do: File.rm_rf(Path.dirname(Path.dirname(tmp)))
    end)

    stage = Path.join(Path.dirname(tmp), ".cmds")

    # $0 is the staged script, as seen from inside the sandbox.
    assert {:ok, output} = ShellCmd.execute(~s{basename "$0"}, Mounts.new(ws, tmp), nil, [])
    assert output =~ "nest-cmd-"

    # The transcript is temporary either way: the caller gets the output.
    assert {:ok, _} = ShellCmd.execute("echo bye", Mounts.new(ws, tmp), nil, [])
    assert Path.wildcard(Path.join(stage, "nest-cmd-*.sh")) == []
  end

  @tag :bwrap
  test "the transcript carries the umask preamble, so created modes are deterministic", %{ws: ws} do
    # Modes used to be whatever umask the launcher had: the same `mkdir` came
    # out 0777 under a launcher with umask 000 and 0775 under 002, so a
    # world-writable directory in the workspace was one inherited value away.
    #
    # The transcript's *bytes* are the assertion that can fail on every host: a
    # launcher with umask 022 already produces 0755/0644, so the mode
    # assertions below corroborate the effect here rather than pinning it.
    #
    # The scratch is what makes the two spellings different strings — with no
    # scratch bind `stage_dir_sandbox/1` *is* `stage_dir/1`, and the assertion
    # below would pass for the bug it names.
    scratch =
      Path.join([
        System.tmp_dir!(),
        "nest_umask_stage_#{System.unique_integer([:positive])}",
        "space-1",
        "agent"
      ])

    File.mkdir_p!(scratch)

    on_exit(fn ->
      if String.contains?(scratch, "nest_umask_stage"),
        do: File.rm_rf(Path.dirname(Path.dirname(scratch)))
    end)

    mounts = Mounts.new(ws, scratch)
    {host, sandbox} = Transcript.stage("mkdir d", mounts)
    on_exit(fn -> File.rm(host) end)

    assert File.read!(host) == "umask 0022\nmkdir d"

    # The spelling bash is handed is the sandbox's, not the host's: with a
    # scratch bind the staging directory is `<space>/.cmds` on the host and
    # `/tmp/.cmds` inside. Handing bash the host path would make every command
    # fail to open its own script.
    assert sandbox == Path.join("/tmp/.cmds", Path.basename(host))

    # End to end through a real command: the preamble applies to the whole
    # script, and the command's own `umask` still wins over it.
    assert {:ok, _} =
             ShellCmd.execute("mkdir d && touch f && umask 0077 && mkdir priv", mounts, nil, [])

    assert mode(Path.join(ws, "d")) == 0o755
    assert mode(Path.join(ws, "f")) == 0o644
    assert mode(Path.join(ws, "priv")) == 0o700
  end

  test "there is no set -e, so a failing statement does not stop the script", %{ws: ws} do
    # The staged script runs without `set -e`: the first statement fails, the
    # next still runs, and the last statement's (zero) status is what the call
    # reports. The non-zero-exit half is covered by `Nest.ToolsTest` (exit 1,
    # bwrap) and `Nest.Sandbox.NoneBackendTest` (exit 3), so only the absence of
    # `set -e` is pinned here.
    assert {:ok, output} = ShellCmd.execute("false\necho survived", Mounts.new(ws, nil), nil, [])
    assert output =~ "survived"
  end

  test "large stdin streams over the pipe and never hits an ARG_MAX ceiling", %{ws: ws} do
    payload = :binary.copy("abcdefgh", 400_000)

    assert {:ok, _} = ShellCmd.execute("cat > big.bin", Mounts.new(ws, nil), nil, stdin: payload)
    assert File.stat!(Path.join(ws, "big.bin")).size == byte_size(payload)
  end

  describe "the config-file gate" do
    test "refuses a workspace whose config path is not a regular file, on every backend", %{
      ws: ws
    } do
      # The only per-command gate `docker` and `none` have: `Docker.command/3` and
      # `job_spec/4` build the inner bwrap from `Binds.specs/2` and never reach
      # `Sandbox.build/4`, and `none` builds no sandbox at all. Remove this clause
      # and the `docker` and `none` iterations fail; the `bwrap` one still matches,
      # because `Sandbox.build/4`'s own gate produces the same message. That
      # asymmetry is why the loop covers all three: with only `bwrap` here, two of
      # the three backends could reopen the escalation with a green suite.
      #
      # One filename is enough: which config file is the offender is
      # `Nest.ConfigFile`'s business (its own suite covers `.nest` and
      # `AGENTS.md`), and the clause here matches only the reason.
      for backend <- ["bwrap", "docker", "none"] do
        # A fresh workspace per backend: `ConfigFile.refuse/2` logs its warning
        # once per path for the life of the BEAM, so a shared path would log for
        # the first iteration only and leave the rest with nothing to assert.
        case_ws = Path.join(ws, backend)
        File.mkdir_p!(case_ws)
        real = Path.join(case_ws, "real")
        File.write!(real, "")
        File.ln_s!(real, Path.join(case_ws, ".nest"))

        log =
          capture_log(fn ->
            assert {:error, msg} =
                     ShellCmd.execute("echo hi", Mounts.new(case_ws, nil, backend), nil)

            assert msg =~ "not a regular file"
            assert msg =~ ".nest"
          end)

        assert log =~ "Nest cannot protect it from being rewritten"
      end
    end
  end

  # The permission bits of `path`, without the file-type bits `File.stat!/1`
  # reports alongside them.
  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end
