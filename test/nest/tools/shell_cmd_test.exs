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
    # self-documenting and the log doesn't escape.
    assert log =~ "ShellCmd.execute: bwrap exited non-zero"
    assert log =~ "exit_code=130"
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
    # 1s on the marker: bwrap start is ~100ms and erlexec's one-off boot is the
    # ~350ms this module's `Exec.ensure_started/0` comment documents, so this is
    # that first-call worst case plus margin rather than a guess.
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

  test "execute/5 returns the natural output for a successful command", %{ws: ws} do
    # Sanity check that the receive doesn't match the
    # pre-seeded stop when none is in the mailbox. A trivial
    # `true` command exits 0 immediately and bwrap reports
    # the success path.
    assert {:ok, output} = ShellCmd.execute("true", Mounts.new(ws, nil), nil, [])

    # The output is the "no output" placeholder because
    # `true` produces no stdout/stderr.
    assert output == "[Command executed successfully with no output]"
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
  # command writes anything, and `ticks > 0` would flake. Sustained output is
  # pinned by the flooding test below, which never pauses at all.
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

  # The deadline used to be consulted only in `after`, so a command whose
  # output never pauses can keep the mailbox non-empty and delay the kill
  # indefinitely; the loop below has no sleep at all, so there is no quiet gap
  # for an `after`-only check to fire in. The loop is finite on purpose: it
  # outlives the 100ms bound (~300k iterations of `echo` take ~0.3s; measured
  # 1M ≈ 1.1s), so a regression that misses the bound ends in a clean
  # `{:ok, 0, ...}` instead of a hung suite. Measured with the fix: ~0.12s.
  #
  # Measured caveat: on this host the pre-fix code also kills it near the bound.
  # erlexec's port delivers stdout in 4 KiB chunks and this loop drains them
  # faster than the port can fill them (`yes` streams ~1.3 GB/s, ~310k
  # messages/s, and is still drained), so the mailbox does empty and the
  # `after`-only check fires. This test therefore pins the wall-clock bound for
  # the regime where the producer *does* outrun the consumer; it is not a
  # reproduction of that regime.
  @tag :bwrap
  test "a command that floods stdout with no pause is killed at its bound", %{ws: ws} do
    started = System.monotonic_time(:millisecond)

    result =
      ShellCmd.execute_raw(
        "for ((i = 0; i < 1000000; i++)); do echo tick; done",
        Mounts.new(ws, nil),
        nil,
        timeout: 100
      )

    # `match?/2` plus the stderr projection, deliberately: on a regression the
    # command floods megabytes of ticks into the result tuple, and a failure
    # message carrying all of them helps nobody. The marker can only come from
    # `handle_timeout/3`, i.e. the deadline check ran while output was still
    # arriving; the exit code is 1, not the flood's own exit status.
    assert match?({:ok, 1, _stdout, _stderr}, result)
    assert elem(result, 3) =~ "[Command timed out after 100ms]"
    assert System.monotonic_time(:millisecond) - started >= 100
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
    # handed to `ShellCmd` as milliseconds — would kill it at once).
    assert {:ok, output} =
             function.function.(
               %{"command" => "echo one; sleep 0.1; echo two", "timeout" => 1},
               nil
             )

    assert output =~ "one"
    assert output =~ "two"
    refute output =~ "timed out"

    # Omitted: the 60s default applies, so a command that writes every 100ms
    # for 300ms — well past any short bound the default could be confused
    # with — finishes with every tick.
    assert {:ok, output} =
             function.function.(
               %{"command" => "for i in 1 2 3; do echo tick-$i; sleep 0.1; done"},
               nil
             )

    for i <- 1..3, do: assert(output =~ "tick-#{i}")
    refute output =~ "timed out"
  end

  test "the tool's schema declares `timeout` in seconds, default 60, no maximum, optional", %{
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
  end

  test "the tool rejects a non-positive or non-integer `timeout` as a tool error", %{ws: ws} do
    function = Tools.get_function("shell-cmd", Mounts.new(ws, nil))

    # Rejected before anything runs, so the tool error is the whole result.
    # The shape is the one `agents-wait`'s `timeout` rejection uses, so the
    # model is told what it got wrong instead of silently getting the
    # default.
    for bad <- [0, -1, 1.5, "5", true] do
      assert {:error, message} =
               function.function.(%{"command" => "echo nope", "timeout" => bad}, nil)

      assert message ==
               "Invalid `timeout` argument: expected a positive integer of seconds, " <>
                 "got: #{inspect(bad)}."
    end
  end

  test "the tool refuses to pipe output into head or tail", %{ws: ws} do
    function = Tools.get_function("shell-cmd", Mounts.new(ws, nil))

    # Rejected before anything runs, so no bwrap is needed and the tool error
    # is the whole result. Each command pipes into a pager at some stage.
    for command <- [
          "ls | head",
          "ls | head -n 5",
          "cat big.log | tail -f",
          "sort | uniq -c | sort -rn | head"
        ] do
      assert {:error, message} = function.function.(%{"command" => command}, nil)
      assert message =~ "will not pipe command output into"
      assert message =~ "head or tail"
    end

    # The offending command is named, so the model knows which pipe to drop.
    assert {:error, message} = function.function.(%{"command" => "dmesg | tail"}, nil)
    assert message =~ "will not pipe command output into `tail`"

    # The guard runs before the background/foreground split, so a backgrounded
    # command cannot smuggle a discarded pipe past it.
    assert {:error, message} =
             function.function.(
               %{"command" => "sort | uniq -c | head", "background" => true},
               nil
             )

    assert message =~ "will not pipe command output into `head`"
  end

  test "the tool rejects a detached-background marker, even with `background: true`", %{ws: ws} do
    function = Tools.get_function("shell-cmd", Mounts.new(ws, nil))

    # The check is a pure function of the command string, so `background: true`
    # does not get a marker past it: a `&` still makes the staged script exit at
    # once (reporting "exited 0" with no output), and bwrap has no controlling
    # terminal for `nohup`/`setsid`. Rejected before anything runs, so no bwrap
    # is needed and the tool error is the whole result.
    for command <- ["setsid sleep 1", "nohup sleep 1", "sleep 1 &"] do
      for args <- [%{"command" => command}, %{"command" => command, "background" => true}] do
        assert {:error, message} = function.function.(args, nil)
        assert message =~ "never runs a command detached"
        assert message =~ "background: true"
      end
    end
  end

  test "the tool rejects a non-string command instead of crashing ShellCmd", %{ws: ws} do
    function = Tools.get_function("shell-cmd", Mounts.new(ws, nil))

    # `Nest.LLM.Tools` only checks that the `command` key is present, so a list
    # reaches the tool; it must come back as a tool error rather than crashing
    # in `ShellCmd` (and leaking a staged script).
    assert {:error, message} = function.function.(%{"command" => ["echo X | head"]}, nil)

    assert message ==
             ~s{Invalid `command` argument: expected a string, got: ["echo X | head"].}
  end

  @tag :bwrap
  test "the tool still runs head/tail/grep directly and pipes into grep or other commands",
       %{ws: ws} do
    function = Tools.get_function("shell-cmd", Mounts.new(ws, nil))
    File.write!(Path.join(ws, "sample.txt"), "alpha\nbeta\n")

    # `head`/`grep` as the command word — no pipe into them — run normally.
    assert {:ok, output} = function.function.(%{"command" => "head -1 sample.txt"}, nil)
    assert output == "alpha\n"

    assert {:ok, output} = function.function.(%{"command" => "grep beta sample.txt"}, nil)
    assert output == "beta\n"

    # A pipe into `grep` is a legitimate filter (issue #106) and runs normally.
    assert {:ok, output} = function.function.(%{"command" => "cat sample.txt | grep beta"}, nil)
    assert output == "beta\n"

    # A pipe into a command other than a pager is unaffected.
    assert {:ok, output} = function.function.(%{"command" => "echo hi | tr a-z A-Z"}, nil)
    assert output == "HI\n"
  end

  @tag :bwrap
  test "a symlinked workspace is bound at its canonical path; read and write work through the symlink",
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

    File.write!(Path.join(real, "hello.txt"), "symlink-ok\n")

    # Default caps bind the canonical workspace read-write; --chdir
    # targets the user's symlinked path. Reading and writing through
    # the symlink must resolve to the canonical writable mount.
    assert {:ok, output} = ShellCmd.execute("cat hello.txt", Mounts.new(link, nil), nil, [])
    assert output =~ "symlink-ok"

    assert {:ok, _} = ShellCmd.execute("echo written > out.txt", Mounts.new(link, nil), nil, [])
    assert File.read!(Path.join(real, "out.txt")) =~ "written"
  end

  test "a missing workspace returns an error without bwrap creating it", %{ws: ws} do
    missing = Path.join(ws, "nest_missing_#{System.unique_integer([:positive])}")

    # The workspace is validated before bwrap runs, so a missing
    # directory surfaces as a clean error and is never auto-created.
    assert {:error, message} = ShellCmd.execute("true", Mounts.new(missing, nil), nil, [])
    assert message =~ "does not exist"

    refute File.exists?(missing)
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

  test "there is no set -e, and the exit code of the last statement is what is reported", %{
    ws: ws
  } do
    assert {:ok, output} = ShellCmd.execute("false\necho survived", Mounts.new(ws, nil), nil, [])
    assert output =~ "survived"

    # A non-zero exit is a deliberate diagnostic — capture it so it
    # doesn't escape into the test log.
    log =
      capture_log(fn ->
        assert {:error, output} =
                 ShellCmd.execute("echo before\nexit 3", Mounts.new(ws, nil), nil, [])

        assert output =~ "before"
        assert output =~ "Exit code 3"
      end)

    assert log =~ "ShellCmd.execute: bwrap exited non-zero"
    assert log =~ "exit_code=3"
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
      # and the `docker` and `none` iterations fail; the `bwrap` ones still match,
      # because `Sandbox.build/4`'s own gate produces the same message. That
      # asymmetry is why the loop covers all three: with only `bwrap` here, two of
      # the three backends could reopen the escalation with a green suite.
      for {backend, filename} <-
            Enum.flat_map(
              ["bwrap", "docker", "none"],
              &[{&1, ".nest"}, {&1, "AGENTS.md"}]
            ) do
        # A fresh workspace per case: `ConfigFile.error/1` reports the *first*
        # offender, so both files cannot be symlinked in one directory and both
        # be observed.
        case_ws = Path.join(ws, "#{backend}-#{filename}")
        File.mkdir_p!(case_ws)
        real = Path.join(case_ws, "real")
        File.write!(real, "")
        File.ln_s!(real, Path.join(case_ws, filename))

        log =
          capture_log(fn ->
            assert {:error, msg} =
                     ShellCmd.execute("echo hi", Mounts.new(case_ws, nil, backend), nil)

            assert msg =~ "not a regular file"
            assert msg =~ filename
          end)

        assert log =~ "Nest cannot protect it from being rewritten"
      end
    end
  end
end
