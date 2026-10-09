defmodule Nest.Timeline do
  @moduledoc """
  W5's observation kit: a JSONL timeline of what a running space actually did.

  This module is the **writer** (and the file layer the digest reads
  through). `Nest.Timeline.Digest` renders it, `mix nest.timeline` drives
  that, and the runtime calls `record/4` from wherever an event happens.

  ## Enabling

  Recording is **off by default**. Turn it on for a real usage session by
  starting the server with `NEST_TIMELINE=1` (or `true`/`yes`), or by
  setting `config :nest, timeline_enabled: true`. Application config wins
  when it is set at all, so a test can pin the switch deterministically;
  the environment variable is the fallback. Both are read at call time, so
  either can be set before `mix phx.server` starts.

  ## Where the events go

  `record/4` appends **one JSON line per event** to
  `<base_dir>/<run_id>/events.jsonl`. The base dir is `notes/usage-runs/`
  (override with `config :nest, timeline_dir: ...`; the tests point it at
  a tmp dir) and `<run_id>` is a timestamp captured **once per OS
  process**, so every event of one session lands in one directory and a
  restart starts a new one. `mix nest.timeline` digests the newest run.

  ## Redaction policy

  The timeline is a *diagnostic* record, not a transcript, and it is
  written into a gitignored directory that may be shared. So:

    * content-shaped values are recorded as **a bounded head plus the
      full size** — `redact/2` returns exactly those two flat fields and
      is what the emitters must use for tool arguments, tool results,
      inbox payloads and anything else a model or a shell produced;
    * **never** record a whole transcript, a whole tool result, or a
      whole message. If the interesting part is not in the head, record
      a path to it instead;
    * `record/4` is a second line of defence: a line that would exceed
      8192 bytes is replaced by a stub that keeps the common fields and
      the size, so a careless emitter cannot fill the disk with one
      event.

  ## Event schema

  Every line is a flat object with the common fields `ts` (ISO8601 UTC),
  `mono` (milliseconds since this OS process started), `space`, `agent`
  and `type`, plus that type's payload:

  | type | payload |
  | --- | --- |
  | `turn` | `event` (the machine event tag), `from` / `to` (each `{kind, phase}`), `iteration`, `max_iterations`, `message_indices` |
  | `llm` | `message_index`, `iteration`, `model`, `projected_tokens`, `limit`, `reserve`, `remaining`, `outcome` |
  | `tool` | `name`, `args_head`, `args_bytes`, `result_bytes`, `is_error`, `worker`, `tool_call_id` — no `duration_ms`: the worker does not measure per call and the machine has no start stamp |
  | `inbox` | `action` (`enqueued` / `queued` / `delivered` / `drained` / `refused`), `from`, `kind`, `mode`, `bytes`, `count`, `disposition`. On a `drained` line `disposition` repeats `mode` (the drain has no sender to report a disposition for) |
  | `debt` | `action` (`set` / `cleared` / `reminded` / `gave_up` / `give_up_refused`), `peer`, `reminders_used`, `how` |
  | `status` | `payload` — the `chat:status` payload verbatim (it is small, and "what did the UI actually see" is the question the transparency rule makes central) |
  | `notification` | `notification_type`, `message` |
  | `error` | `message`, `source` (the `[Source: Module.fn/arity]` tag) |
  | `compaction` | `limit`, `reserve`, `used`, `projected`, `carried`, `loop_count`, `archived_to_index`; `trigger` only on the commit line, where it is `"commit"` — the staged line has no honest value for it |
  | `usage` | `input`, `output`, `cache_read`, `cache_write`, `total`; the child-usage line adds `name`, the child the cost came from |
  | `child` | `action` (`spawned` / `completed` / `failed` / `terminated` / `archived` / `stopped`), `name`, and — on the spawn line only — `vocation`, `depth`, `model`, `clone_context`, `archive` |

  A line the writer could not encode keeps the common fields and gains
  `encode_error`; a line the writer had to bound keeps the common fields
  and gains `truncated: true` plus `line_bytes`. Both are visible in the
  digest rather than silently missing.

  ## Cost, and why this cannot break a turn

  This is diagnostic code running inside the agent process, so:

    * when recording is off, `record/4` is two configuration lookups and
      returns `:ok` — no encoding, no file system, no allocation of note;
    * when it is on, one append (`File.write!/3` with `:append`) per
      event, so nothing is held open and nothing is buffered;
    * `record/4` **never raises into the caller**. A failed write logs a
      warning once and then disables the writer for that directory (the
      rescue is at the bottom of `do_write/5`, and `disable/2` is
      idempotent), because "the observer broke the turn" is not an
      acceptable failure mode. A payload that cannot be encoded is
      recorded as a stub and does *not* disable the writer, because the
      writer itself is fine.
  """

  require Logger

  @head_bytes 200
  @max_line_bytes 8_192
  @default_dir "notes/usage-runs"
  @run_id_key {__MODULE__, :run_id}

  @typedoc "The event kinds the runtime records."
  @type type() ::
          :turn
          | :llm
          | :tool
          | :inbox
          | :debt
          | :status
          | :notification
          | :error
          | :compaction
          | :usage
          | :child

  @typedoc "One decoded timeline line."
  @type event() :: map()

  @doc """
  Whether timeline recording is on.

  Application config (`:nest, :timeline_enabled`) wins when it is set;
  otherwise the `NEST_TIMELINE` environment variable decides. Both default
  to off.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:nest, :timeline_enabled) do
      nil -> env_enabled?()
      value -> value == true
    end
  end

  defp env_enabled?, do: System.get_env("NEST_TIMELINE") in ["1", "true", "yes"]

  @doc """
  Append one event to the current run's `events.jsonl`.

  `type` is a `t:type/0`; `payload` is that type's fields (see the schema
  in the moduledoc). Returns `:ok` always: when recording is off this is a
  cheap no-op, and when it is on a failure is logged and the writer is
  disabled rather than raised into the caller.
  """
  @spec record(term(), term(), type(), map()) :: :ok
  def record(space_id, agent_name, type, payload) do
    if enabled?(), do: write(space_id, agent_name, type, payload), else: :ok
  end

  @doc """
  Bound a content-shaped value for recording: a bounded head plus the
  full size, as two flat keys `"<prefix>_head"` and `"<prefix>_bytes"`.

  This is the redaction mechanism the emitters use. `prefix` is a literal
  from the caller (`"args"`, `"content"`, …) and the keys are strings, so
  no atom is created from data. The head is at most 200 bytes and is
  always valid UTF-8 (a partial character at the cut is dropped, and a
  non-UTF-8 value is sanitised) so it always encodes; a value longer than
  the head is marked with a trailing `…`.
  """
  @spec redact(String.t(), term()) :: %{optional(String.t()) => String.t() | non_neg_integer()}
  def redact(prefix, content) do
    %{"#{prefix}_head" => head(content), "#{prefix}_bytes" => bytes(content)}
  end

  @doc """
  The full size in bytes of a content-shaped value.

  A binary is measured as-is (so a non-UTF-8 tool result is still measured
  honestly); anything else is inspected with a bound, because a content
  field is expected to be a binary.
  """
  @spec bytes(term()) :: non_neg_integer()
  def bytes(nil), do: 0
  def bytes(content) when is_binary(content), do: byte_size(content)

  def bytes(content),
    do: byte_size(inspect(content, limit: 20, printable_limit: @head_bytes))

  @doc "The base directory runs are written under."
  @spec base_dir() :: String.t()
  def base_dir, do: Application.get_env(:nest, :timeline_dir, @default_dir)

  @doc "The directory of this OS process's run."
  @spec run_dir() :: String.t()
  def run_dir, do: Path.join(base_dir(), run_id())

  @doc "The events file of this OS process's run."
  @spec events_path() :: String.t()
  def events_path, do: Path.join(run_dir(), "events.jsonl")

  @doc """
  The newest run directory under `base_dir/0`, or `nil` when there is none.

  Ordered by modification time and then by name, so two runs recorded in
  the same second still resolve deterministically. Returns `nil` for a
  missing or empty base directory, which is the ordinary "nothing recorded
  yet" case.
  """
  @spec latest_run() :: String.t() | nil
  def latest_run do
    case File.ls(base_dir()) do
      {:ok, names} ->
        names
        |> Enum.map(&Path.join(base_dir(), &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.sort_by(&run_sort_key/1, :desc)
        |> List.first()

      {:error, _reason} ->
        nil
    end
  end

  @doc """
  Read a run's events.

  Returns `{events, problems}`: the parsed events in file order, and one
  `{line, reason}` per line that could not be parsed — a truncated final
  line from a crash mid-write, say. `line` is `:file` when the file itself
  could not be read. A diagnostic tool that dies on corrupt input is
  useless, so a bad line is reported and skipped, never raised.
  """
  @spec load(String.t()) :: {[event()], [{pos_integer() | :file, String.t()}]}
  def load(dir) do
    path = Path.join(dir, "events.jsonl")

    case File.read(path) do
      {:ok, body} -> parse(body)
      {:error, reason} -> {[], [{:file, "cannot read #{path}: #{:file.format_error(reason)}"}]}
    end
  end

  # ---- writing ----

  defp write(space_id, agent_name, type, payload) do
    dir = run_dir()

    if disabled?(dir) do
      :ok
    else
      do_write(dir, space_id, agent_name, type, payload)
    end
  rescue
    # `run_dir/0` sits *outside* `do_write/5`'s rescue, and it can raise: a
    # `:timeline_dir` that is not a binary makes `Path.join/2` raise a
    # `FunctionClauseError` straight into the caller — which, for the emitters
    # that call `record/4` directly, is inside a settle. `record/4`'s contract is
    # that it never raises into the caller, so the directory computation is
    # guarded here as well.
    error -> disable(disable_key(), error)
  end

  # The key a failed write disables under when the run directory could not be
  # computed at all: the configured base dir when it is usable, otherwise a
  # string that says so. A string — never a tuple — because `disable/2`
  # interpolates the key into its log line, and `String.Chars` would raise on a
  # tuple, inside the very rescue that must not raise.
  defp disable_key do
    case base_dir() do
      dir when is_binary(dir) -> dir
      other -> "an invalid :timeline_dir (#{inspect(other)})"
    end
  end

  defp do_write(dir, space_id, agent_name, type, payload) do
    line = build_line(space_id, agent_name, type, payload)
    json = line |> encode(dir) |> bound(line, dir)

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "events.jsonl"), [json, "\n"], [:append])
    :ok
  rescue
    error -> disable(dir, error)
  end

  defp build_line(space_id, agent_name, type, payload) do
    common = %{
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "mono" => mono_ms(),
      "space" => space_id,
      "agent" => agent_name,
      "type" => stringify(type)
    }

    payload |> normalize_payload() |> Map.merge(common)
  end

  # The common fields win, and both sides use string keys, so a payload
  # that happens to carry `space` cannot produce a duplicate JSON key.
  defp normalize_payload(payload) when is_map(payload) do
    Map.new(payload, fn {key, value} -> {key_string(key), value} end)
  end

  defp normalize_payload(other), do: %{"payload" => describe(other)}

  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key) when is_binary(key), do: key
  defp key_string(key), do: describe(key)

  defp stringify(type) when is_atom(type), do: Atom.to_string(type)
  defp stringify(type) when is_binary(type), do: type
  defp stringify(other), do: describe(other)

  # Milliseconds since this OS process started: the run's zero point, and
  # a monotonic-enough clock for ordering events inside one run.
  defp mono_ms do
    {elapsed_ms, _since_last_call} = :erlang.statistics(:wall_clock)
    elapsed_ms
  end

  defp encode(line, dir) do
    case Jason.encode(line) do
      {:ok, json} ->
        json

      {:error, reason} ->
        warn_once({:warned, :encode, dir}, fn ->
          "Nest.Timeline: a #{inspect(line["type"])} payload could not be encoded " <>
            "(#{inspect(reason)}); recorded as a stub"
        end)

        Jason.encode!(stub(line, %{"encode_error" => inspect(reason)}))
    end
  end

  defp bound(json, line, dir) do
    if byte_size(json) <= @max_line_bytes do
      json
    else
      warn_once({:warned, :bound, dir}, fn ->
        "Nest.Timeline: a #{inspect(line["type"])} line was #{byte_size(json)} bytes; " <>
          "recorded as a stub (use Nest.Timeline.redact/2 for content)"
      end)

      Jason.encode!(stub(line, %{"truncated" => true, "line_bytes" => byte_size(json)}))
    end
  end

  # A stub must itself always encode, so the identity fields fall back to a
  # string when the emitter handed over something JSON cannot carry. `ts`
  # and `type` are already strings by construction (`stringify/1`).
  defp stub(line, extra) do
    %{
      "ts" => line["ts"],
      "mono" => line["mono"],
      "space" => identity(line["space"]),
      "agent" => identity(line["agent"]),
      "type" => line["type"]
    }
    |> Map.merge(extra)
  end

  defp identity(value) when is_binary(value) or is_integer(value) or is_atom(value), do: value
  defp identity(value), do: describe(value)

  defp disabled?(dir), do: :persistent_term.get({:disabled, dir}, false)

  # "Log once, then stop trying": the flag is per directory, so a
  # misconfigured directory disables recording for that directory and
  # nothing else (and a test can point at its own).
  defp disable(dir, error) do
    unless disabled?(dir) do
      :persistent_term.put({:disabled, dir}, true)

      Logger.warning("Nest.Timeline: recording disabled for #{dir}: #{Exception.message(error)}")
    end

    :ok
  end

  defp warn_once(key, message_fun) do
    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)
      Logger.warning(message_fun.())
    end

    :ok
  end

  # ---- run identity ----

  # Captured once per OS process and cached. The timestamp is derived from
  # the VM's start time, so two processes racing to initialise it compute
  # the *same* id and cannot end up in two directories.
  defp run_id do
    case :persistent_term.get(@run_id_key, nil) do
      nil ->
        id = "#{vm_start_stamp()}-#{os_pid()}"
        :persistent_term.put(@run_id_key, id)
        id

      id ->
        id
    end
  end

  defp vm_start_stamp do
    started_ms = System.system_time(:millisecond) - mono_ms()

    started_ms
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%Y%m%d-%H%M%S")
  end

  defp os_pid, do: :os.getpid() |> to_string()

  defp run_sort_key(dir) do
    mtime =
      case File.stat(dir) do
        {:ok, %File.Stat{mtime: mtime}} -> mtime
        {:error, _reason} -> {{0, 0, 0}, {0, 0, 0}}
      end

    {mtime, Path.basename(dir)}
  end

  # ---- reading ----

  defp parse(body) do
    {events, problems} =
      body
      |> String.split("\n", trim: true)
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, &parse_line/2)

    {Enum.reverse(events), Enum.reverse(problems)}
  end

  defp parse_line({line, number}, {events, problems}) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) ->
        {[event | events], problems}

      {:ok, other} ->
        {events, [{number, "not a JSON object: #{describe(other)}"} | problems]}

      {:error, reason} ->
        {events, [{number, "invalid JSON: #{Exception.message(reason)}"} | problems]}
    end
  end

  # ---- bounded heads ----

  defp head(content) do
    text = text(content)

    if byte_size(text) > @head_bytes do
      text |> binary_part(0, @head_bytes) |> utf8() |> Kernel.<>("…")
    else
      text
    end
  end

  defp text(nil), do: ""
  defp text(content) when is_binary(content), do: utf8(content)
  defp text(content), do: describe(content)

  # `:unicode.characters_to_binary/1` reports invalid or incomplete input
  # instead of raising, which matters here: a tool result is arbitrary
  # bytes, and this must never take down the process that is recording it.
  defp utf8(bin) do
    case :unicode.characters_to_binary(bin) do
      converted when is_binary(converted) -> converted
      {:error, valid, _rest} -> valid
      {:incomplete, valid, _rest} -> valid
    end
  end

  # A short, always-encodable rendering of a non-content value. Lists are
  # rendered as lists, not charlists: a list of small integers is data.
  defp describe(value) do
    inspect(value, limit: 20, printable_limit: @head_bytes, charlists: :as_lists)
  end
end
