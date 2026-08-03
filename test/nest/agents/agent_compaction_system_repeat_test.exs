defmodule Nest.Agents.AgentCompactionSystemRepeatTest do
  @moduledoc """
  Regression coverage for the post-compaction message sequence:

    1. The system message at position 0 of
       `state.chat_state.messages` is re-rendered at
       compaction time from the latest DB vocation and
       on-disk AGENTS.md (per AGENTS.md the system message
       MAY change at compaction — the prefix cache is
       invalidated by the compaction itself).
    2. `state.tools` is rebuilt from the fresh `vocation.tools`
       so vocation edits that add/remove tools take effect
       immediately.
    3. The invariant "every entry in `(history ++ messages)` has
       a row in the `messages` table at its `message_index`"
       is structural: every addition to either list flows
       through `MessageAppender.append_one/2` or
       `MessageAppender.append_history_one/2`, which always
       persist.

  Companion tests:
  - `agent_agents_md_test.exs` — AGENTS.md re-read pin
    (in-place fixture overwrite).
  - `agent_compaction_persistence_test.exs` — DB-side
    coverage for the unified `Persistence.insert_message/2`
    compaction clause.
  """
  use Nest.DataCase, async: true

  alias Nest.Agents.Agent.ClientAPI
  alias Nest.LLM.AnthropicClient
  alias Nest.LLM.MockClient
  alias Nest.LLM.OpenAIClient
  alias Nest.LLM.RunRequest
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.User
  alias Nest.Vocations

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  # conflicts with our private helper below
  import Nest.Agents.AgentTestHelpers, except: [text_from_parts: 1]

  # Build a test vocation. Returns the struct.
  defp create_vocation(attrs) do
    merged =
      Map.merge(
        %{
          name: "TestSystemRepeat-#{System.unique_integer([:positive])}",
          description: "Default for system-repeat tests",
          system_prompt: "Default system prompt #{System.unique_integer([:positive])}",
          tools: ["context"],
          modes: %{
            "chat" => %{
              "description" => "General conversation.",
              "caps" => %{
                "net" => false,
                "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
              }
            }
          }
        },
        attrs
      )

    {:ok, %Vocations.Vocation{} = vocation} = Vocations.create_vocation(merged)
    vocation
  end

  # Start an agent bound to `vocation`. The `start_agent/1`
  # helper generates its own unique agent name and inserts the
  # agent row. We pass `vocation` as the cached `vocation:`
  # field to avoid a redundant DB roundtrip. Also subscribes
  # the test process to the agent's PubSub topic so the
  # `:chat_message` broadcasts from `run_compaction/3`'s
  # pre-seed loop are observable via `assert_receive/1`.
  defp start_with_vocation(vocation, attrs \\ []) do
    # Canned response for the next chat turn spawned by
    # `spawn_next_chat_turn/2` after compaction.
    MockClient.set_response("done")

    full_attrs =
      Map.merge(
        %{
          model: %{name: "qwen3.5-plus", provider: "model-studio"},
          vocation_id: vocation.id,
          vocation: vocation
        },
        Map.new(attrs)
      )

    {pid, agent_id} = start_agent(full_attrs)
    {pid, agent_id}
  end

  # Pre-seed `chat_state.messages` via the canonical append
  # path (so DB rows mirror the in-memory state), bump
  # `next_message_index` past the highest so the marker lands
  # at a non-colliding slot, then trigger the compaction.
  defp run_compaction(pid, summary_text \\ "Test summary.", messages \\ default_messages()) do
    seed_pre_swap_messages(pid, messages)
    consume_pre_seed_broadcasts(messages)

    send(pid, {:compaction_done, summary_text, nil})
    _ = :sys.get_state(pid)
    state = :sys.get_state(pid)

    # Terminate the agent so the spawned chat turn's
    # `tool_calls_received` handler doesn't crash during
    # teardown (purely test-induced noise).
    ClientAPI.terminate(pid)

    state
  end

  # Seed `state.chat_state.messages` with the test fixtures,
  # bumping `next_message_index` past the highest pre-seeded
  # index so the compaction marker lands at a non-colliding
  # slot. Then append each via the canonical `append_message`
  # GenServer call so DB rows mirror the in-memory state.
  defp seed_pre_swap_messages(pid, messages) do
    highest_index =
      messages
      |> Enum.map(&message_index/1)
      |> Enum.max(fn -> -1 end)

    :sys.replace_state(pid, fn state ->
      bumped_index = max(state.chat_state.next_message_index, highest_index + 1)

      %{
        state
        | chat_state: %{state.chat_state | messages: messages, next_message_index: bumped_index}
      }
    end)

    for stamped <- messages do
      GenServer.call(pid, {:append_message, stamped}, 5_000)
    end
  end

  # Each pre-seeded `append_message` broadcasts one `:chat_message`
  # PubSub event. Consume them deterministically (one per pre-seeded
  # entry) so the post-compaction broadcasts are the only events
  # left in the test process's mailbox. AGENTS.md line 96 prohibits
  # `receive ... after` drains; consuming the exact expected count
  # is deterministic and gives a real failure if the broadcast
  # count drifts.
  defp consume_pre_seed_broadcasts(messages) do
    for _ <- messages do
      assert_receive {:chat_message, _}
    end
  end

  # Pull the `:index` out of a `{role, struct}` pre-seeded entry,
  # tolerating the rare case where the entry isn't a tagged tuple.
  defp message_index({_, %{index: idx}}), do: idx
  defp message_index(_), do: -1

  defp default_messages do
    [
      {:user, %User{index: 1, parts: [%Part.Text{text: "First"}], api_logs: []}},
      {:assistant, %Assistant{index: 2, parts: [%Part.Text{text: "Reply"}], api_logs: []}}
    ]
  end

  # Concatenate the text portions of a `parts` list, in order.
  # Used to extract the rendered system prompt string from a
  # `%System{parts: ...}` struct for substring assertions.
  defp text_from_parts(parts) do
    Enum.map_join(parts, "", fn
      %Part.Text{text: text} -> text
      _ -> ""
    end)
  end

  describe "system message re-render" do
    test "post-compaction state.chat_state.messages[0] is a fresh system message" do
      vocation = create_vocation(%{system_prompt: "Original-prompt-marker-XYZ"})
      {pid, _agent_id} = start_with_vocation(vocation)

      state = run_compaction(pid)

      assert match?({:system, _}, Enum.at(state.chat_state.messages, 0)),
             "expected fresh system message at messages[0]; " <>
               "got #{inspect(Enum.at(state.chat_state.messages, 0))}"

      [{:system, sys_struct} | _] = state.chat_state.messages

      sys_text = text_from_parts(sys_struct.parts)

      assert sys_text =~ "Original-prompt-marker-XYZ"
    end

    test "vocation.system_prompt changes between init and compaction are reflected in the regenerated system prompt" do
      fresh_marker = "FRESH-PROMPT-#{System.unique_integer([:positive])}"
      original_marker = "ORIGINAL-PROMPT-#{System.unique_integer([:positive])}"

      # Create vocation with the ORIGINAL prompt.
      vocation = create_vocation(%{system_prompt: original_marker})
      {pid, _agent_id} = start_with_vocation(vocation)

      # Verify the system prompt at init contains the original.
      initial_state = :sys.get_state(pid)

      [{:system, initial_sys} | _] = initial_state.chat_state.messages
      initial_text = text_from_parts(initial_sys.parts)

      assert initial_text =~ original_marker
      refute initial_text =~ fresh_marker

      # Mutate the vocation in the DB to use the FRESH prompt.
      {:ok, _updated_vocation} =
        Vocations.update_vocation(vocation, %{system_prompt: fresh_marker})

      # Trigger a compaction.
      state = run_compaction(pid)

      assert match?({:system, _}, Enum.at(state.chat_state.messages, 0))

      [{:system, post_sys} | _] = state.chat_state.messages
      post_text = text_from_parts(post_sys.parts)

      assert post_text =~ fresh_marker,
             "expected system prompt to reflect the fresh vocation; " <>
               "got #{post_text}"

      refute post_text =~ original_marker,
             "expected original system prompt to be absent"
    end

    test "AGENTS.md changes on disk between init and compaction are reflected" do
      vocation = create_vocation(%{})

      workspace_path =
        Path.join(
          System.tmp_dir!(),
          "nest-tmp-system-repeat-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workspace_path)
      on_exit(fn -> safe_rm_rf(workspace_path) end)

      agents_md_path = Path.join(workspace_path, "AGENTS.md")

      sentinel = "REFRESH-MARKER-#{System.unique_integer([:positive])}"
      File.write!(agents_md_path, "# Test AGENTS.md\nFROM_COMPACTION_TEST\n#{sentinel}\n")

      {pid, _agent_id} = start_with_vocation(vocation, workspace_path: workspace_path)

      # Verify the initial system prompt contains the sentinel.
      init_state = :sys.get_state(pid)
      [{:system, init_sys} | _] = init_state.chat_state.messages
      init_text = text_from_parts(init_sys.parts)

      assert init_text =~ sentinel

      # Write a NEW sentinel to the file and trigger compaction.
      new_sentinel = "POST-COMPACTION-#{System.unique_integer([:positive])}"
      File.write!(agents_md_path, "# Test AGENTS.md\nFROM_COMPACTION_TEST\n#{new_sentinel}\n")

      state = run_compaction(pid)

      [{:system, post_sys} | _] = state.chat_state.messages
      post_text = text_from_parts(post_sys.parts)

      assert post_text =~ new_sentinel
    end
  end

  defp safe_rm_rf(path) do
    if String.contains?(path, "nest-tmp") do
      File.rm_rf!(path)
    end
  end

  describe "index assignment via canonical path" do
    test "post-compaction messages are stamped sequentially starting at marker_index + 1" do
      vocation = create_vocation(%{system_prompt: "Indexed-prompt"})
      {pid, _agent_id} = start_with_vocation(vocation)

      state = run_compaction(pid)
      messages = state.chat_state.messages

      actual =
        messages
        |> Enum.map(fn {_, %{index: idx}} -> idx end)

      assert actual == [6, 7],
             "expected consecutive indices [6, 7] for [system, summary_user] " <>
               "(marker at 5 + 1, +2); got #{inspect(actual)}"
    end
  end

  describe "wire format after compaction" do
    test "Anthropic wire format includes the fresh system in the top-level 'system' field" do
      vocation = create_vocation(%{system_prompt: "Anthropic-test-prompt-XYZ"})

      # The Anthropic client requires an explicit `model` on the
      # RunRequest. Use the agent's configured model.
      {pid, _agent_id} = start_with_vocation(vocation)
      state = run_compaction(pid)

      request = %RunRequest{
        model: model_name(state.model),
        messages: state.chat_state.messages,
        tools: state.tools,
        tool_choice: :auto
      }

      payload = AnthropicClient.format_request_payload(request, [])

      assert is_binary(payload["system"]),
             "expected Anthropic payload['system'] to be a binary; got #{inspect(payload["system"])}"

      assert payload["system"] =~ "Anthropic-test-prompt-XYZ"
    end

    test "OpenAI wire format puts the fresh system at position 0 of the messages array" do
      vocation = create_vocation(%{system_prompt: "OpenAI-test-prompt-XYZ"})
      {pid, _agent_id} = start_with_vocation(vocation)
      state = run_compaction(pid)

      request = %RunRequest{
        model: model_name(state.model),
        messages: state.chat_state.messages,
        tools: state.tools,
        tool_choice: :auto
      }

      payload = OpenAIClient.format_request_payload(request, [])

      [first | _] = payload["messages"]
      assert first["role"] == "system"
      assert first["content"] =~ "OpenAI-test-prompt-XYZ"
    end
  end

  describe "vocation refresh" do
    test "state.vocation is updated to the fresh DB value post-compaction" do
      original_marker = "ORIGINAL-#{System.unique_integer([:positive])}"
      fresh_marker = "FRESH-#{System.unique_integer([:positive])}"

      vocation = create_vocation(%{system_prompt: original_marker})
      {pid, _agent_id} = start_with_vocation(vocation)

      state_before = :sys.get_state(pid)
      assert state_before.vocation.system_prompt =~ original_marker

      {:ok, _updated} =
        Vocations.update_vocation(vocation, %{system_prompt: fresh_marker})

      state_after = run_compaction(pid)
      assert state_after.vocation.system_prompt =~ fresh_marker
    end

    test "state.tools is rebuilt from the fresh vocation.tools post-compaction" do
      # Use a vocation with no read_file initially. Then add
      # read_file in the DB and trigger compaction. After
      # compaction the agent's `state.tools` should reflect
      # the new tool list.
      original_tools = ["context"]
      fresh_tools = ["context", "read_file"]

      vocation = create_vocation(%{tools: original_tools})
      {pid, _agent_id} = start_with_vocation(vocation)

      # Initial state has only the original tools.
      initial_state = :sys.get_state(pid)

      initial_tool_names =
        initial_state.tools
        |> Enum.map(fn t -> t.name end)
        |> MapSet.new()

      assert MapSet.equal?(initial_tool_names, MapSet.new(original_tools)),
             "pre-condition: agent's initial tools mismatch test fixture"

      # Mutate the vocation in the DB to add `read_file`.
      {:ok, _updated_vocation} =
        Vocations.update_vocation(vocation, %{tools: fresh_tools})

      # Trigger a compaction.
      state_after = run_compaction(pid)

      expected_tool_names = MapSet.new(fresh_tools)

      actual_tool_names =
        state_after.tools
        |> Enum.map(fn t -> t.name end)
        |> MapSet.new()

      assert MapSet.equal?(expected_tool_names, actual_tool_names),
             "expected tools to reflect fresh vocation.tools " <>
               "(#{inspect(fresh_tools)}); got #{inspect(actual_tool_names)}"
    end
  end

  describe "state-vs-DB invariant" do
    test "every post-swap entry added by the compaction has a row at its assigned index" do
      # Pins the invariant for the post-swap additions. The
      # canonical append path (`__append_messages__/2` for
      # new_messages and `MessageAppender.append_history_one/2`
      # for the marker) assigns each entry an index and persists
      # a row at that index. Pre-swap messages are persisted via
      # the canonical `:append_message` GenServer call (the
      # pre-seed loop in `run_compaction/3`).
      vocation = create_vocation(%{})
      {pid, agent_id} = start_with_vocation(vocation)

      state = run_compaction(pid)

      rows =
        Nest.Repo.all(
          from(m in Nest.Agents.PersistedMessage,
            join: a in Nest.Agents.PersistedAgent,
            on: m.agent_id == a.id,
            where: a.name == ^agent_id
          )
        )

      row_indices = MapSet.new(rows, & &1.message_index)

      # Post-swap entries in the active `messages` list must
      # all have rows. These are produced by
      # `MessageAppender.append_one/2`.
      for {_role, %{index: idx}} <- state.chat_state.messages do
        assert MapSet.member?(row_indices, idx),
               "post-swap entry at index #{idx} has no DB row"
      end

      # The marker is the LAST entry in `history`. The marker
      # index in memory must match a DB row at that index.
      assert {:compaction, %{index: marker_index}} = List.last(state.chat_state.history)

      assert MapSet.member?(row_indices, marker_index),
             "marker at index #{marker_index} has no DB row"
    end

    test "agents.last_compaction_index reflects the marker after compaction" do
      vocation = create_vocation(%{})
      {pid, agent_id} = start_with_vocation(vocation)

      state = run_compaction(pid)

      # Read the marker_index from the post-state (it's now
      # the index of the marker in history).
      assert {:compaction, %{index: marker_index}} = List.last(state.chat_state.history)

      agent_row =
        Nest.Repo.one!(from(a in Nest.Agents.PersistedAgent, where: a.name == ^agent_id))

      assert agent_row.last_compaction_index == marker_index,
             "expected last_compaction_index = #{marker_index} (the marker index); " <>
               "got #{agent_row.last_compaction_index}"
    end
  end

  # The `model` field on `state` arrives as string keys for
  # agents loaded from the JSONB column (via `Persistence.
  # build_attrs_for_start/1` → `state.model`) and as atom keys
  # when the caller passes atom-keyed attrs directly. Both
  # shapes are valid; tests use this accessor to assert
  # without coupling to the source shape.
  defp model_name(model), do: model[:name] || model["name"]
end
