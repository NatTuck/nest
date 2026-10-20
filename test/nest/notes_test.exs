defmodule Nest.NotesTest do
  @moduledoc """
  The `user_notes` context (`Nest.Notes`): what a note with a human at one end
  is, the two reads the feed is built on, and the answer that clears a query.

  The send path that writes these rows is `Nest.Agents.send_note/6`, and it is
  covered by `Nest.Agents.SendNoteHumanTest` — including the refusal of an
  address that names no user. This file is the table and its rules.
  """

  use Nest.DataCase, async: true

  alias Nest.AddressTestHelpers
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Notes
  alias Nest.Notes.UserNote

  describe "deliver/5" do
    test "a note to a human is one row with both ends named, and it is broadcast" do
      space = AddressTestHelpers.space_with_human("alice")
      Phoenix.PubSub.subscribe(Nest.PubSub, Broadcasts.space_topic(space.id))

      assert {:ok, %UserNote{} = note} =
               Notes.deliver(space.id, {:agent, "crazy-dolphin"}, {:user, "alice"}, "hi", :agent)

      # Both ends, spelled out: the sigil never enters a column, so `to_kind` is
      # what says the name beside it is a human's.
      assert note.space_id == space.id
      assert note.from_kind == :agent
      assert note.from_name == "crazy-dolphin"
      assert note.to_kind == :user
      assert note.to_name == "alice"
      assert note.content == "hi"
      assert note.kind == :agent

      # The frame is the row the feed will read, on the space's topic.
      assert_receive {:user_note, %UserNote{id: id, content: "hi"}}, 500
      assert id == note.id
    end

    test "a human-to-human note is one row both feeds read" do
      # The point of an *addressed* table: no owning `user_id`, so two humans are
      # two ends of one row rather than two mirrors of it. Neither needs to be in
      # the space — an address names a user (`Nest.Notes`' moduledoc).
      space = AddressTestHelpers.space_with_human("alice")
      bob = AddressTestHelpers.human("bob")

      assert {:ok, note} =
               Notes.deliver(space.id, {:user, "alice"}, {:user, bob.username}, "hi bob", :agent)

      assert [^note] = Notes.list_for(space.id, {:user, "alice"})
      assert [^note] = Notes.list_for(space.id, {:user, "bob"})
    end

    test "an agent-to-agent note is refused by the table, not quietly stored" do
      # The table only holds rows with a human at one end: agent-to-agent notes
      # are the inbox's, and a copy here would be a second spelling of what an
      # agent was told.
      space = AddressTestHelpers.space_with_human("alice")

      assert {:error, %Ecto.Changeset{} = changeset} =
               Notes.deliver(space.id, {:agent, "a"}, {:agent, "b"}, "hi", :agent)

      assert "a note must have a human at one end" in errors_on(changeset).to_kind
    end

    test "a note in a space that does not exist is a changeset error, not a raise" do
      AddressTestHelpers.human("alice")

      assert {:error, %Ecto.Changeset{} = changeset} =
               Notes.deliver(-1, {:agent, "a"}, {:user, "alice"}, "hi", :agent)

      assert "does not exist" in errors_on(changeset).space_id
    end
  end

  describe "mark_answered/3" do
    test "marks that agent's outstanding queries to that human, and nothing else" do
      space = AddressTestHelpers.space_with_human("alice")
      AddressTestHelpers.human("bob")

      {:ok, query} = Notes.deliver(space.id, {:agent, "a"}, {:user, "alice"}, "q", :query)
      {:ok, plain} = Notes.deliver(space.id, {:agent, "a"}, {:user, "alice"}, "fyi", :agent)
      {:ok, other_agent} = Notes.deliver(space.id, {:agent, "b"}, {:user, "alice"}, "q", :query)
      {:ok, other_human} = Notes.deliver(space.id, {:agent, "a"}, {:user, "bob"}, "q", :query)

      assert :ok = Notes.mark_answered(space.id, "alice", "a")

      assert %UserNote{answered_at: %DateTime{}} = reload(query)
      # A plain note was not waiting for an answer.
      assert %UserNote{answered_at: nil} = reload(plain)
      # A note back to `a` answers only `a`'s queries...
      assert %UserNote{answered_at: nil} = reload(other_agent)
      # ...and only alice's, not the ones it sent somebody else.
      assert %UserNote{answered_at: nil} = reload(other_human)
    end

    test "leaves an already-answered query's timestamp alone" do
      # The banner reads `answered_at` null; a second answer must not move the
      # timestamp of the first, or "when was this answered" becomes "when was it
      # last answered" for no reader's benefit.
      space = AddressTestHelpers.space_with_human("alice")
      {:ok, query} = Notes.deliver(space.id, {:agent, "a"}, {:user, "alice"}, "q", :query)

      first = %{DateTime.utc_now() | microsecond: {111_111, 6}}
      Repo.update_all(from(n in UserNote, where: n.id == ^query.id), set: [answered_at: first])

      assert :ok = Notes.mark_answered(space.id, "alice", "a")
      assert %UserNote{answered_at: ^first} = reload(query)
    end
  end

  describe "list_humans_for_space/1" do
    test "is the space's owner, and empty when the space has none" do
      # A space has one owner and no membership table, so this is the human an
      # agent in the space is told about. It is a list because the *shape* is
      # "the space's humans"; when a space can hold several, this is the function
      # that grows.
      space = AddressTestHelpers.space_with_human("alice")
      {:ok, ownerless} = AgentTestHelpers.create_test_space()

      assert Notes.list_humans_for_space(space.id) == ["alice"]
      assert Notes.list_humans_for_space(ownerless) == []
    end
  end

  defp reload(%UserNote{id: id}), do: Repo.get!(UserNote, id)
end
