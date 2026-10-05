defmodule Nest.Agents.Agent.GuardTest do
  @moduledoc """
  Anti-drift guards for the Plan B architecture.

  These assert structural properties that unit tests cannot: `step/2` is the
  only transition authority and has a production caller, every declared
  action has an executor clause, effects only happen through the executor,
  and no module outside `Machine` writes `phase:`.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Machine

  @executor "lib/nest/agents/agent/turn/executor.ex"
  @turn "lib/nest/agents/agent/turn.ex"
  @handlers "lib/nest/agents/agent/handlers.ex"

  # Turn-driving modules whose effects must route through the executor.
  @turn_drivers Path.wildcard("lib/nest/agents/agent/turn.ex") ++
                  Path.wildcard("lib/nest/agents/agent/machine.ex") ++
                  Path.wildcard("lib/nest/agents/agent/machine/*.ex") ++
                  Path.wildcard("lib/nest/agents/agent/chat_pipeline.ex") ++
                  Path.wildcard("lib/nest/agents/agent/handlers.ex") ++
                  Path.wildcard("lib/nest/agents/agent/handlers/*.ex") ++
                  Path.wildcard("lib/nest/agents/agent/compaction/*.ex") ++
                  Path.wildcard("lib/nest/agents/agent/init/*.ex") ++
                  Path.wildcard("lib/nest/agents/agent/inbox.ex")

  # Modules allowed to touch the sequence / spawn / timers directly.
  @effect_allowed MapSet.new([
                    "lib/nest/agents/agent/turn/executor.ex",
                    "lib/nest/agents/agent/message_appender.ex",
                    "lib/nest/agents/agent/callbacks.ex",
                    "lib/nest/agents/agent/inbox.ex"
                  ])

  test "every declared action has an executor clause" do
    source = File.read!(@executor)

    missing =
      for action <- Machine.actions(),
          not Regex.match?(~r/execute\(\{:#{action}\b/, source) and
            not Regex.match?(~r/execute\(:#{action}\b/, source),
          do: action

    assert missing == [], "actions with no executor clause: #{inspect(missing)}"
  end

  test "every declared event is handled by step/2" do
    for tag <- Machine.events() do
      event = sample_event(tag)
      refute Machine.step(Machine.new(work: %Machine.Work{ctx: ctx()}), event) == :quarantine
    end
  end

  test "step/2 has a production caller (the settle loop)" do
    assert File.read!(@turn) =~ "Machine.step("
  end

  test "no lib source calls a Machine.to_ transition" do
    offenders =
      for path <-
            Path.wildcard("lib/nest/agents/agent.ex") ++
              Path.wildcard("lib/nest/agents/agent/**/*.ex"),
          File.read!(path) =~ ~r/Machine\.to_/,
          do: path

    assert offenders == []
  end

  test "effects only happen through the executor and message appender" do
    forbidden =
      ~r/(MessageAppender\.[a-z_]+\(|Task\.Supervisor\.|Process\.send_after\(|GenServer\.cast\()/

    offenders =
      for path <- @turn_drivers,
          path not in @effect_allowed,
          Regex.match?(forbidden, File.read!(path)),
          do: path

    assert offenders == [], "effect call(s) outside the executor: #{inspect(offenders)}"
  end

  test "only the Machine namespace writes phase:" do
    forbidden = ~r/\|\s*phase:\s*:|phase:\s*:[a-z_]+,?\s*\n/

    offenders =
      for path <-
            Path.wildcard("lib/nest/agents/agent.ex") ++
              Path.wildcard("lib/nest/agents/agent/**/*.ex"),
          not String.starts_with?(path, "lib/nest/agents/agent/machine"),
          File.read!(path) =~ forbidden,
          do: path

    assert offenders == [], "imperative phase write(s) outside Machine: #{inspect(offenders)}"
  end

  test "every Handlers.route_for tag maps to a declared event or lifecycle tag" do
    lifecycle =
      MapSet.new([
        :delta_received,
        :thinking_signature_received,
        :llm_usage,
        :api_log_sequences_updated,
        :llm_error,
        :http_response,
        :http_error,
        :worker_crashed,
        :DOWN,
        :EXIT
      ])

    tags = route_tags()

    assert :iterate in tags and :http_error in tags

    for tag <- tags do
      assert tag in Machine.events() or MapSet.member?(lifecycle, tag)
    end
  end

  defp route_tags do
    source = File.read!(@handlers)

    Regex.scan(~r/defp route_for\((.+?)\), do:/, source, capture: :all_but_first)
    |> Enum.map(fn [pattern] -> pattern |> Code.string_to_quoted!() |> event_tag_of() end)
    |> Enum.reject(&is_nil/1)
  end

  defp event_tag_of({:{}, _, [tag | _]}) when is_atom(tag), do: tag
  defp event_tag_of(tag) when is_atom(tag), do: tag
  defp event_tag_of(_), do: nil

  defp ctx do
    %{
      agent_pid: self(),
      agent_name: "a",
      space_id: 1,
      client_config: %Nest.LLM.ClientConfig{client: Nest.LLM.MockClient, model: "m"},
      tools: [],
      tool_choice: :auto,
      caps: %{},
      context_limit: 100_000,
      context_limit_source: :default,
      messages: [],
      tmp_path: nil,
      workspace_path: nil,
      mode: "chat",
      next_message_index: 0,
      crossed_thresholds: %MapSet{},
      context_projection: nil,
      api_log_sequences: %{},
      vocation: nil,
      depth: 0
    }
  end

  defp user do
    {:user,
     %Nest.Messages.User{index: nil, parts: [%Nest.Messages.Part.Text{text: "hi"}], api_logs: []}}
  end

  defp sample_event(:chat_request), do: {:chat_request, {:user_message, elem(user(), 1)}}
  defp sample_event(:iterate), do: :iterate
  defp sample_event(:finalize_idle), do: :finalize_idle
  defp sample_event(:inbox_drain), do: {:inbox_drain, [], "queued"}
  defp sample_event(:http_ok), do: {:http_ok, make_ref(), %Nest.LLM.RunResponse{}}
  defp sample_event(:http_error), do: {:http_error, make_ref(), :boom}
  defp sample_event(:worker_crashed), do: {:worker_crashed, make_ref(), %RuntimeError{}, []}
  defp sample_event(:worker_down), do: {:worker_down, self(), :killed}
  defp sample_event(:worker_started), do: {:worker_started, make_ref(), self(), :http}
  defp sample_event(:llm_error), do: {:llm_error, make_ref(), "boom"}
  defp sample_event(:append_result), do: {:append_result, :stale, nil}
  defp sample_event(:preflight_result), do: {:preflight_result, :fits}
  defp sample_event(:stop), do: {:stop, self()}
  defp sample_event(:stop_timer), do: :stop_timer
  defp sample_event(:timer_armed), do: {:timer_armed, :stop_timer, make_ref()}
  defp sample_event(:compaction_request), do: {:compaction_request, {:tool_call, %{}, 1, 10}}
  defp sample_event(:compaction_ok), do: {:compaction_ok, %{summary: "s"}}
  defp sample_event(:commit_done), do: {:commit_done}
  defp sample_event(:commit_error), do: {:commit_error, :boom}
  defp sample_event(:compaction_error), do: {:compaction_error, :boom, nil}
  defp sample_event(:retry_compaction), do: :retry_compaction
  defp sample_event(:loop_ack), do: :loop_ack
  defp sample_event(:blocked), do: {:blocked, :needs_repair, nil}
  defp sample_event(:unblocked), do: {:unblocked}
  defp sample_event(:chat_idle), do: :chat_idle
  defp sample_event(:workspace_notice), do: :workspace_notice
  defp sample_event(:tool_results), do: {:tool_results, make_ref(), []}
  defp sample_event(:child_spawned), do: {:child_spawned, "kid", make_ref(), false}
  defp sample_event(:child_completed), do: {:child_completed, "kid", "resp", %{}}
  defp sample_event(:child_failed), do: {:child_failed, "kid", :crashed}
  defp sample_event(:child_terminated), do: {:child_terminated, "kid", :killed}
  defp sample_event(:abandon_child), do: {:abandon_child, "kid"}
end
