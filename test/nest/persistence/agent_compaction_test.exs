defmodule Nest.Persistence.AgentCompactionTest do
  @moduledoc """
  End-to-end tests for `mix nest.compact_agent`'s orchestration:
  marker + system + summary writes, restore partitioning, orphan
  cleanup, dry-run, and the preflight refusal. The summarizer is
  injected, so no HTTP is involved.
  """

  use Nest.DataCase, async: true

  import Nest.PersistenceTestHelpers

  alias Nest.Agents.PersistedAgent
  alias Nest.LLM.Preflight
  alias Nest.Messages.Assistant
  alias Nest.Messages.Compaction
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Persistence.AgentCompaction
  alias Nest.Spaces

  @summary "the summary"

  test "applies a compaction and partitions the history on restore" do
    {space_id, name} =
      seed_agent(next: 4, messages: [system(0), user(1, "one"), assistant(2), user(3, "two")])

    assert {:ok, plan, @summary} =
             AgentCompaction.run(space_name(space_id) |> target(name),
               apply: true,
               llm_call: summary_call()
             )

    assert plan.marker_index == 4

    assert {:ok, %PersistedAgent{last_compaction_index: 4, next_message_index: 7}} =
             Persistence.fetch_agent(space_id, name)

    full = Persistence.load_full_messages(space_id, name)
    assert Enum.map(full, &index/1) == [0, 1, 2, 3, 4, 5, 6]
    assert {:compaction, %Compaction{archived_count: 4}} = Enum.at(full, 4)
    assert {:system, _} = Enum.at(full, 5)
    assert {:user, %User{parts: [%Part.Text{text: text}]}} = Enum.at(full, 6)
    assert text == "Summary of earlier conversation:\n\n" <> @summary

    active = Enum.filter(full, fn {_role, %{index: idx}} -> idx > 4 end)
    assert :ok = Preflight.validate(active)
  end

  test "dry run writes nothing and never calls the LLM" do
    {space_id, name} =
      seed_agent(next: 4, messages: [system(0), user(1, "one"), assistant(2), user(3, "two")])

    assert {:ok, plan, nil} =
             AgentCompaction.run(
               space_name(space_id) |> target(name),
               llm_call: fn _ -> flunk("dry run must not call the LLM") end
             )

    assert plan.marker_index == 4

    assert {:ok, %PersistedAgent{last_compaction_index: -1, next_message_index: 4}} =
             Persistence.fetch_agent(space_id, name)
  end

  test "deletes orphan rows left by a crashed compaction" do
    {space_id, name} =
      seed_agent(
        next: 6,
        messages: [system(0), user(1, "one"), assistant(2), user(4, "gap"), assistant(5)]
      )

    assert {:ok, plan, @summary} =
             AgentCompaction.run(space_name(space_id) |> target(name),
               apply: true,
               llm_call: summary_call()
             )

    assert plan.marker_index == 6

    assert {:ok, %PersistedAgent{last_compaction_index: 6, next_message_index: 9}} =
             Persistence.fetch_agent(space_id, name)

    full = Persistence.load_full_messages(space_id, name)
    assert Enum.map(full, &index/1) == [0, 1, 2, 6, 7, 8]
  end

  test "refuses an invalid sequence unless forced" do
    {space_id, name} =
      seed_agent(next: 3, messages: [system(0), user(1, "one"), assistant_tool(2, "call_1")])

    assert {:error, {:sequence_violations, message}} =
             AgentCompaction.run(space_name(space_id) |> target(name),
               apply: true,
               llm_call: summary_call()
             )

    assert message =~ "preflight"

    assert {:ok, _plan, @summary} =
             AgentCompaction.run(
               space_name(space_id) |> target(name),
               apply: true,
               force: true,
               llm_call: summary_call()
             )
  end

  test "formats dry-run and applied reports" do
    {space_id, name} = seed_agent(next: 3, messages: [system(0), user(1, "one"), assistant(2)])
    {:ok, plan, nil} = AgentCompaction.run({space_name(space_id), name})

    dry = AgentCompaction.format_report(plan, false)
    assert dry =~ "Dry run"
    assert dry =~ "dry run: no LLM calls made"

    applied = AgentCompaction.format_report(plan, true)
    assert applied =~ "Applied"
    assert applied =~ "restart the agent"
  end

  test "reports a missing space or agent" do
    assert {:error, {:space_not_found, "nope"}} = AgentCompaction.run({"nope", "x"})

    space_id = test_space_id()

    assert {:error, {:agent_not_found, "missing"}} =
             AgentCompaction.run({space_name(space_id), "missing"})
  end

  test "fails clearly when the summarizer provider is not configured" do
    {space_id, name} = seed_agent(next: 3, messages: [system(0), user(1, "one"), assistant(2)])

    assert {:error, {:provider_not_in_dotconfig, "test"}} =
             AgentCompaction.run({space_name(space_id), name}, apply: true)
  end

  test "accepts a provider/model override and focus on a dry run" do
    {space_id, name} = seed_agent(next: 3, messages: [system(0), user(1, "one"), assistant(2)])

    assert {:ok, plan, nil} =
             AgentCompaction.run(
               {space_name(space_id), name},
               model: "pegasus/whatever",
               focus: "keep the API decisions"
             )

    assert plan.focus == "keep the API decisions"
  end

  # ---- helpers ----

  defp seed_agent(opts) do
    space_id = test_space_id()
    name = unique_name("compact-root")

    {:ok, _} =
      Persistence.insert_agent(agent_attrs(name) |> Map.put(:next_message_index, opts[:next]))

    for message <- opts[:messages] do
      {:ok, _} = Persistence.insert_message(space_id, name, message)
    end

    {space_id, name}
  end

  defp space_name(space_id), do: Spaces.get_space(space_id).name
  defp target(space_name, agent_name), do: {space_name, agent_name}

  defp summary_call, do: fn _messages -> {:ok, @summary} end

  defp index({_role, %{index: idx}}), do: idx
  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp system(index) do
    {:system, %MsgSystem{index: index, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp user(index, text), do: {:user, %User{index: index, parts: [%Part.Text{text: text}]}}

  defp assistant(index) do
    {:assistant, %Assistant{index: index, parts: [%Part.Text{text: "ok"}], api_logs: []}}
  end

  defp assistant_tool(index, id) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [%Part.ToolUse{id: id, name: "shell-cmd", arguments: %{}}],
       api_logs: []
     }}
  end
end
