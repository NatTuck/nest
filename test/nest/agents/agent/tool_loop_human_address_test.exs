defmodule Nest.Agents.Agent.ToolLoopHumanAddressTest do
  @moduledoc """
  The sub-agent tools, with a human as an addressee: `agents-list` names the
  space's humans, `agents-send`/`agents-query` refuse a bad address in words
  that name both possibilities, and a successful send to an address clears the
  debt keyed on it.

  Dispatch-level (`ToolLoop.execute/3`), like `ToolLoopSendAgentTest`: the
  delivery itself is stubbed, because what is under test is what the tool tells
  the model, not what the delivery does (`SendNoteHumanTest` owns that).
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.AddressTestHelpers
  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Persistence

  setup :verify_on_exit!

  describe "agents-list" do
    test "names the space's human, with the sigil that makes the address" do
      # `agents-list` is how an agent discovers the human: the system prompt is
      # fixed and would go stale the moment someone joins the space.
      space = AddressTestHelpers.space_with_human("alice")

      assert run(ctx(space.id), "agents-list", %{}).content ==
               "No agents in this space.\n" <>
                 "Humans in this space (a human is addressed with the @ sigil; " <>
                 "a bare name is an agent): @alice"

      # ...and it is appended to a non-empty listing too, not only to the
      # "no agents" case above. (The listing itself is `SubAgentToolsTest`'s:
      # it asserts the names and vocation slugs.)
      insert_agent(space.id, "bob")

      assert run(ctx(space.id), "agents-list", %{}).content =~ "@alice"
    end

    test "says nothing about humans in a space that has none" do
      # A space with no owner has no human to name; the listing is exactly what
      # it was. (Most test spaces are this shape, which is why the older
      # assertions on this tool still pass.)
      {:ok, space_id} = AgentTestHelpers.create_test_space()

      assert run(ctx(space_id), "agents-list", %{}).content == "No agents in this space."
    end
  end

  describe "a target that resolves to nobody" do
    test "a bare name points at the human of that name, and only when one exists" do
      # The sigil is the only thing that tells a human from an agent, so the
      # refusal has to name both possibilities — and a suggestion that named
      # nobody would be a second wrong answer.
      space = AddressTestHelpers.space_with_human("nat")
      stub_send({:error, :not_found})

      assert content(
               run_errors(ctx(space.id), "agents-send", %{"name" => "nat", "message" => "hi"})
             ) ==
               "Agent nat not found in this space. Did you mean the human @nat?"

      # A name no user has: the hint would name nobody, so there is none.
      assert content(
               run_errors(ctx(space.id), "agents-send", %{
                 "name" => "ghostname",
                 "message" => "hi"
               })
             ) ==
               "Agent ghostname not found in this space."
    end

    test "an address points at the agent of that name, when one exists" do
      # The other half — no hint when no agent row has that name — is
      # `WaitForHumanTest`'s through `agents-wait`: the same `target_error/2`
      # branch, so this test only needs the positive case.
      space = AddressTestHelpers.space_with_human("alice")
      stub_send({:error, :not_found})

      insert_agent(space.id, "ghost")

      assert content(
               run_errors(ctx(space.id), "agents-query", %{"name" => "@ghost", "prompt" => "hi"})
             ) ==
               "No human @ghost. Did you mean the agent ghost?"
    end

    test "a bare `@` says what an address is" do
      space = AddressTestHelpers.space_with_human("alice")
      stub_send({:error, :not_found})

      assert content(
               run_errors(ctx(space.id), "agents-send", %{"name" => "@", "message" => "hi"})
             ) ==
               "An address is `@` followed by a username; `@` alone names nobody."
    end
  end

  describe "a human target" do
    test "a query to a human says what it owes, and a send back clears the address-keyed debt" do
      # A human has no turn to be in, so the peer-shaped confirmation ("it stays
      # in its turn until it answers") would be a lie.
      space = AddressTestHelpers.space_with_human("alice")
      stub_send({:ok, :delivered})

      content =
        run(ctx(space.id), "agents-query", %{"name" => "@alice", "prompt" => "hi"}).content

      assert content =~ "Query delivered to @alice"
      assert content =~ "A human owes no reply"

      # The obligation a human's query sets is keyed on the address string, and
      # this cast is the clear: same key, no new machinery. `SendNoteHumanTest`
      # pins the key the debt is set with.
      run(ctx(space.id), "agents-send", %{"name" => "@alice", "message" => "hi"})

      assert_received {:"$gen_cast", {:reply_sent, "@alice"}}
    end

    test "set_mode is refused: a human has no mode" do
      # The monotone rule's refusal ("not one of your descendants") would be a
      # true sentence about the wrong thing: `set_mode` moves an agent's mode,
      # and a human has none to move.
      space = AddressTestHelpers.space_with_human("alice")

      content =
        content(
          run_errors(ctx(space.id), "agents-send", %{
            "name" => "@alice",
            "message" => "hi",
            "set_mode" => "act"
          })
        )

      assert content =~ "a human has no mode"
      refute_received {:"$gen_cast", {:reply_sent, _}}
    end
  end

  # `agent_pid` is this test process, so the debt-clear the worker sends to its
  # own agent lands in the test's mailbox.
  defp ctx(space_id) do
    %{
      space_id: space_id,
      agent_name: "sender",
      agent_pid: self(),
      context_limit: 100_000,
      messages: [],
      tools: [],
      caps: %{},
      mode: "act"
    }
  end

  defp run(ctx, name, args) do
    [%ToolResult{} = result] = ToolLoop.execute(ctx, nil, [call(name, args)])
    result
  end

  # A dispatch that expects `is_error` results: BatchSizer logs a line for each,
  # so the capture asserts on it. A capture nobody asserts on could only hide
  # prints, which is why the assertion is the point of it.
  defp run_errors(ctx, name, args) do
    {[%ToolResult{} = result], log} =
      with_log(fn -> ToolLoop.execute(ctx, nil, [call(name, args)]) end)

    assert log =~ "BatchSizer produced is_error=true tool result"
    result
  end

  defp call(name, args), do: %ToolCall{id: "call-1", name: name, arguments: args}

  defp content(%ToolResult{content: content}), do: content

  defp stub_send(reply) do
    Mimic.stub(Nest.Agents, :send_note, fn _space_id, _from, _name, _msg, _kind, _mode ->
      reply
    end)
  end

  # A persisted-only agent row: the listing merges persisted rows, and a
  # refusal's "did you mean" hint reads the row rather than loading the agent.
  defp insert_agent(space_id, name) do
    {:ok, _row} =
      Persistence.insert_agent(%{
        space_id: space_id,
        name: name,
        model: %{name: "test-model", provider: "test"},
        vocation_id: AgentTestHelpers.vocation_id_for_test()
      })
  end
end
