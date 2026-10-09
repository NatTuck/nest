defmodule Nest.TimelineTest do
  # Not async: enablement lives in application/OS environment state and
  # `Mix.shell/1` is global. The writer's own state (the run id, the
  # per-directory disable flag) is deliberately process-global too, so the
  # tests point `:timeline_dir` at a fresh tmp directory each time rather
  # than resetting it.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nest.Timeline
  alias Nest.Timeline.Digest

  setup do
    dir = Path.join(System.tmp_dir!(), "nest-timeline-test-#{System.unique_integer([:positive])}")
    Application.put_env(:nest, :timeline_dir, dir)

    on_exit(fn ->
      Application.delete_env(:nest, :timeline_dir)
      Application.delete_env(:nest, :timeline_enabled)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  defp enable!, do: Application.put_env(:nest, :timeline_enabled, true)

  defp read_events(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  describe "enablement" do
    test "is off by default, on via the environment, and config wins" do
      # The env var is the one piece of global state this test owns, so it
      # is cleared first and removed again afterwards.
      System.delete_env("NEST_TIMELINE")
      refute Timeline.enabled?()

      System.put_env("NEST_TIMELINE", "1")
      on_exit(fn -> System.delete_env("NEST_TIMELINE") end)
      assert Timeline.enabled?()

      Application.put_env(:nest, :timeline_enabled, false)
      refute Timeline.enabled?()

      Application.put_env(:nest, :timeline_enabled, true)
      assert Timeline.enabled?()
    end

    test "a disabled writer writes nothing and creates no run directory", %{dir: dir} do
      Application.put_env(:nest, :timeline_enabled, false)

      assert Timeline.record(7, "coordinator", :turn, %{event: :stop}) == :ok

      refute File.exists?(Timeline.events_path())
      refute File.dir?(Timeline.run_dir())
      assert String.starts_with?(Timeline.run_dir(), dir)
    end
  end

  describe "recording" do
    test "appends one JSONL line per event, with the common fields", %{dir: dir} do
      enable!()

      assert Timeline.record(7, "coordinator", :debt, %{action: :set, peer: "alice"}) == :ok
      assert Timeline.record(7, "worker-1", :turn, %{event: :stop, iteration: 1}) == :ok

      # The run id is captured once per OS process, so every event of a
      # session lands in one file.
      assert Timeline.run_dir() == Timeline.run_dir()
      assert Path.dirname(Timeline.events_path()) == Timeline.run_dir()
      assert String.starts_with?(Timeline.events_path(), dir)

      assert [first, second] = read_events(Timeline.events_path())
      assert first["space"] == 7
      assert first["agent"] == "coordinator"
      assert first["type"] == "debt"
      assert first["action"] == "set"
      assert first["peer"] == "alice"
      assert is_integer(first["mono"])
      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(first["ts"])
      assert second["agent"] == "worker-1"
      assert second["iteration"] == 1
    end

    test "a malformed payload or type is recorded defensively rather than raising" do
      enable!()

      assert Timeline.record(7, "coordinator", :turn, "not a map") == :ok
      assert Timeline.record(7, "coordinator", "turn", %{"already" => "string"}) == :ok
      assert Timeline.record(7, "coordinator", {:weird, :type}, %{{1, 2} => "x"}) == :ok

      assert [first, second, third] = read_events(Timeline.events_path())
      assert first["payload"] == ~s("not a map")
      assert second["type"] == "turn"
      assert second["already"] == "string"
      assert third["type"] == "{:weird, :type}"
      assert third["{1, 2}"] == "x"
    end

    test "a payload that cannot be encoded is a stub, and does not disable the writer" do
      enable!()

      log =
        capture_log(fn ->
          assert Timeline.record(7, "coordinator", :turn, %{event: self()}) == :ok
          # An identity the JSON encoder cannot carry is stubbed as a
          # string, so the stub itself always encodes.
          assert Timeline.record(self(), "coordinator", :turn, %{event: self()}) == :ok
        end)

      assert log =~ "could not be encoded"

      assert [stub, pid_space] = read_events(Timeline.events_path())
      assert stub["type"] == "turn"
      assert stub["space"] == 7
      assert stub["encode_error"] =~ "PID"
      refute Map.has_key?(stub, "truncated")
      assert pid_space["space"] =~ "#PID"

      # The writer itself is fine, so the next event is recorded normally.
      assert Timeline.record(7, "coordinator", :turn, %{event: :stop}) == :ok
      assert length(read_events(Timeline.events_path())) == 3
    end

    test "an oversized line is bounded to a stub, once" do
      enable!()

      payload = %{name: "shell-cmd", result_bytes: 20_000, blob: String.duplicate("z", 20_000)}

      log =
        capture_log(fn ->
          assert Timeline.record(7, "coordinator", :tool, payload) == :ok
          assert Timeline.record(7, "coordinator", :tool, payload) == :ok
        end)

      assert log =~ "recorded as a stub"
      # Logged once, not once per event.
      assert length(String.split(log, "recorded as a stub")) == 2

      assert [stub, _second] = read_events(Timeline.events_path())
      assert stub["truncated"] == true
      assert stub["line_bytes"] > 8_192
      assert stub["type"] == "tool"
      # The payload is dropped: this is the "do not fill the disk" net.
      refute Map.has_key?(stub, "name")
    end

    test "a write failure logs once, disables the writer, and never raises", %{dir: dir} do
      File.mkdir_p!(dir)
      blocker = Path.join(dir, "blocker")
      File.write!(blocker, "not a directory")
      Application.put_env(:nest, :timeline_dir, Path.join(blocker, "nested"))
      enable!()

      log =
        capture_log(fn ->
          assert Timeline.record(7, "coordinator", :turn, %{event: :stop}) == :ok
          assert Timeline.record(7, "coordinator", :turn, %{event: :stop}) == :ok
        end)

      assert log =~ "recording disabled"
      assert length(String.split(log, "recording disabled")) == 2
    end

    test "a directory that cannot even be computed does not raise into the caller", %{dir: dir} do
      # `run_dir/0` sits outside `do_write/5`'s rescue, and a `:timeline_dir` that
      # is not a binary makes `Path.join/2` raise a `FunctionClauseError` — which
      # would come out of `record/4`, i.e. into whatever settle called the
      # emitter. The guard covers the directory computation too.
      Application.put_env(:nest, :timeline_dir, 123)
      enable!()

      log =
        capture_log(fn ->
          assert Timeline.record(7, "coordinator", :turn, %{event: :stop}) == :ok
          assert Timeline.record(7, "coordinator", :turn, %{event: :stop}) == :ok
        end)

      assert log =~ "recording disabled"
      assert length(String.split(log, "recording disabled")) == 2

      Application.put_env(:nest, :timeline_dir, dir)
    end
  end

  describe "redaction" do
    test "keeps a bounded head plus the full size" do
      long = String.duplicate("x", 500)
      redacted = Timeline.redact("args", long)

      assert redacted["args_bytes"] == 500
      assert String.starts_with?(redacted["args_head"], "xxx")
      assert String.ends_with?(redacted["args_head"], "…")
      assert String.length(redacted["args_head"]) == 201

      assert Timeline.redact("content", "hi") == %{"content_head" => "hi", "content_bytes" => 2}
      assert Timeline.redact("args", nil) == %{"args_head" => "", "args_bytes" => 0}
      assert Timeline.redact("args", 123)["args_head"] == "123"
    end

    test "never produces an invalid head, whatever the content is" do
      # A cut that lands inside a 3-byte character drops the partial tail.
      euro = String.duplicate("€", 100)
      head = Timeline.redact("args", euro)["args_head"]
      assert String.valid?(head)
      assert String.ends_with?(head, "…")

      # Invalid UTF-8 (a binary tool result) is sanitised, not raised on.
      binary = <<0xFF, 0xFE>> <> String.duplicate("y", 500)
      redacted = Timeline.redact("result", binary)
      assert redacted["result_bytes"] == 502
      assert String.valid?(redacted["result_head"])

      assert Timeline.bytes(<<1, 2, 3>>) == 3
      assert Timeline.bytes(nil) == 0
      assert Timeline.bytes(%{a: 1}) > 0
    end
  end

  describe "reading a run" do
    test "reports a malformed line by number and keeps the good ones", %{dir: dir} do
      run = write_run(dir, [event(1), "{oops", event(2), "[1,2]"])

      assert {events, problems} = Timeline.load(run)
      assert Enum.map(events, & &1["mono"]) == [1, 2]
      assert [{2, bad_json}, {4, not_object}] = problems
      assert bad_json =~ "invalid JSON"
      assert not_object =~ "not a JSON object"
    end

    test "reports a run directory it cannot read", %{dir: dir} do
      assert {[], [{:file, reason}]} = Timeline.load(Path.join(dir, "missing"))
      assert reason =~ "cannot read"
    end

    test "latest_run/0 picks the newest directory, and is nil when there are none", %{dir: dir} do
      assert Timeline.latest_run() == nil

      old = Path.join(dir, "old")
      new = Path.join(dir, "new")
      File.mkdir_p!(old)
      File.mkdir_p!(new)
      File.touch!(old, {{2026, 1, 1}, {0, 0, 0}})
      File.touch!(new, {{2026, 1, 2}, {0, 0, 0}})
      File.write!(Path.join(dir, "not-a-run.txt"), "")

      assert Timeline.latest_run() == new
    end
  end

  describe "the digest" do
    test "summarises the run and interleaves every kind per agent", %{dir: dir} do
      run = write_run(dir, fixture())
      digest = Digest.render(run)

      assert digest =~ "Timeline digest — #{run}"
      assert digest =~ "events: 19"
      assert digest =~ "  spaces: 1   agents: 2"
      assert digest =~ "  turns: 3   llm requests: 1"
      assert digest =~ "tokens: in 1.2M out 4.2k cache r 80.0k w 0"
      assert digest =~ "  tool calls: 2 (1 error)"
      assert digest =~ "inbox: enqueued 0 · queued 1 · delivered 1 · drained 0 · refused 0"
      assert digest =~ "debts: set 1 · cleared 0 · reminded 0 · gave_up 1 · give_up_refused 0"
      assert digest =~ "  compactions: 1"

      assert digest =~
               "children: spawned 1 · completed 0 · failed 0 · terminated 0 · archived 0 · stopped 0"

      assert digest =~ "  notifications: 1   errors: 1"

      assert digest =~ "space 7 · agent coordinator  (18 events)"
      assert digest =~ "generating/chat → executing_tools/chat · tool_results · iter 2/25"
      # A list of small integers is data, not a charlist.
      assert digest =~ "iter 2/25 · message_indices=[12, 13]"
      assert digest =~ "12345/200000 projected (reserve 16000, remaining 171655) · gpt-4o · sent"
      # No `ms` segment: no emitter sends a per-call duration, so a real tool
      # line has nothing to put there (a line that carried `duration_ms` would
      # show it through the generic tail as `duration_ms=120`).
      assert digest =~ "shell-cmd args 440B result 2100B · tool-1 · call-9 · echo hello"
      assert digest =~ "file-write args 6B result 0B · tool-2 · call-10 · ERROR"
      assert digest =~ "delivered from alice kind query 42B count 1 · delivered"
      assert digest =~ "queued from bob kind user 900B count 2 · queued · mode build"
      assert digest =~ "gave_up peer carol reminders 1 · no_reminder"
      # A nested map is flattened one level: the number the kit exists for is
      # never the field a value bound cut off.
      assert digest =~
               "payload owedReplies=[\"carol\"] pendingMessageCount=2 status=streaming " <>
                 "usage.context_input_tokens=123 usage.total_tokens=456"

      assert digest =~ "payload -"
      assert digest =~ "max_iterations · Max tool iterations reached"
      assert digest =~ "Nest.Agents.Agent.Turn/1 · boom"

      assert digest =~
               "reserve_exhausted · limit 200000 reserve 16000 used 190000 projected 205000"

      assert digest =~ "carried 3 · loops 1 · archived→88"
      assert digest =~ "in 1200000 out 4200 cache r 80000 w n/a · total 1284200"
      assert digest =~ "spawned worker-1 (programmer, depth 1, gpt-4o) · clone_context"

      assert digest =~
               "?  unknown_thing  flag=true nested=[1, 2] nested_map.a=1 ratio=0.50"

      # A second turn in the same group, with string phases and a newline
      # in a recorded string: the layout must survive both.
      assert digest =~ "generating → idle · stop · iter 1/25"
      assert digest =~ "space 7 · agent worker-1  (1 event)"
      assert digest =~ "· note=boom"

      # No problems, so no problems section.
      refute digest =~ "Unreadable lines"
    end

    test "reports unreadable lines and still renders the rest", %{dir: dir} do
      run = write_run(dir, [event(1), "{oops", event(2)])
      digest = Digest.render(run)

      assert digest =~ "events: 2   unreadable lines: 1"
      assert digest =~ "Unreadable lines\n  line 2: invalid JSON:"
    end

    test "renders an empty run, and one with no events file, without crashing", %{dir: dir} do
      empty = write_run(dir, [])
      digest = Digest.render(empty)

      assert digest =~ "events: 0"
      assert digest =~ "  turns: 0   llm requests: 0   tokens: in 0 out 0 cache r 0 w 0"
      assert digest =~ "  spaces: 0   agents: 0"
      refute digest =~ "· agent"

      run = Path.join(dir, "no-events-file")
      File.mkdir_p!(run)
      missing = Digest.render(run)
      assert missing =~ "events: 0   unreadable lines: 1"
      assert missing =~ "file: cannot read"
    end

    test "filters by space and agent", %{dir: dir} do
      run =
        write_run(dir, [
          event(1, 7, "coordinator"),
          event(2, 7, "worker-1"),
          event(3, 9, "coordinator")
        ])

      assert Digest.render(run, space: "7") =~ "events: 2"
      refute Digest.render(run, space: "7") =~ "space 9"
      assert Digest.render(run, agent: "worker-1") =~ "events: 1"
      # Compared as strings, so an integer option matches too.
      assert Digest.render(run, space: 9, agent: "coordinator") =~ "events: 1"
      assert Digest.render(run, space: "nope") =~ "events: 0"
    end
  end

  describe "mix nest.timeline" do
    test "parse_args/1 accepts the documented flags and rejects unknown ones" do
      assert Mix.Tasks.Nest.Timeline.parse_args(["--run", "r", "--space", "7", "--agent", "a"]) ==
               {:ok, [run: "r", space: "7", agent: "a"]}

      assert Mix.Tasks.Nest.Timeline.parse_args([]) == {:ok, []}
      assert {:error, message} = Mix.Tasks.Nest.Timeline.parse_args(["--nope"])
      assert message =~ "--nope"
    end

    test "run/1 prints the digest, the no-runs hint, and raises on bad args", %{dir: dir} do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      Mix.Tasks.Nest.Timeline.run([])
      assert_received {:mix_shell, :info, [message]}
      assert message =~ "No runs found under #{dir}/"
      assert message =~ "NEST_TIMELINE=1"

      run = write_run(dir, [event(1)], "20260101-000000-1")
      Mix.Tasks.Nest.Timeline.run(["--run", run, "--agent", "coordinator"])
      assert_received {:mix_shell, :info, [message]}
      assert message =~ "Timeline digest — #{run}"
      assert message =~ "events: 1"

      assert_raise Mix.Error, fn -> Mix.Tasks.Nest.Timeline.run(["--nope"]) end
    end
  end

  # ---- fixture helpers ----

  defp write_run(dir, lines, name \\ "20260101-000000-1") do
    run = Path.join(dir, name)
    File.mkdir_p!(run)
    body = Enum.map_join(lines, "\n", &encode_line/1)
    File.write!(Path.join(run, "events.jsonl"), body <> "\n")
    run
  end

  defp encode_line(raw) when is_binary(raw), do: raw
  defp encode_line(map), do: Jason.encode!(map)

  defp event(mono, space \\ 7, agent \\ "coordinator") do
    %{
      "ts" => "2026-01-01T00:00:00Z",
      "mono" => mono,
      "space" => space,
      "agent" => agent,
      "type" => "turn",
      "event" => "stop"
    }
  end

  # One event of every type, plus one the digest does not know, so the
  # rendering of each is pinned. Written as data rather than through the
  # writer, so the reader is tested against the file format itself. The
  # common fields are hoisted into `ev/4` so the payloads stay readable.
  defp fixture do
    [
      ev(100, "turn", %{
        "ts" => "2026-01-01T00:00:01Z",
        "event" => "tool_results",
        "from" => %{"kind" => "generating", "phase" => "chat"},
        "to" => %{"kind" => "executing_tools", "phase" => "chat"},
        "iteration" => 2,
        "max_iterations" => 25,
        "message_indices" => [12, 13]
      }),
      ev(101, "llm", %{
        "message_index" => 12,
        "iteration" => 2,
        "model" => "gpt-4o",
        "projected_tokens" => 12_345,
        "limit" => 200_000,
        "reserve" => 16_000,
        "remaining" => 171_655,
        "outcome" => "sent"
      }),
      ev(102, "tool", %{
        "name" => "shell-cmd",
        "args_head" => "echo hello",
        "args_bytes" => 440,
        "result_bytes" => 2100,
        "is_error" => false,
        "worker" => "tool-1",
        "tool_call_id" => "call-9"
      }),
      ev(103, "tool", %{
        "name" => "file-write",
        "args_bytes" => 6,
        "result_bytes" => 0,
        "is_error" => true,
        "worker" => "tool-2",
        "tool_call_id" => "call-10"
      }),
      ev(104, "inbox", %{
        "action" => "delivered",
        "from" => "alice",
        "kind" => "query",
        "mode" => nil,
        "bytes" => 42,
        "count" => 1,
        "disposition" => "delivered"
      }),
      ev(105, "inbox", %{
        "action" => "queued",
        "from" => "bob",
        "kind" => "user",
        "mode" => "build",
        "bytes" => 900,
        "count" => 2,
        "disposition" => "queued"
      }),
      ev(106, "debt", %{
        "action" => "set",
        "peer" => "alice",
        "reminders_used" => 0,
        "how" => "delivery"
      }),
      ev(107, "debt", %{
        "action" => "gave_up",
        "peer" => "carol",
        "reminders_used" => 1,
        "how" => "no_reminder"
      }),
      ev(108, "status", %{
        "payload" => %{
          "status" => "streaming",
          "pendingMessageCount" => 2,
          "owedReplies" => ["carol"],
          # The real `chat:status` payload carries the usage map nested like
          # this: rendered as one value, the bound would hide every field
          # behind the first.
          "usage" => %{"context_input_tokens" => 123, "total_tokens" => 456}
        }
      }),
      ev(109, "notification", %{
        "notification_type" => "max_iterations",
        "message" => "Max tool\niterations reached"
      }),
      ev(110, "error", %{"message" => "boom", "source" => "Nest.Agents.Agent.Turn/1"}),
      ev(111, "compaction", %{
        "trigger" => "reserve_exhausted",
        "limit" => 200_000,
        "reserve" => 16_000,
        "used" => 190_000,
        "projected" => 205_000,
        "carried" => 3,
        "loop_count" => 1,
        "archived_to_index" => 88
      }),
      ev(112, "usage", %{
        "input" => 1_200_000,
        "output" => 4_200,
        "cache_read" => 80_000,
        "cache_write" => "n/a",
        "total" => 1_284_200
      }),
      ev(113, "child", %{
        "action" => "spawned",
        "name" => "worker-1",
        "vocation" => "programmer",
        "depth" => 1,
        "model" => "gpt-4o",
        "clone_context" => true,
        "archive" => false
      }),
      # An empty payload renders as a bare marker rather than a dangling
      # label.
      ev(116, "status", %{"payload" => %{}}),
      # A status event whose payload is not the expected map: it still
      # renders rather than taking the digest down.
      ev(117, "status", %{"payload" => "oops"}),
      # A line with no `mono` at all, of a type the digest does not know:
      # both must render rather than take the digest down.
      no_mono("unknown_thing", %{
        "ratio" => 0.5,
        "nested" => [1, 2],
        "nested_map" => %{"a" => 1},
        "flag" => true
      }),
      ev(114, "worker-1", "turn", %{
        "event" => "stop",
        "from" => "generating",
        "to" => "idle",
        "iteration" => 1,
        "max_iterations" => 25
      }),
      # A turn in the coordinator group whose recorded text carries a
      # newline: it must stay on one line.
      ev(115, "turn", %{
        "event" => "stop",
        "from" => "generating",
        "to" => "idle",
        "iteration" => 1,
        "max_iterations" => 25,
        "note" => "boom"
      })
    ]
  end

  defp ev(mono, type, payload), do: ev(mono, "coordinator", type, payload)

  defp ev(mono, agent, type, payload) do
    Map.merge(%{"mono" => mono, "space" => 7, "agent" => agent, "type" => type}, payload)
  end

  defp no_mono(type, payload) do
    Map.merge(%{"space" => 7, "agent" => "coordinator", "type" => type}, payload)
  end
end
