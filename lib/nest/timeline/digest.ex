defmodule Nest.Timeline.Digest do
  @moduledoc """
  Human digest of a recorded timeline run (`mix nest.timeline`).

  `render/2` turns one `events.jsonl` into the text the task prints: a
  short summary of what happened, then a chronological timeline per
  space/agent that interleaves turns, LLM calls with their budget
  arithmetic, tool calls, inbox and debt events, status broadcasts,
  notifications and errors, compactions and the child graph.

  It is plain text with no ANSI escapes and no external dependencies, one
  line per event, ordered by the recorded `mono` clock (the file is
  append-only, so file order and clock order agree). Every field of the
  event is shown: the interesting ones in a readable shape, and anything
  else — including a type this module does not know — as `key=value`, so
  nothing is silently dropped. A nested map is flattened one level
  (`payload.usage.total=12`) rather than sliced as a single value, because
  the value bound would otherwise hide every field behind the first one.

  Unreadable lines are reported with their line number and skipped, and a
  run with no events still renders with a zero summary rather than
  crashing: a diagnostic tool that dies on corrupt input is useless.
  """

  alias Nest.Timeline

  @common ["ts", "mono", "space", "agent", "type"]
  @type_width 13
  @stamp_width 9
  @text_width 70

  # The fields each body clause already renders. Anything else in the
  # event is appended as `key=value`, so a field an emitter adds later is
  # visible in the digest the day it appears rather than the day someone
  # remembers to update this module. `duration_ms` is deliberately *not* here:
  # no emitter sends it, and the tool body no longer prints an `ms` segment for
  # a field that is absent — a line that carried one would show it through
  # `tail/2` as `duration_ms=120`.
  @turn_keys ~w(event from to iteration max_iterations)
  @llm_keys ~w(message_index iteration model projected_tokens limit reserve remaining outcome)
  @tool_keys ~w(name args_head args_bytes result_bytes is_error worker tool_call_id)
  @inbox_keys ~w(action from kind mode bytes count disposition)
  @debt_keys ~w(action peer reminders_used how)
  @status_keys ~w(payload)
  @notification_keys ~w(notification_type message)
  @error_keys ~w(message source)
  @compaction_keys ~w(trigger limit reserve used projected carried loop_count archived_to_index)
  @usage_keys ~w(input output cache_read cache_write total)
  @child_keys ~w(action name vocation depth model clone_context archive)

  @doc """
  Render the digest for the run in `dir`.

  Options:

    * `:space` — keep only events whose recorded `space` matches;
    * `:agent` — keep only events whose recorded `agent` matches.

  Both are compared as strings, so `--space 7` matches the integer `7`.
  """
  @spec render(String.t(), keyword()) :: String.t()
  def render(dir, opts \\ []) do
    {events, problems} = Timeline.load(dir)
    events = filter(events, opts)

    [
      header(dir, events, problems),
      summary(events),
      groups(events),
      problems_section(problems)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp header(dir, events, problems) do
    counts =
      case problems do
        [] -> "events: #{length(events)}"
        _ -> "events: #{length(events)}   unreadable lines: #{length(problems)}"
      end

    "Timeline digest — #{dir}\n#{counts}"
  end

  # ---- summary ----

  defp summary(events) do
    [
      "Summary",
      "  spaces: #{distinct(events, "space")}   agents: #{distinct(events, "agent")}",
      "  turns: #{count_type(events, "turn")}   llm requests: #{count_type(events, "llm")}   " <>
        "tokens: #{tokens(events)}",
      "  tool calls: #{count_type(events, "tool")} " <>
        "(#{plural(count_where(events, "tool", "is_error", true), "error")})",
      action_line("inbox", "inbox", events, ~w(enqueued queued delivered drained refused)),
      action_line(
        "debts",
        "debt",
        events,
        ["set", "cleared", "reminded", "gave_up", "give_up_refused"]
      ),
      "  compactions: #{count_type(events, "compaction")}",
      action_line(
        "children",
        "child",
        events,
        ~w(spawned completed failed terminated archived stopped)
      ),
      "  notifications: #{count_type(events, "notification")}   " <>
        "errors: #{count_type(events, "error")}"
    ]
    |> Enum.join("\n")
  end

  defp action_line(label, type, events, actions) do
    counts =
      Enum.map_join(actions, " · ", fn action ->
        "#{action} #{count_action(events, type, action)}"
      end)

    "  #{label}: #{counts}"
  end

  defp tokens(events) do
    sums =
      events
      |> Enum.filter(&(Map.get(&1, "type") == "usage"))
      |> Enum.reduce(
        %{"input" => 0, "output" => 0, "cache_read" => 0, "cache_write" => 0},
        &add_tokens/2
      )

    "in #{human(sums["input"])} out #{human(sums["output"])} " <>
      "cache r #{human(sums["cache_read"])} w #{human(sums["cache_write"])}"
  end

  defp add_tokens(event, sums) do
    Map.new(sums, fn {key, total} -> {key, total + integer(event[key])} end)
  end

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: 0

  defp human(n) when n < 1_000, do: Integer.to_string(n)
  defp human(n) when n < 1_000_000, do: "#{Float.round(n / 1000, 1)}k"
  defp human(n), do: "#{Float.round(n / 1_000_000, 1)}M"

  defp distinct(events, key), do: events |> Enum.map(&Map.get(&1, key)) |> Enum.uniq() |> length()

  defp count_type(events, type), do: Enum.count(events, &(Map.get(&1, "type") == type))

  defp count_action(events, type, action), do: count_where(events, type, "action", action)

  defp count_where(events, type, key, wanted) do
    Enum.count(events, &(Map.get(&1, "type") == type and Map.get(&1, key) == wanted))
  end

  # ---- timeline ----

  defp groups(events) do
    events
    |> Enum.group_by(&{Map.get(&1, "space"), Map.get(&1, "agent")})
    |> Enum.sort_by(fn {{space, agent}, _group} -> {value(space), value(agent)} end)
    |> Enum.map_join("\n\n", fn {{space, agent}, group} -> group_block(space, agent, group) end)
  end

  defp group_block(space, agent, events) do
    header = "space #{value(space)} · agent #{value(agent)}  (#{plural(length(events), "event")})"

    [header | Enum.map(events, &event_line/1)] |> Enum.join("\n")
  end

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"

  defp event_line(event) do
    "  #{stamp(event)}  #{String.pad_trailing(value(event["type"]), @type_width)}  #{body(event)}"
  end

  defp stamp(event) do
    ms = Map.get(event, "mono")

    text =
      if is_integer(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 2) <> "s", else: "?"

    String.pad_leading(text, @stamp_width)
  end

  # ---- per-type bodies ----

  defp body(%{"type" => "turn"} = e) do
    "#{phase(e["from"])} → #{phase(e["to"])} · #{value(e["event"])} · " <>
      "iter #{value(e["iteration"])}/#{value(e["max_iterations"])}" <> tail(e, @turn_keys)
  end

  defp body(%{"type" => "llm"} = e) do
    "##{value(e["message_index"])} iter #{value(e["iteration"])} · " <>
      "#{value(e["projected_tokens"])}/#{value(e["limit"])} projected " <>
      "(reserve #{value(e["reserve"])}, remaining #{value(e["remaining"])}) · " <>
      "#{value(e["model"])} · #{value(e["outcome"])}" <> tail(e, @llm_keys)
  end

  defp body(%{"type" => "tool"} = e) do
    # No `ms` segment: nothing measures a per-call duration (the worker does not
    # measure it and the machine has no start stamp), so the field is absent from
    # every real line. A line that did carry one falls through to `tail/2`'s
    # `duration_ms=120` rather than rendering a bare `-ms`.
    "#{value(e["name"])} args #{value(e["args_bytes"])}B result #{value(e["result_bytes"])}B " <>
      "· #{value(e["worker"])} · #{value(e["tool_call_id"])}" <>
      suffix(e["is_error"], "ERROR") <>
      suffix(e["args_head"], inline(e["args_head"])) <>
      tail(e, @tool_keys)
  end

  defp body(%{"type" => "inbox"} = e) do
    "#{value(e["action"])} from #{value(e["from"])} kind #{value(e["kind"])} " <>
      "#{value(e["bytes"])}B count #{value(e["count"])} · #{value(e["disposition"])}" <>
      suffix(e["mode"], "mode #{value(e["mode"])}") <> tail(e, @inbox_keys)
  end

  defp body(%{"type" => "debt"} = e) do
    "#{value(e["action"])} peer #{value(e["peer"])} " <>
      "reminders #{value(e["reminders_used"])} · #{value(e["how"])}" <> tail(e, @debt_keys)
  end

  defp body(%{"type" => "status"} = e) do
    "payload #{pairs(e["payload"])}" <> tail(e, @status_keys)
  end

  defp body(%{"type" => "notification"} = e) do
    "#{value(e["notification_type"])} · #{inline(e["message"])}" <> tail(e, @notification_keys)
  end

  defp body(%{"type" => "error"} = e) do
    "#{value(e["source"])} · #{inline(e["message"])}" <> tail(e, @error_keys)
  end

  defp body(%{"type" => "compaction"} = e) do
    "#{value(e["trigger"])} · limit #{value(e["limit"])} reserve #{value(e["reserve"])} " <>
      "used #{value(e["used"])} projected #{value(e["projected"])} · " <>
      "carried #{value(e["carried"])} · loops #{value(e["loop_count"])} · " <>
      "archived→#{value(e["archived_to_index"])}" <> tail(e, @compaction_keys)
  end

  defp body(%{"type" => "usage"} = e) do
    "in #{value(e["input"])} out #{value(e["output"])} " <>
      "cache r #{value(e["cache_read"])} w #{value(e["cache_write"])} · " <>
      "total #{value(e["total"])}" <> tail(e, @usage_keys)
  end

  defp body(%{"type" => "child"} = e) do
    "#{value(e["action"])} #{value(e["name"])} " <>
      "(#{value(e["vocation"])}, depth #{value(e["depth"])}, #{value(e["model"])})" <>
      suffix(e["clone_context"], "clone_context") <>
      suffix(e["archive"], "archive") <>
      tail(e, @child_keys)
  end

  # An unknown type is still shown in full: a digest that silently drops
  # what it does not recognise would be worse than useless.
  defp body(event), do: pairs(event)

  # ---- field rendering ----

  defp phase(%{"kind" => kind, "phase" => phase}), do: "#{value(kind)}/#{value(phase)}"
  defp phase(other), do: value(other)

  defp suffix(nil, _text), do: ""
  defp suffix(false, _text), do: ""
  defp suffix(_value, text), do: " · #{text}"

  defp tail(event, known) do
    case event |> Map.drop(@common ++ known) |> Enum.sort() do
      [] -> ""
      rest -> " · " <> (rest |> Enum.flat_map(&field_pairs/1) |> Enum.join(" "))
    end
  end

  defp pairs(map) when is_map(map) do
    case map |> Map.drop(@common) |> Enum.sort() |> Enum.flat_map(&field_pairs/1) do
      [] -> "-"
      pairs -> Enum.join(pairs, " ")
    end
  end

  defp pairs(other), do: inline(other)

  # One `key=value` per field — or one per entry when the value is a map, which
  # keeps the number the kit exists for visible: `inline/1` bounds a value at 70
  # chars, and a `status` payload is `%{"usage" => %{…}}`, so rendered as one
  # value it printed `payload=%{"cache_creation_input_tokens" => 0, …` and
  # stopped before `context_input_tokens`. Deeper nesting still falls back to a
  # single bounded value, so the one-line rule holds.
  defp field_pairs({key, value}) when is_map(value) and map_size(value) > 0 do
    Enum.map(Enum.sort(value), fn {sub, sub_value} -> "#{key}.#{sub}=#{inline(sub_value)}" end)
  end

  defp field_pairs({key, value}), do: ["#{key}=#{inline(value)}"]

  # One line per event, so a newline (or a tab) inside a recorded string
  # must not be able to break the layout. `value/1` always returns valid
  # UTF-8 (the decoder rejects anything else), so this cannot raise.
  defp inline(value) do
    value(value) |> String.replace(~r/\s+/, " ") |> String.slice(0, @text_width)
  end

  defp value(nil), do: "-"
  defp value(value) when is_binary(value), do: value
  defp value(value) when is_atom(value), do: Atom.to_string(value)
  defp value(value) when is_integer(value), do: Integer.to_string(value)
  defp value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  # `charlists: :as_lists` matters: a list of small integers (the message
  # indices a turn appended, say) is otherwise printed as a charlist.
  defp value(value) do
    inspect(value, limit: 10, printable_limit: @text_width, charlists: :as_lists)
  end

  # ---- filtering and problems ----

  defp filter(events, opts) do
    Enum.filter(events, fn event ->
      matches?(event, "space", opts[:space]) and matches?(event, "agent", opts[:agent])
    end)
  end

  defp matches?(_event, _key, nil), do: true
  defp matches?(event, key, wanted), do: value(Map.get(event, key)) == value(wanted)

  defp problems_section([]), do: ""

  defp problems_section(problems) do
    ["Unreadable lines" | Enum.map(problems, &problem_line/1)] |> Enum.join("\n")
  end

  defp problem_line({:file, reason}), do: "  file: #{reason}"
  defp problem_line({line, reason}), do: "  line #{line}: #{reason}"
end
