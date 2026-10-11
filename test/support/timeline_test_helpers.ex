defmodule Nest.TimelineTestHelpers do
  @moduledoc """
  Timeline readers and fixtures for the emitters' tests.

  Recording is switched on globally and writes into a per-OS-process run file, so
  every reader here filters to the one agent the calling test tracked: a write
  from another test's process — a worker still finishing while this module runs —
  would otherwise land in the middle of an assertion. The digest is filtered the
  same way, through `Digest.render/2`'s own `:agent` option.

  Split out of `Nest.Agents.Agent.TimelineEmittersTest` for that file's line cap.
  """

  import ExUnit.Assertions

  import Nest.Agents.AgentTestHelpers, only: [programmer_vocation_id_for_test: 0]

  alias Nest.Agents.Agent.Machine
  alias Nest.Timeline
  alias Nest.Vocations

  @doc "The agent whose events the calling test reads."
  @spec track_agent(String.t()) :: String.t() | nil
  def track_agent(name), do: Process.put(:timeline_test_agent, name)

  @doc "Every event this test's agent recorded."
  @spec events() :: [map()]
  def events do
    {events, problems} = Timeline.load(Timeline.run_dir())
    assert problems == []
    Enum.filter(events, &(&1["agent"] == agent_name()))
  end

  @doc "Every recorded event of one `type`."
  @spec events(String.t()) :: [map()]
  def events(type), do: Enum.filter(events(), &(&1["type"] == type))

  @doc "Every `child` event with one `action`."
  @spec child_action(String.t()) :: [map()]
  def child_action(action), do: Enum.filter(events("child"), &(&1["action"] == action))

  @doc "Every `inbox` event with one `action`."
  @spec inbox_action(String.t()) :: [map()]
  def inbox_action(action), do: Enum.filter(events("inbox"), &(&1["action"] == action))

  @doc "Every `inbox` event recording one `disposition`."
  @spec inbox_disposition(String.t()) :: [map()]
  def inbox_disposition(value), do: Enum.filter(events("inbox"), &(&1["disposition"] == value))

  @doc "Every `usage` event for one child."
  @spec child_usage_events(String.t()) :: [map()]
  def child_usage_events(name), do: Enum.filter(events("usage"), &(&1["name"] == name))

  @doc "The usage one child reports."
  @spec child_usage() :: map()
  def child_usage do
    %{
      input_tokens: 30,
      output_tokens: 4,
      total_tokens: 34,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0
    }
  end

  @doc "The attributes `start_agent/1` needs for a turn that can run tools."
  @spec default_attrs() :: map()
  def default_attrs do
    %{model: %{name: "qwen3.5-plus"}, vocation_id: programmer_vocation_id_for_test()}
  end

  @doc "Force an agent's observable status (test-only; see `Machine.status_to_machine/2`)."
  @spec set_status(pid(), atom()) :: :ok
  def set_status(pid, status) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | live: %{state.live | machine: Machine.status_to_machine(state.live.machine, status)}
      }
    end)
  end

  @doc "Fill an agent's inbox with `count` queued peer entries."
  @spec fill_inbox(pid(), non_neg_integer()) :: :ok
  def fill_inbox(pid, count) do
    entry = %{
      from: "peer",
      content: "queued",
      timestamp: DateTime.utc_now(),
      kind: :agent,
      mode: nil
    }

    :sys.replace_state(pid, fn state ->
      %{state | live: %{state.live | inbox: List.duplicate(entry, count)}}
    end)
  end

  @doc "Create a distinct vocation for a spawned specialist; returns its slug."
  @spec specialist_vocation_slug() :: String.t()
  def specialist_vocation_slug do
    {:ok, %Vocations.Vocation{slug: slug}} =
      Vocations.upsert_vocation(%{
        name: "Timeline Specialist #{System.unique_integer([:positive])}",
        description: "A specialist",
        system_prompt: "You are a specialist.",
        tools: ["context"],
        modes: %{}
      })

    slug
  end

  defp agent_name, do: Process.get(:timeline_test_agent)
end
