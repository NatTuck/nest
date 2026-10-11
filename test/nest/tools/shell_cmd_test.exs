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
  naturally. This keeps the test fast (sub-second) without
  requiring mocks or a long-running command.
  """

  use ExUnit.Case, async: true

  import Eventually
  import ExUnit.CaptureLog

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
        assert {:error, message} = ShellCmd.execute("true", ws, nil, nil, [])

        assert message =~ "Exit code 130"
        assert message =~ "[Command cancelled]"
      end)

    # The bwrap non-zero exit on cancel is a deliberate
    # diagnostic — assert on it so the test's intent is
    # self-documenting and the log doesn't escape.
    assert log =~ "ShellCmd.execute: bwrap exited non-zero"
    assert log =~ "exit_code=130"
  end

  test "execute/5 returns the natural output for a successful command", %{ws: ws} do
    # Sanity check that the receive doesn't match the
    # pre-seeded stop when none is in the mailbox. A trivial
    # `true` command exits 0 immediately and bwrap reports
    # the success path.
    assert {:ok, output} = ShellCmd.execute("true", ws, nil, nil, [])

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
                   ws,
                   nil,
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
        ws,
        nil,
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
    function = Tools.get_function("shell-cmd", ws)

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
  # (peeked, never received) so the second call's outcome is deterministic
  # rather than a race against its arrival, which is measured at ~5-15ms
  # after `:exec.stop/1`.
  @tag :bwrap
  test "a timed-out call does not swallow the next call's result", %{ws: ws} do
    log =
      capture_log(fn ->
        assert {:error, first} =
                 ShellCmd.execute("echo first; sleep 5", ws, nil, nil, timeout: 50)

        assert first =~ "[Command timed out after 50ms]"
        assert eventually(fn -> stale_down_pending?() end, timeout: 500, interval: 10)

        # Call 2's own output. With the stale `:DOWN` it is the empty-output
        # placeholder instead, returned before its command had finished.
        assert {:ok, second} = ShellCmd.execute("echo second", ws, nil, nil, [])
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
    function = Tools.get_function("shell-cmd", ws)

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
    tool = Tools.get_function("shell-cmd", ws)
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
    function = Tools.get_function("shell-cmd", ws)

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
    # Clear any stale entries first (guarded by the `nest_bwrap` name).
    File.rm_rf([real, link])
    File.mkdir_p!(real)
    File.ln_s!(real, link)
    on_exit(fn -> File.rm_rf([real, link]) end)

    File.write!(Path.join(real, "hello.txt"), "symlink-ok\n")

    # Default caps bind the canonical workspace read-write; --chdir
    # targets the user's symlinked path. Reading and writing through
    # the symlink must resolve to the canonical writable mount.
    assert {:ok, output} = ShellCmd.execute("cat hello.txt", link, nil, nil, [])
    assert output =~ "symlink-ok"

    assert {:ok, _} = ShellCmd.execute("echo written > out.txt", link, nil, nil, [])
    assert File.read!(Path.join(real, "out.txt")) =~ "written"
  end

  test "a missing workspace returns an error without bwrap creating it", %{ws: ws} do
    missing = Path.join(ws, "nest_missing_#{System.unique_integer([:positive])}")

    # The workspace is validated before bwrap runs, so a missing
    # directory surfaces as a clean error and is never auto-created.
    assert {:error, message} = ShellCmd.execute("true", missing, nil, nil, [])
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

    assert {:ok, output} = ShellCmd.execute(command, ws, nil, nil, [])
    assert output =~ ~s{HELLO "WORLD" }
  end

  test "stdin is delivered over a pipe, and an absent stdin gives an immediate EOF", %{ws: ws} do
    assert {:ok, output} = ShellCmd.execute("wc -c", ws, nil, nil, stdin: "abcde")
    assert String.trim(output) == "5"

    assert {:ok, output} = ShellCmd.execute("wc -c", ws, nil, nil, [])
    assert String.trim(output) == "0"
  end

  test "a timeout places its annotation in stderr so raw callers see it", %{ws: ws} do
    # `execute_raw` discards the combined output; the marker must reach it via
    # stderr, or a timed-out glob/read would classify as an empty `:read_failed`
    # with no signal at all.
    assert {:ok, 1, _stdout, stderr} =
             ShellCmd.execute_raw("sleep 5", ws, nil, nil, timeout: 50)

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
    assert {:ok, output} = ShellCmd.execute(~s{basename "$0"}, ws, tmp, nil, [])
    assert output =~ "nest-cmd-"

    # The transcript is temporary either way: the caller gets the output.
    assert {:ok, _} = ShellCmd.execute("echo bye", ws, tmp, nil, [])
    assert Path.wildcard(Path.join(stage, "nest-cmd-*.sh")) == []
  end

  test "there is no set -e, and the exit code of the last statement is what is reported", %{
    ws: ws
  } do
    assert {:ok, output} = ShellCmd.execute("false\necho survived", ws, nil, nil, [])
    assert output =~ "survived"

    # A non-zero exit is a deliberate diagnostic — capture it so it
    # doesn't escape into the test log.
    log =
      capture_log(fn ->
        assert {:error, output} = ShellCmd.execute("echo before\nexit 3", ws, nil, nil, [])
        assert output =~ "before"
        assert output =~ "Exit code 3"
      end)

    assert log =~ "ShellCmd.execute: bwrap exited non-zero"
    assert log =~ "exit_code=3"
  end

  test "large stdin streams over the pipe and never hits an ARG_MAX ceiling", %{ws: ws} do
    payload = :binary.copy("abcdefgh", 400_000)

    assert {:ok, _} = ShellCmd.execute("cat > big.bin", ws, nil, nil, stdin: payload)
    assert File.stat!(Path.join(ws, "big.bin")).size == byte_size(payload)
  end

  # Peek at the mailbox without consuming from it: `true` once a `:DOWN` is
  # pending. Only this test's own bwrap processes can have sent one.
  defp stale_down_pending? do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.any?(messages, &match?({:DOWN, _ref, :process, _pid, _reason}, &1))
  end
end
