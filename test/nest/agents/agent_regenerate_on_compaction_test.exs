defmodule Nest.Agents.AgentRegenerateOnCompactionTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.Handlers.CompactionHandler.regenerate_for_compaction/2` —
  the shared helper that rebuilds the agent's system prompt
  (position 0 of `state.chat_state.messages`) from the latest
  DB state on every compaction. Re-fetches the Vocation row,
  re-renders the system prompt, re-builds the tool set,
  re-resolves the context limit, and persists all new
  messages. See `notes/update-system-msg-on-compaction.md`.

  This file is `async: false` so the agent's regeneration
  can use the test's sandboxed connection via the
  `Ecto.Adapters.SQL.Sandbox` ownership chain. Async tests
  lose the connection walking at the agent's supervisor
  boundary, which causes `DBConnection.OwnershipError`s
  during the regeneration's DB lookup.
  """
  use Nest.DataCase, async: false

  import ExUnit.CaptureLog
  import Mimic

  import Nest.Agents.AgentTestHelpers, only: [start_agent: 1]

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  # Create a Programmer vocation in the test DB and return its
  # id. The system-prompt regeneration tests need a vocation
  # with `shell_cmd` registered (so the tools actually run)
  # and a non-trivial system_prompt (so we can assert that
  # position 0 reflects the latest value).
  defp programmer_vocation_id do
    {:ok, vocation} =
      Vocations.create_vocation(%{
        name: "Test Programmer (#{Elixir.System.unique_integer([:positive])})",
        description: "A coding assistant that can read and write files in a workspace",
        system_prompt: "Test programmer prompt.",
        tools: ["read_file", "write_file", "edit", "shell_cmd", "context"],
        modes: %{
          "build" => %{
            "description" => "Test mode",
            "caps" => %{
              "net" => true,
              "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
            }
          }
        }
      })

    vocation.id
  end

  defp unique_tmp_dir do
    dir =
      Path.join(
        Elixir.System.tmp_dir!(),
        "agents-md-#{Elixir.System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  # Mimic `Nest.Tokens.Compactor.compact/3`'s output shape:
  # `[original_system, wrap_summary(llm_text), ...rest]` where
  # the original system sits at index 0 (with the full system
  # prompt as a single Part.Text) and the LLM-generated head
  # summary sits at index 1 (also wrapped as a single Part.Text
  # system message). The regenerator reads `summary_text` from
  # index 1, the original system at index 0 is preserved (its
  # text is allowed to look anything).
  defp compactor_messages_with(summary_text, after_text \\ "Next") do
    [
      {:system,
       %System{
         parts: [
           %Part.Text{text: "ORIGINAL_SYSTEM_PROMPT_PLACEHOLDER"}
         ]
       }},
      {:system, %System{parts: [%Part.Text{text: summary_text}]}},
      {:user, %User{parts: [%Part.Text{text: after_text}], api_logs: []}}
    ]
  end

  defp extract_position0_text(state) do
    [{:system, %System{parts: [%Part.Text{text: text}]}} | _] = state.chat_state.messages
    text
  end

  describe "system prompt regeneration" do
    test "position 0 reflects the latest vocation.system_prompt after compaction" do
      vocation_id = programmer_vocation_id()

      {pid, _agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})

      Vocations.update_vocation(
        Vocations.get_vocation!(vocation_id),
        %{system_prompt: "UPDATED via Vocations.update_vocation/2"}
      )

      send(
        pid,
        {:compaction_done, compactor_messages_with("[Summary of earlier conversation]:\n\n..."),
         {:task_compaction_continuation, self()}}
      )

      assert_receive {:task_compaction_done, _}, 200

      text0 = extract_position0_text(:sys.get_state(pid))
      assert text0 =~ "UPDATED via Vocations.update_vocation/2"

      Agent.terminate(pid)
    end

    test "position 0 reflects a mutated AGENTS.md on disk after compaction" do
      workspace = unique_tmp_dir()
      File.write!(Path.join(workspace, "AGENTS.md"), "FIRST version")
      on_exit(fn -> File.rm_rf!(workspace) end)

      vocation_id = programmer_vocation_id()

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation_id,
          workspace_path: workspace
        })

      # Mutate AGENTS.md on disk.
      File.write!(Path.join(workspace, "AGENTS.md"), "SECOND version")

      send(
        pid,
        {:compaction_done, compactor_messages_with("[Summary of earlier conversation]:\n\n..."),
         {:task_compaction_continuation, self()}}
      )

      assert_receive {:task_compaction_done, _}, 200

      text0 = extract_position0_text(:sys.get_state(pid))
      assert text0 =~ "SECOND version"
      refute text0 =~ "FIRST version"

      Agent.terminate(pid)
    end

    test "state.vocation is updated to the fresh struct after compaction" do
      vocation_id = programmer_vocation_id()

      {pid, _agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})

      Vocations.update_vocation(
        Vocations.get_vocation!(vocation_id),
        %{description: "UPDATED description for the fresh fetch"}
      )

      send(
        pid,
        {:compaction_done, compactor_messages_with("[Summary of earlier conversation]:\n\n..."),
         {:task_compaction_continuation, self()}}
      )

      assert_receive {:task_compaction_done, _}, 200

      state = :sys.get_state(pid)
      assert state.vocation.description == "UPDATED description for the fresh fetch"

      Agent.terminate(pid)
    end

    test "encoded summary-as-user is at position 1 when compactor's output starts with a system message" do
      vocation_id = programmer_vocation_id()

      {pid, _agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})

      send(
        pid,
        {:compaction_done,
         compactor_messages_with("[Summary of earlier conversation]:\n\nkey facts"),
         {:task_compaction_continuation, self()}}
      )

      assert_receive {:task_compaction_done, _}, 200

      state = :sys.get_state(pid)
      assert length(state.chat_state.messages) == 3

      [_, {:user, %User{parts: [%Part.Text{text: text1}]}}, _] = state.chat_state.messages
      assert text1 =~ "Summary of earlier conversation"
      assert text1 =~ "key facts"

      Agent.terminate(pid)
    end

    test "encoded summary-as-user uses the wrap_summary text (position 1) of the real compactor output, not the original system (position 0)" do
      # Real production shape: `Compactor.compact/3` returns
      # `[original_system, wrap_summary(llm_text)]`. Position 0 is
      # the original system (with the full prompt in a single
      # Part.Text), position 1 is the wrap_summary (a system
      # message whose single Part.Text is the LLM summary).
      # The regenerator's destructuring MUST bind summary_text
      # to position 1 so the encoded summary-as-user message
      # contains the LLM summary, not the original system prompt.
      vocation_id = programmer_vocation_id()

      {pid, _agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})

      # Mimic `Compactor.compact/3`'s contract:
      # `[original_system, wrap_summary, ...rest]` — position 0
      # is the original system (full prompt as a single
      # Part.Text), position 1 is the wrap_summary (LLM summary
      # text as a single Part.Text), position 2 is `rest` (a
      # placeholder user message that should land at the tail).
      real_compactor_output = [
        {:system,
         %System{
           parts: [%Part.Text{text: "ORIGINAL SYSTEM PROMPT — must not leak into summary"}]
         }},
        {:system, %System{parts: [%Part.Text{text: "REAL_LLM_SUMMARY_TEXT"}]}},
        {:user, %User{parts: [%Part.Text{text: "post-compaction remainder"}], api_logs: []}}
      ]

      send(
        pid,
        {:compaction_done, real_compactor_output, {:task_compaction_continuation, self()}}
      )

      assert_receive {:task_compaction_done, _}, 200

      state = :sys.get_state(pid)

      [_, {:user, %User{parts: [%Part.Text{text: text1}]}}, _] = state.chat_state.messages
      # The encoded summary-as-user MUST carry the LLM summary
      # text, NOT the original system prompt.
      assert text1 =~ "REAL_LLM_SUMMARY_TEXT"
      refute text1 =~ "ORIGINAL SYSTEM PROMPT"

      Agent.terminate(pid)
    end

    test "Vocations.get_vocation returns nil: graceful fallback (cached state, warning logged)" do
      # The DB-missing case is "expected to come back quickly"
      # (per the design in notes/update-system-msg-on-compaction.md).
      # We simulate it by deleting the vocation row mid-test;
      # the agent's regenerate_for_compaction/2 calls
      # Vocations.get_vocation/1 which returns nil, and the
      # handler falls back to the cached state.
      vocation_id = programmer_vocation_id()

      {pid, _agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})

      # Delete the vocation row to simulate a transient DB blip.
      # Bypass the agents_using_vocation? check by deleting
      # directly via Repo.
      vocation = Vocations.get_vocation!(vocation_id)
      Nest.Repo.delete!(vocation)

      log =
        capture_log(fn ->
          send(
            pid,
            {:compaction_done,
             compactor_messages_with("[Summary of earlier conversation]:\n\n..."),
             {:task_compaction_continuation, self()}}
          )

          assert_receive {:task_compaction_done, _}, 200
        end)

      # The fallback path is observable: a warning is logged
      # and the cached vocation stays in state.
      assert log =~ "Vocation #{vocation_id} not found during compaction regeneration"
      assert log =~ "using cached state"

      state = :sys.get_state(pid)
      # The compactor's output is used as-is; the cached
      # vocation stays. The fixture mimics the compactor's
      # `[original_system, wrap_summary, ...rest]` shape, so
      # all three input messages survive unchanged.
      assert length(state.chat_state.messages) == 3
      assert {:system, %System{}} = hd(state.chat_state.messages)
      assert state.vocation.id == vocation_id

      Agent.terminate(pid)
    end
  end
end
