defmodule Nest.Agents.SendNoteHumanTest do
  @moduledoc """
  `Nest.Agents.send_note/6` with a **human** at one end.

  A note to a human is a row and a frame: there is no process to call, no inbox
  to drain and no transcript to append to. A human's note to an agent is the
  same row *plus* the message the model reads — one note, two readers — and it is
  what obliges the agent to answer, keyed on the address it was sent from.
  """

  use Nest.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.AddressTestHelpers
  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Notes
  alias Nest.Notes.UserNote

  test "a note to a human is a row and a frame, and `:delivered` is the honest answer" do
    # A human has no process that could be busy and no queue to wait in, so the
    # disposition is `:delivered` — the same answer an idle agent gives, for a
    # different reason.
    space = AddressTestHelpers.space_with_human("alice")
    Phoenix.PubSub.subscribe(Nest.PubSub, Broadcasts.space_topic(space.id))

    assert {:ok, :delivered} =
             Agents.send_note(space.id, "crazy-dolphin", "@alice", "the report is ready")

    assert [note] = Notes.list_for(space.id, {:user, "alice"})
    assert {note.from_kind, note.from_name} == {:agent, "crazy-dolphin"}
    assert {note.to_kind, note.to_name} == {:user, "alice"}
    assert note.content == "the report is ready"
    assert note.kind == :agent

    assert_receive {:user_note, %{id: id}}, 500
    assert id == note.id
  end

  test "an address that names no user is refused, and nothing is written" do
    space = AddressTestHelpers.space_with_human("alice")

    assert {:error, :not_found} = Agents.send_note(space.id, "crazy-dolphin", "@nobody", "hi")
    assert Notes.list_for(space.id, {:user, "nobody"}) == []
    refute_received {:user_note, _}
  end

  test "a bare name that names no agent is refused, and nothing is written" do
    # Agent-to-agent notes are the inbox's: `record_human_note/5` has nothing to
    # do for an agent sender, and the row count is the proof. A *human's* note to
    # a target that does not exist writes nothing either — the note is recorded
    # only once there is an agent to deliver it to.
    space = AddressTestHelpers.space_with_human("alice")

    assert {:error, :not_found} = Agents.send_note(space.id, "crazy-dolphin", "ghost", "hi")
    assert {:error, :not_found} = Agents.send_note(space.id, "@alice", "ghost", "hi")
    assert Notes.list_for(space.id, {:user, "alice"}) == []
  end

  test "a human's query to an agent is one row and one message, and it owes the address a reply" do
    # The conversation loop's first half. The query reaches the agent as a
    # user-role row naming the address it must answer, and the obligation is
    # keyed on that same string — which is why the reply machinery needs no
    # change for a human: a successful `agents-send` back to `@alice` casts
    # `{:reply_sent, "@alice"}`, the key this debt already has.
    #
    # The agent is scripted to answer neither request, so the test also pins the
    # *failure* path, which the design says is free: the runtime gives up on the
    # debt and the human is told, as a row.
    space = AddressTestHelpers.space_with_human("alice")
    {pid, name} = start_agent_in(space.id, "bob")

    assert {:ok, :delivered} =
             Agents.send_note(space.id, "@alice", name, "please summarize", :query)

    # The debt, at delivery, keyed on the address — the same string a
    # successful `agents-send` back to `@alice` clears.
    assert Agent.get_public_info(pid, 1_000).owed_replies == ["@alice"]

    await_idle(name)

    # The reminder the model is given names the debtor as a human, so it can
    # answer it: `user @alice`, not `agent "@alice"`.
    assert [_reminder_header, reminder] = human_row(pid, "have not answered")
    assert reminder =~ "user @alice"

    # The message the model read: a human's words, the address to answer, and
    # the marker that this one obliges a reply. The body is the note as written.
    assert ["[From user @alice, agents-send reply required | mode: act]", "please summarize"] =
             human_row(pid, "please summarize")

    # The human's own copy: the row the feed reads.
    assert %UserNote{kind: :query, answered_at: nil} = note(space.id, :query)

    # The give-up, delivered as a row: the runtime speaking, about the agent
    # that did not answer — which is what the feed groups by.
    assert %UserNote{
             from_kind: :runtime,
             from_name: ^name,
             to_kind: :user,
             to_name: "alice",
             kind: :runtime,
             content: content
           } = note(space.id, :runtime)

    assert content =~ name
    assert content =~ "did not reply"
  end

  test "a human's note back to an agent answers that agent's query" do
    # `answered_at` is the advisory banner's clear, set by the human's note back
    # to the agent that queried them — not by "any note from that agent", which
    # would clear it on a note that answered something else.
    #
    # The query here is addressed *to the human*, so it is a row and nothing
    # else: no turn starts and `bob` stays idle. The human's note back is the one
    # thing that starts a turn on him — one request, and no debt to answer, so it
    # rests — and the teardown refuses an agent still in flight, so that turn is
    # what the fence at the end is for. `answered_at` is already set when the
    # delivery returns (the row is written before it), so no assertion here
    # depends on the fence; only the test's *end* does.
    space = AddressTestHelpers.space_with_human("alice")
    {_pid, name} = start_agent_in(space.id, "bob")

    assert {:ok, :delivered} = Agents.send_note(space.id, name, "@alice", "which one?", :query)
    assert %UserNote{answered_at: nil} = query = note(space.id, :query)

    assert {:ok, :delivered} = Agents.send_note(space.id, "@alice", name, "the second one")
    assert %UserNote{answered_at: %DateTime{}} = answered(query)

    await_idle(name)
  end

  # A real agent in `space_id`, mocked so a delivered note's turn never touches
  # the network. `AgentTestHelpers.start_agent/1` always makes a fresh space of
  # its own, and these tests need the space the human is in.
  defp start_agent_in(space_id, name) do
    {:ok, ^name} =
      Agents.create_agent(
        space_id,
        %{name: "qwen3.5-plus", provider: "model-studio"},
        name: name,
        vocation_id: AgentTestHelpers.vocation_id_for_test()
      )

    {:ok, pid} = Supervisor.get_agent(space_id, name)

    AgentTestHelpers.put_space_id(space_id)
    AgentTestHelpers.ensure_cleanup(name)
    # `create_agent/3` starts the agent under the app supervisor, so it does not
    # inherit this test's `$callers`: its message appends need explicit access to
    # the test process's checked-out connection.
    Sandbox.allow(Nest.Repo, self(), pid)
    # The agent is started by hand, not by `start_agent/1`, so this call site
    # subscribes the test pid: `await_idle/1` fences on the agent's own idle
    # frame.
    AgentTestHelpers.subscribe_to_agent(space_id, name)

    :sys.replace_state(
      pid,
      fn st -> %{st | client_config: %{st.client_config | client: MockClient}} end,
      1_000
    )

    # Two responses: a query's turn, and the reminder that follows it. Neither
    # answers the human, so the settle after them gives the reply up.
    MockClient.start_link(pid)
    MockClient.put_pending(pid, {:text, "I will look into it"})
    MockClient.put_pending(pid, {:text, "Still looking"})

    {pid, name}
  end

  # The idle fence: the agent's own `chat_status` frame decides it, never a poll.
  # 1000 ms is the suite's cap on a test-side fence and is a failure detector,
  # not the synchronisation.
  defp await_idle(name) do
    assert_receive {:chat_status, %{name: ^name, status: "idle"}}, 1_000
  end

  # The header line and body of the user row holding `text`, split so the two can
  # be asserted separately: the body is the note as written (no header, no
  # marker), and the header is the framing `Nest.Messages.Header` adds.
  defp human_row(pid, text) do
    pid
    |> Agent.get_messages(1_000)
    |> Enum.flat_map(&user_row/1)
    |> Enum.find(fn [_header, body] -> String.contains?(body, text) end)
  end

  defp user_row({:user, %{parts: parts}}) do
    text =
      Enum.map_join(parts, "", fn
        %Part.Text{text: body} -> body || ""
        _other -> ""
      end)

    case String.split(text, "\n", parts: 2) do
      [header, body] -> [[header, body]]
      _no_header -> []
    end
  end

  defp user_row(_other), do: []

  # The note of `kind` in `space_id` addressed to or sent by alice. One per kind
  # in these tests, so the match is the assertion.
  defp note(space_id, kind) do
    Enum.find(Notes.list_for(space_id, {:user, "alice"}), &(&1.kind == kind))
  end

  defp answered(%UserNote{id: id}), do: Nest.Repo.get!(UserNote, id)
end
