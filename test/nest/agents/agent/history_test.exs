defmodule Nest.Agents.Agent.HistoryTest do
  @moduledoc """
  Coverage for `agents-history` (issue #22): the range read with Python-style
  negative indices, the search mode's JSON shape, the out-of-range refusals,
  and the space scoping that keeps the tool inside the caller's own space.

  The history is seeded through the canonical append path
  (`{:append_message, _}`), so the rows the reader queries are the ones the
  runtime actually writes, and the live state and the DB agree.
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.Registry
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Sandbox.Mounts

  setup do
    {pid, name} = AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus"}})
    %{pid: pid, name: name, space_id: AgentTestHelpers.current_space_id()}
  end

  # The tool dispatch, end to end: `ToolLoop.execute/3` routes `agents-history`
  # to this worker's executor, and the BatchSizer logs an `is_error=true` line
  # for an error result, so the log is captured (never printed).
  defp run(space_id, agent_name, args, overrides \\ %{}) do
    ctx =
      Map.merge(
        %{
          space_id: space_id,
          agent_name: agent_name,
          agent_pid: nil,
          context_limit: 100_000,
          messages: []
        },
        overrides
      )

    {[%ToolResult{} = result], log} =
      with_log(fn ->
        ToolLoop.execute(ctx, nil, [%ToolCall{id: "h1", name: "agents-history", arguments: args}])
      end)

    {result, log}
  end

  defp append(pid, {_role, _message} = message) do
    {_role, _stamped} = GenServer.call(pid, {:append_message, message})
    :ok
  end

  defp text(:user, body), do: {:user, %User{parts: [%Part.Text{text: body}]}}
  defp text(:assistant, body), do: {:assistant, %Assistant{parts: [%Part.Text{text: body}]}}

  defp indexed(:user, index, body),
    do: {:user, %User{index: index, parts: [%Part.Text{text: body}]}}

  defp indexed(:assistant, index, body),
    do: {:assistant, %Assistant{index: index, parts: [%Part.Text{text: body}]}}

  # system(0) user(1) assistant(2) user(3) assistant(4)
  defp seed_conversation(pid) do
    append(pid, text(:user, "the first question"))
    append(pid, text(:assistant, "first reply"))
    append(pid, text(:user, "the second question"))
    append(pid, text(:assistant, "the report is ready"))
  end

  describe "a range read" do
    test "returns the requested window, and a negative start_index reaches the end", %{
      pid: pid,
      name: name,
      space_id: space_id
    } do
      seed_conversation(pid)

      # A non-negative start counts from the first message; the window runs
      # forward from it.
      {result, _log} = run(space_id, name, %{"start_index" => 1, "length" => 2})

      assert %ToolResult{name: "agents-history", is_error: false, content: content} = result
      assert content =~ "History of agent \"#{name}\": 5 message(s), indices 0..4."
      assert content =~ "Showing 1..2 (2)."
      assert content =~ "[1] user:\nthe first question"
      assert content =~ "[2] assistant:\nfirst reply"

      # -1 is the last message; the default length is 1.
      {last, _log} = run(space_id, name, %{"start_index" => -1})

      assert %ToolResult{is_error: false, content: content} = last
      assert content =~ "Showing 4..4 (1)."
      assert content =~ "[4] assistant:\nthe report is ready"

      # The last N messages are `start_index: -N, length: N`.
      {three, _log} = run(space_id, name, %{"start_index" => -3, "length" => 3})

      assert %ToolResult{is_error: false, content: content} = three
      assert content =~ "Showing 2..4 (3)."
      assert content =~ "[3] user:\nthe second question"

      # No `name` means the caller itself, and no `start_index` means the last
      # message: the whole call is `agents-history()`.
      {default, _log} = run(space_id, name, %{})

      assert %ToolResult{is_error: false, content: content} = default
      assert content =~ "Showing 4..4 (1)."
      assert content =~ "[4] assistant:\nthe report is ready"
    end

    test "renders tool calls and results, and searches their text", %{
      pid: pid,
      name: name,
      space_id: space_id
    } do
      append(pid, text(:user, "run the thing"))

      append(
        pid,
        {:assistant,
         %Assistant{
           parts: [
             %Part.ToolUse{id: "call_1", name: "shell-cmd", arguments: %{"command" => "ls"}}
           ]
         }}
      )

      append(
        pid,
        {:tool,
         %Tool{
           parts: [
             %Part.ToolResult{
               tool_call_id: "call_1",
               name: "shell-cmd",
               content: "hello from the shell",
               is_error: false
             }
           ]
         }}
      )

      {result, _log} = run(space_id, name, %{"start_index" => -2, "length" => 2})

      assert %ToolResult{is_error: false, content: content} = result
      assert content =~ ~s([2] assistant:\n[tool_use shell-cmd] {"command":"ls"})
      assert content =~ "[3] tool:\n[tool_result shell-cmd]\nhello from the shell"

      # The search corpus is the same text the range read shows, so a hit in a
      # tool result is findable.
      {found, _log} = run(space_id, name, %{"search" => "hello from the shell"})

      assert %ToolResult{is_error: false, content: content} = found

      assert %{"matches" => [match]} = Jason.decode!(content)
      assert match["index"] == 3
      assert match["role"] == "tool"
    end
  end

  describe "search" do
    test "returns a JSON list of matches carrying their index, role and text", %{
      pid: pid,
      name: name,
      space_id: space_id
    } do
      seed_conversation(pid)

      {result, _log} = run(space_id, name, %{"search" => "report"})

      assert %ToolResult{name: "agents-history", is_error: false, content: content} = result

      assert %{
               "agent" => ^name,
               "query" => "report",
               "matches" => [match]
             } = Jason.decode!(content)

      assert match == %{
               "index" => 4,
               "role" => "assistant",
               "text" => "the report is ready",
               "text_truncated" => false
             }

      # The match is case-insensitive.
      {insensitive, _log} = run(space_id, name, %{"search" => "REPLY"})

      assert %ToolResult{is_error: false, content: content} = insensitive
      assert %{"matches" => [%{"index" => 2, "role" => "assistant"}]} = Jason.decode!(content)

      # Several matches come back in index order.
      {many, _log} = run(space_id, name, %{"search" => "question"})

      assert %ToolResult{is_error: false, content: content} = many
      assert %{"matches" => matches} = Jason.decode!(content)
      assert Enum.map(matches, & &1["index"]) == [1, 3]

      # No match is an empty list, not an error: "nothing matched" is an answer.
      {none, _log} = run(space_id, name, %{"search" => "zzz-not-there"})

      assert %ToolResult{is_error: false, content: content} = none
      assert %{"matches" => []} = Jason.decode!(content)
    end

    test "a long message's snippet is clipped around the match", %{
      pid: pid,
      name: name,
      space_id: space_id
    } do
      append(
        pid,
        text(
          :user,
          String.duplicate("filler ", 100) <> "the needle" <> String.duplicate(" tail", 100)
        )
      )

      {result, _log} = run(space_id, name, %{"search" => "needle"})

      assert %ToolResult{is_error: false, content: content} = result
      assert %{"matches" => [match]} = Jason.decode!(content)

      assert match["index"] == 1
      assert match["role"] == "user"
      assert match["text_truncated"] == true
      assert match["text"] =~ "the needle"
      # Clipped on both sides, and the markers say so.
      assert String.starts_with?(match["text"], "…")
      assert String.ends_with?(match["text"], "…")
    end
  end

  describe "refusals" do
    test "out-of-range and malformed arguments are errors naming the valid range", %{
      pid: pid,
      name: name,
      space_id: space_id
    } do
      seed_conversation(pid)

      {out_of_range, log} = run(space_id, name, %{"start_index" => -99})

      assert %ToolResult{name: "agents-history", is_error: true, content: content} = out_of_range

      assert content ==
               "start_index -99 is out of range: agent #{name} has 5 messages, " <>
                 "so valid indices are -5..4."

      assert log =~ "BatchSizer produced is_error=true tool result"

      {past_end, _log} = run(space_id, name, %{"start_index" => 3, "length" => 4})

      assert %ToolResult{is_error: true, content: content} = past_end

      assert content ==
               "start_index 3 with length 4 runs past the end: agent #{name} has 5 " <>
                 "messages (indices 0..4), so at most 2 can be read from index 3."

      # A negative start resolves once and the window runs forward, so `-1` with
      # a length above 1 runs off the end — the plausible misreading of the
      # "last N" idiom the description teaches (`-N` with `length: N`).
      {negative_past_end, _log} = run(space_id, name, %{"start_index" => -1, "length" => 5})

      assert %ToolResult{is_error: true, content: content} = negative_past_end

      assert content ==
               "start_index -1 with length 5 runs past the end: agent #{name} has 5 " <>
                 "messages (indices 0..4), so at most 1 can be read from index 4."

      {bad_length, _log} = run(space_id, name, %{"length" => 0})

      assert %ToolResult{is_error: true, content: content} = bad_length
      assert content == "Invalid `length` argument: expected a positive integer, got: 0."

      {bad_index, _log} = run(space_id, name, %{"start_index" => "2"})

      assert %ToolResult{is_error: true, content: content} = bad_index
      assert content == ~s(Invalid `start_index` argument: expected an integer, got: "2".)

      {both_modes, _log} = run(space_id, name, %{"search" => "report", "start_index" => -1})

      assert %ToolResult{is_error: true, content: content} = both_modes
      assert content == "Pass either `search` or `start_index`/`length`, not both."

      {bad_search, _log} = run(space_id, name, %{"search" => 5})

      assert %ToolResult{is_error: true, content: content} = bad_search
      assert content == "Invalid `search` argument: expected a non-empty string, got: 5."
    end

    test "resolves `name`: absent means the caller, a malformed one is refused", %{
      pid: pid,
      name: name,
      space_id: space_id
    } do
      seed_conversation(pid)

      # Absent, explicitly empty, and no arguments map at all all mean the
      # caller itself.
      for args <- [%{}, %{"name" => ""}, nil] do
        {result, _log} = run(space_id, name, args)

        assert %ToolResult{name: "agents-history", is_error: false, content: content} = result
        assert content =~ "[4] assistant:\nthe report is ready"
      end

      # Present but not a string is a typo, not a default: reading the caller's
      # own history in its place would answer a question the model did not ask.
      for {bad, rendered} <- [{123, "123"}, {%{}, "%{}"}, {["bob"], ~s(["bob"])}, {nil, "nil"}] do
        {result, log} = run(space_id, name, %{"name" => bad})

        assert %ToolResult{is_error: true, content: content} = result

        assert content ==
                 "Invalid `name` argument: expected a string, got: #{rendered}. " <>
                   "Omit it to target yourself."

        assert log =~ "BatchSizer produced is_error=true tool result"
      end

      # A string that names nothing in this space is still a lookup failure.
      {ghost, _log} = run(space_id, name, %{"name" => "ghost"})

      assert %ToolResult{name: "agents-history", is_error: true, content: content} = ghost
      assert content == "Agent ghost not found in this space."

      # `ctx.agent_name` is the caller's own name in production; a call that has
      # neither a name nor a caller is refused rather than reading something
      # arbitrary.
      {nameless, _log} = run(space_id, "", %{})

      assert %ToolResult{is_error: true, content: content} = nameless

      assert content ==
               "Missing required argument: name (and this call has no calling agent)."
    end

    test "an archived agent is refused, naming what to do about it", %{
      pid: pid,
      name: name,
      space_id: space_id
    } do
      seed_conversation(pid)
      assert :ok = Persistence.archive_agent(space_id, name)

      {result, _log} = run(space_id, name, %{"name" => name})

      assert %ToolResult{is_error: true, content: content} = result

      assert content ==
               "Agent #{name} is archived, so it is out of service; " <>
                 "restore it with agents-unarchive first."
    end

    test "a name that only exists in another space is refused", %{
      pid: pid,
      name: name,
      space_id: space_id
    } do
      seed_conversation(pid)

      # A second agent, in a second space: `start_agent/1` creates a fresh space
      # each time, so this one is not visible from the first space.
      {other_pid, other_name} = AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus"}})
      other_space_id = AgentTestHelpers.current_space_id()
      append(other_pid, text(:user, "a message only the other space can see"))

      assert other_space_id != space_id

      # From the first space the name is not found — the security boundary.
      {refused, log} = run(space_id, name, %{"name" => other_name})

      assert %ToolResult{is_error: true, content: content} = refused
      assert content == "Agent #{other_name} not found in this space."
      assert log =~ "BatchSizer produced is_error=true tool result"

      # The same name read from its own space works, and a default read uses the
      # caller's own name: the refusal is the space, not the name.
      {allowed, _log} = run(other_space_id, other_name, %{"name" => other_name})

      assert %ToolResult{is_error: false, content: content} = allowed
      assert content =~ "a message only the other space can see"

      {by_default, _log} = run(other_space_id, other_name, %{})

      assert %ToolResult{is_error: false, content: content} = by_default
      assert content =~ "a message only the other space can see"
    end
  end

  describe "a directly-inserted row" do
    test "its persisted history is still readable with no live process", %{
      space_id: space_id,
      name: caller
    } do
      bare = "bare-#{System.unique_integer([:positive])}"
      {:ok, %PersistedAgent{id: agent_id}} = insert_row(space_id, bare)
      :ok = insert_messages(space_id, bare, agent_id)

      # No process was started, and none is started by the read.
      assert {:error, :not_found} = Registry.lookup(space_id, bare)

      {result, _log} = run(space_id, caller, %{"name" => bare, "start_index" => -1})

      assert %ToolResult{name: "agents-history", is_error: false, content: content} = result
      assert content =~ "History of agent \"#{bare}\": 2 message(s), indices 0..1."
      assert content =~ "[1] assistant:\nno process, but persisted"
      assert {:error, :not_found} = Registry.lookup(space_id, bare)
    end

    test "a row with no messages reports that, rather than an empty range", %{
      space_id: space_id,
      name: caller
    } do
      bare = "empty-#{System.unique_integer([:positive])}"
      {:ok, %PersistedAgent{}} = insert_row(space_id, bare)

      {result, _log} = run(space_id, caller, %{"name" => bare})

      assert %ToolResult{is_error: true, content: content} = result
      assert content == "Agent #{bare} has no messages."
    end

    test "a gap in the sequence is reported, not silently truncated", %{
      space_id: space_id,
      name: caller
    } do
      bare = "gap-#{System.unique_integer([:positive])}"
      {:ok, %PersistedAgent{id: agent_id}} = insert_row(space_id, bare)

      # Index 1 is missing: the sequence is not contiguous, so the window
      # 0..2 cannot be served as one range.
      {:ok, _} = Persistence.insert_message(space_id, bare, indexed(:user, 0, "first"))
      {:ok, _} = Persistence.insert_message(space_id, bare, indexed(:user, 2, "third"))
      Persistence.update_next_message_index_by_id(agent_id, 3)

      {result, _log} = run(space_id, caller, %{"name" => bare, "start_index" => 0, "length" => 3})

      assert %ToolResult{is_error: true, content: content} = result

      assert content ==
               "Agent #{bare}'s message sequence has a gap: not every index in 0..2 " <>
                 "is present, so this range cannot be read as one window."
    end

    test "every part kind is rendered, and a compaction marker reads as a marker", %{
      space_id: space_id,
      name: caller
    } do
      bare = "parts-#{System.unique_integer([:positive])}"
      {:ok, %PersistedAgent{id: agent_id}} = insert_row(space_id, bare)

      {:ok, _} =
        Persistence.insert_message(
          space_id,
          bare,
          {:assistant,
           %Assistant{
             index: 0,
             parts: [
               %Part.Thinking{thinking: "weighing it up"},
               %Part.Text{text: "here is the answer"},
               %Part.Refusal{refusal: "not that part"}
             ]
           }}
        )

      {:ok, _} =
        Persistence.insert_message(
          space_id,
          bare,
          {:tool,
           %Tool{
             index: 1,
             parts: [
               %Part.ToolResult{
                 tool_call_id: "call_1",
                 name: "shell-cmd",
                 content: "boom",
                 is_error: true
               },
               %Part.Media{
                 tool_call_id: "call_1",
                 modality: :image,
                 media_type: "image/png",
                 data: Base.encode64(<<1, 2, 3>>),
                 bytes: 3
               }
             ]
           }}
        )

      assert {:ok, _marker} = Persistence.record_compaction(space_id, bare, 2, 2)
      Persistence.update_next_message_index_by_id(agent_id, 3)

      {result, _log} = run(space_id, caller, %{"name" => bare, "start_index" => 0, "length" => 3})

      assert %ToolResult{is_error: false, content: content} = result
      assert content =~ "[0] assistant:\n[thinking]\nweighing it up\nhere is the answer\n"
      assert content =~ "[refusal] not that part"
      assert content =~ "[1] tool:\n[tool_result shell-cmd (error)]\nboom"
      assert content =~ "[media image/png, 3 bytes]"
      assert content =~ "[2] compaction:\n[compaction marker: 2 message(s) archived]"
    end
  end

  describe "the compaction summary's archive pointer (issue #117)" do
    test "names a range this tool actually reads", %{
      pid: pid,
      name: name,
      space_id: space_id
    } do
      # The post-compaction summary message ends with a pointer at the archived
      # range, spelled the way this tool takes it. `Turn.Commit` builds the
      # pointer from the marker index, so its `length` is that index and its
      # window is `0..marker_index - 1`; this drives the read to prove the tool
      # accepts exactly that window (a window running past the count is an
      # error here, never a silent truncation).
      append(pid, text(:user, "before the compaction"))
      append(pid, text(:assistant, "answered"))

      # The marker lands at the runtime's next free index — the same number the
      # pointer's `length` is derived from. (No `update_next_message_index_by_id`
      # here: this test only reads, so the runtime's own index needs no
      # catch-up.)
      # allowlist: snapshot — the next free index, i.e. the marker's index
      next_index = :sys.get_state(pid, 1_000).chat_state.next_message_index

      assert {:ok, _marker} =
               Persistence.record_compaction(space_id, name, next_index, next_index)

      {result, _log} =
        run(space_id, name, %{"name" => name, "start_index" => 0, "length" => next_index})

      assert %ToolResult{is_error: false, content: content} = result
      assert content =~ "before the compaction"
      assert content =~ "answered"

      # The marker row sits at index 2 — one past the pointer's window, which is
      # why the pointer's `length` is the marker's index and not one more.
      refute content =~ "compaction marker"
    end
  end

  describe "a range read over the inline cap" do
    test "is substituted with a pointer to the full text", %{
      pid: pid,
      name: name,
      space_id: space_id
    } do
      append(pid, text(:user, String.duplicate("x", 40_000)))

      # A small window so the read cannot fit inline, and a real scratch dir so
      # the full text has somewhere to go.
      dir = scratch_dir()

      {result, _log} =
        run(space_id, name, %{"start_index" => -1}, %{
          context_limit: 12_000,
          mounts: Mounts.new(nil, dir)
        })

      assert %ToolResult{name: "agents-history", is_error: false, content: content} = result

      # The full text is in the scratch dir and the inline result says so,
      # rather than the read being silently cut off.
      assert content =~ "Output of agents-history"
      assert content =~ "saved to /tmp/"
      refute content =~ String.duplicate("x", 40_000)
    end
  end

  # A unique scratch directory, removed on exit — the same shape
  # `batch_sizer_overflow_test.exs` uses.
  defp scratch_dir do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "nest-tmp-history-#{unique}")
    dir = Path.join([root, "space-1", "agent-#{unique}"])

    File.mkdir_p!(dir)

    on_exit(fn ->
      if String.contains?(root, "nest-tmp-history"), do: File.rm_rf!(root)
    end)

    dir
  end

  # A row inserted directly: the reader must work for an agent this session has
  # never started, and `Agents.create_agent/3` would start one.
  defp insert_row(space_id, name) do
    Persistence.insert_agent(%{
      space_id: space_id,
      name: name,
      model: %{name: "qwen3.5-plus", provider: "model-studio"},
      vocation_id: AgentTestHelpers.vocation_id_for_test()
    })
  end

  defp insert_messages(space_id, name, agent_id) do
    {:ok, _} =
      Persistence.insert_message(space_id, name, indexed(:user, 0, "no process, but persisted"))

    {:ok, _} =
      Persistence.insert_message(
        space_id,
        name,
        indexed(:assistant, 1, "no process, but persisted")
      )

    Persistence.update_next_message_index_by_id(agent_id, 2)
  end
end
