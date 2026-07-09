# Diagnostic compaction probe.
#
# Replays the compactor's summarization call against the real
# LLM without committing anything to the database, so we can
# reproduce compaction failures (most commonly `:llm_returned_empty`)
# and see exactly what the LLM did or didn't return.
#
# Run with:
#
#     mix run scripts/compaction_probe.exs <agent_name> [options]
#
# Options:
#
#   --pass=head         Probe the head-summary pass (default).
#   --pass=tail         Probe the tail-summary pass. Requires
#                       a previous head summary; one is fetched
#                       live using --pass=head if missing.
#   --pass=full         Run both passes and report each.
#   --repeat=N          Run the chosen pass N times back-to-back.
#                       Useful for catching intermittent empties.
#                       Default: 1.
#   --snapshot=FILE     Persist the probe input to FILE.
#   --replay=FILE       Replay a previously-saved snapshot.
#   --verbose           Print full response text instead of a
#                       500-char preview.
#
# Every invocation writes a full event log to /tmp:
#
#     /tmp/nest-compaction-probe-{agent}-{pass}-{pid}-{ts}.log
#
# The log has every canonical event from the LLM stream (text
# deltas, thinking deltas, finish_reason, usage, refusal, error,
# done), the request payload, per-run summaries, and an
# aggregate table. The log is the canonical artifact — even when
# the console output looks trivial, the file has everything.
#
# This is a self-contained debug script. It deliberately does
# not share code with `compact_agent_history.exs`; the prompt
# text is the one exception (single-source via
# `Nest.Scripts.CompactionProbeSupport.compaction_suffix/2` for
# the per-call suffix string, so the probe and the live
# compactor stay in lockstep).

defmodule Nest.Scripts.CompactionProbe do
  @moduledoc false

  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.LLM.ClientConfig
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
  alias Nest.LLM.StreamConsumer
  alias Nest.Persistence
  alias Nest.Scripts.CompactionProbeSupport
  alias Nest.Tokens.Estimator

  require Logger

  def run(argv) do
    {opts, positional, _invalid} =
      OptionParser.parse(argv,
        strict: [
          pass: :string,
          repeat: :integer,
          snapshot: :string,
          replay: :string,
          verbose: :boolean
        ]
      )

    pass = parse_pass(opts[:pass] || "head")
    repeat = opts[:repeat] || 1
    verbose = opts[:verbose] || false

    {input, log} = resolve_input(opts, positional)
    log_header(log, input, pass, repeat)

    Logger.info("""

    Compaction probe
    ────────────────
    source:    #{input.source}
    pass:      #{pass}
    repeat:    #{repeat}
    log:       #{log.path}
    """)

    if Enum.empty?(input.messages) do
      Logger.error("No messages to probe; aborting")
      log_section(log, "ABORT: no messages to probe")
      log_close(log)
      Elixir.System.halt(1)
    end

    log_line(log, "loaded_messages=#{length(input.messages)} estimated_tokens=#{Estimator.estimate_messages(input.messages)}")

    case pass do
      :head -> run_pass(input, log, &build_head_input/1, "head", repeat, verbose)
      :tail -> run_tail_pass(input, log, repeat, verbose)
      :full -> run_full_pass(input, log, repeat, verbose)
    end

    log_close(log)
  end

  ## --- log file helpers -----------------------------------------

  # A `log` is a small struct bundling the file handle and the
  # path. All event writes go through `log_line/2` so the format
  # stays consistent and we can swap in a buffered writer later
  # without rewriting callers.
  defp log_open(path) do
    {:ok, handle} = File.open(path, [:write, :utf8])
    %{path: path, handle: handle}
  end

  defp log_line(log, line) when is_binary(line) do
    IO.binwrite(log.handle, line <> "\n")
  end

  defp log_section(log, title) do
    bar = String.duplicate("=", 64)
    log_line(log, bar)
    log_line(log, title)
    log_line(log, bar)
  end

  defp log_close(%{handle: handle, path: path}) do
    File.close(handle)
    Logger.info("Log written: #{path}")
  end

  defp log_header(log, input, pass, repeat) do
    bar = String.duplicate("#", 64)
    log_line(log, bar)
    log_line(log, "# Compaction probe log")
    log_line(log, "#  pid:        #{System.pid()}")
    log_line(log, "#  timestamp:  #{DateTime.utc_now() |> DateTime.to_iso8601()}")
    log_line(log, "#  source:     #{input.source}")
    log_line(log, "#  pass:       #{pass}")
    log_line(log, "#  repeat:     #{repeat}")
    log_line(log, "#  agent:      #{input.agent.name}")
    log_line(log, "#  model:      #{inspect(input.agent.model, limit: 5)}")

    input_text =
      input.messages
      |> Enum.map(fn {role, msg} -> "#{role}@#{msg.index}" end)
      |> Enum.join(", ")

    log_line(log, "#  messages:   [#{input_text}]")
    log_line(log, bar)
  end

  ## --- input resolution -----------------------------------------

  defp resolve_input(opts, positional) do
    input =
      cond do
        replay = opts[:replay] -> load_snapshot(replay)
        true -> load_from_db(positional, opts)
      end

    path = build_log_path(input, opts)
    log = log_open(path)
    {input, log}
  end

  defp build_log_path(input, opts) do
    ts = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    pass = opts[:pass] || "head"
    "/tmp/nest-compaction-probe-#{input.agent.name}-#{pass}-#{System.pid()}-#{ts}.log"
  end

  defp load_from_db([], _opts), do: raise(usage())

  defp load_from_db([agent_name | _], opts) do
    case Persistence.fetch_agent_by_name(agent_name) do
      {:ok, %PersistedAgent{} = agent} ->
        rows = load_messages(agent.id)
        messages = Enum.map(rows, &PersistedMessage.to_runtime/1)

        input = %{
          source: "db:#{agent_name}",
          agent: agent,
          messages: messages,
          head_summary: nil
        }

        maybe_persist_snapshot(input, opts[:snapshot])
        input

      {:error, :not_found} ->
        raise "Agent not found: #{agent_name}"
    end
  end

  defp load_messages(agent_id) do
    import Ecto.Query

    Nest.Repo.all(
      from(m in PersistedMessage,
        where: m.agent_id == ^agent_id and is_nil(m.archived_at) and m.role != "compaction",
        order_by: [asc: m.message_index]
      )
    )
  end

  defp maybe_persist_snapshot(input, nil), do: input

  defp maybe_persist_snapshot(input, path) do
    iodata = [
      <<1>>,
      length_prefixed(input.agent.name),
      length_prefixed(:erlang.term_to_binary(input.agent.model)),
      <<length(input.messages)::32>>,
      Enum.map(input.messages, fn msg -> length_prefixed(:erlang.term_to_binary(msg)) end),
      head_summary_segment(input.head_summary)
    ]

    File.write!(path, IO.iodata_to_binary(iodata))
    input
  end

  defp head_summary_segment(nil), do: <<0>>
  defp head_summary_segment(text), do: [<<1>>, length_prefixed(text)]

  defp length_prefixed(bin) when is_binary(bin) do
    [<<byte_size(bin)::32>>, bin]
  end

  defp load_snapshot(path) do
    <<1, rest::binary>> = File.read!(path)
    {name_bin, rest} = read_length_prefixed(rest)
    {_model_bin, rest} = read_length_prefixed(rest)
    {count, rest} = read_int32(rest)

    messages =
      Enum.reduce(1..count, {[], rest}, fn _, {acc, rest} ->
        {bin, rest} = read_length_prefixed(rest)
        {[:erlang.binary_to_term(bin) | acc], rest}
      end)
      |> elem(0)
      |> Enum.reverse()

    <<has_head::8, rest::binary>> = rest

    {head_summary, _rest} =
      case has_head do
        0 -> {nil, rest}
        1 -> {text_bin, rest} = read_length_prefixed(rest)
             {text_bin, rest}
      end

    agent = %PersistedAgent{name: name_bin, model: %{}}

    %{source: "snapshot:#{path}", agent: agent, messages: messages, head_summary: head_summary}
  end

  defp read_length_prefixed(<<len::32, rest::binary>>) do
    <<bin::binary-size(len), rest::binary>> = rest
    {bin, rest}
  end

  defp read_int32(<<n::32, rest::binary>>), do: {n, rest}

  defp parse_pass("head"), do: :head
  defp parse_pass("tail"), do: :tail
  defp parse_pass("full"), do: :full
  defp parse_pass(other), do: raise("invalid --pass value: #{other} (expected head, tail, or full)")

  ## --- pass runners ---------------------------------------------

  defp run_pass(input, log, input_builder, label, repeat, verbose) do
    {head_input, _last_user, _responses} = split(input.messages, head_only: true)

    log_section(log, "[#{label}] pass starts, #{length(head_input)} head_input messages")

    results =
      for run <- 1..repeat do
        Logger.info("── #{label} run #{run}/#{repeat} ──")
        target = input_builder.(input.messages)
        probe_one(input.agent, log, target, run, repeat, label, verbose)
      end

    write_aggregate(log, label, results)
    summarize_console(label, results)
    results
  end

  defp run_tail_pass(input, log, repeat, verbose) do
    log_section(log, "[tail] pass starts; acquiring head summary first")

    head_summary =
      case input.head_summary do
        nil ->
          head_target = build_head_input(input.messages)

          case probe_one(input.agent, log, head_target, 0, 0, "head(setup)", verbose) do
            {:ok, text, _summary} -> text
            other -> abort_other_pass(log, other)
          end

        text ->
          text
      end

    tail_input = build_tail_input(input.messages, head_summary)

    log_section(log, "[tail] head summary acquired (#{byte_size(head_summary)} chars); #{length(tail_input)} input messages")

    results =
      for run <- 1..repeat do
        Logger.info("── tail run #{run}/#{repeat} ──")
        probe_one(input.agent, log, tail_input, run, repeat, "tail", verbose)
      end

    write_aggregate(log, "tail", results)
    summarize_console("tail", results)
    results
  end

  defp run_full_pass(input, log, repeat, verbose) do
    log_section(log, "[full] pass starts; head then tail")

    head_target = build_head_input(input.messages)

    head_result = probe_one(input.agent, log, head_target, 0, 0, "head(setup)", verbose)

    case head_result do
      {:ok, head_summary, _summary} ->
        tail_input = build_tail_input(input.messages, head_summary)

        log_section(log, "[full] head summary acquired (#{byte_size(head_summary)} chars); #{length(tail_input)} input messages")

        tail_results =
          for run <- 1..repeat do
            Logger.info("── full tail run #{run}/#{repeat} ──")
            probe_one(input.agent, log, tail_input, run, repeat, "full/tail", verbose)
          end

        write_aggregate(log, "full/tail", tail_results)
        summarize_console("full/tail", tail_results)
        tail_results

      other ->
        abort_other_pass(log, other)
    end
  end

  defp abort_other_pass(log, other) do
    Logger.error("Aborting chain: head pass failed with #{inspect(elem(other, 0))}")
    log_section(log, "ABORT: chain failed at head pass")
    log_close(log)
    Elixir.System.halt(1)
  end

  ## --- input builders -------------------------------------------

  defp build_head_input(messages) do
    {head_input, _, _} = split(messages, head_only: true)
    head_input
  end

  defp build_tail_input(messages, head_summary) do
    {head_input, last_user, responses} = split(messages, head_only: true)
    system = List.first(head_input)
    [system, wrap_head_summary(head_summary), last_user | responses]
  end

  # Mirror Nest.Tokens.Compactor.split_messages/1. Returns
  # `{head_input, last_user, responses}`. Aborts via halt on
  # `:too_short`.
  defp split(messages, opts) do
    cond do
      length(messages) < 2 ->
        Logger.error("Messages too short for compaction probe (need >=2)")
        Elixir.System.halt(1)

      last_user_idx = find_last_user_index(messages) ->
        {head, [last_user | responses]} = Enum.split(messages, last_user_idx)
        system = List.first(head)

        head_to_summarize =
          case head do
            [_system | rest] -> rest
            _ -> head
          end

        if Enum.empty?(head_to_summarize) and opts[:head_only] do
          Logger.error("No head to summarize; conversation has no history past the system prompt")
          Elixir.System.halt(1)
        end

        head_input =
          case system do
            nil -> head_to_summarize
            sys -> [sys | head_to_summarize]
          end

        {head_input, last_user, responses}
    end
  end

  defp find_last_user_index([]), do: nil

  defp find_last_user_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {msg, idx} ->
      if match?({:user, _}, msg), do: idx
    end)
  end

  defp wrap_head_summary(text) do
    {:system,
     %Nest.Messages.System{
       index: 0,
       parts: [%Nest.Messages.Part.Text{text: text}],
       timestamp: DateTime.utc_now(),
       api_logs: []
     }}
  end

  ## --- one probe call -------------------------------------------

  # Returns one of:
  #   {:ok, text, summary}     — text is non-empty; summary has finish_reason etc.
  #   {:empty, summary}        — text was "" or whitespace-only (compactor would
  #                              surface as `:llm_returned_empty`).
  #   {:error, reason, summary} — transport / stream error.
  #
  # `summary` is the post-stream accumulator minus the raw deltas:
  # `%{stop_reason, usage, refusal, thinking_chars, text_chars, model, elapsed_ms,
  #      input_tokens}`. Returned in all three cases so callers can report
  # consistently.
  defp probe_one(agent, log, messages, run, total, label, verbose) do
    log_section(log, "[#{label}] run #{run}/#{total} starts, input_messages=#{length(messages)}")

    log_request(log, run, total, label, messages)

    with {:ok, client_config, _context_limit} <-
           CompactionProbeSupport.build_client_config(agent.model) do
      llm_call = build_verbose_llm_call(client_config, log, run, total, label)

      input_tokens = Estimator.estimate_messages(messages)
      log_line(log, "[#{format_ts()}] run=#{run}/#{total} kind=run_start input_messages=#{length(messages)} input_tokens_est=#{input_tokens} model=#{client_config.model}")

      Logger.info("input: #{length(messages)} messages, ~#{input_tokens} estimated tokens")

      t0 = System.monotonic_time(:millisecond)
      result = llm_call.(messages)
      elapsed = System.monotonic_time(:millisecond) - t0

      case result do
        :no_response ->
          summary = %{elapsed_ms: elapsed, input_tokens: input_tokens, error: :no_response}

          log_line(log, "[#{format_ts()}] run=#{run}/#{total} kind=run_summary result=error reason=:no_response elapsed_ms=#{elapsed}")

          {:error, :no_response, summary}

        {:text_event, response, acc, in_band_error} ->
          summarize_stream_result(log, run, total, label, response, acc, in_band_error, elapsed, input_tokens, verbose)
      end
    else
      {:error, reason} = err ->
        Logger.error("Client config failed: #{inspect(reason)}")
        log_line(log, "[#{format_ts()}] run=#{run}/#{total} kind=client_config_error reason=#{inspect(reason)}")
        err
    end
  end

  # Logs the exact RunRequest payload so the log is replayable.
  defp log_request(log, run, total, label, messages) do
    bar = String.duplicate("-", 64)
    log_line(log, bar)
    log_line(log, "[#{format_ts()}] run=#{run}/#{total} kind=request_preview label=#{label}")

    messages
    |> Enum.with_index()
    |> Enum.each(fn {{role, msg}, idx} ->
      text_preview =
        msg.parts
        |> Enum.map(&part_text/1)
        |> Enum.join("\n")
        |> truncate_for_log(200)

      log_line(log, "  msg[#{idx}] role=#{role} index=#{msg.index} preview=#{text_preview}")
    end)

    log_line(log, bar)
  end

  defp part_text(%Nest.Messages.Part.Text{text: t}), do: t
  defp part_text(%Nest.Messages.Part.Thinking{thinking: t}), do: "[thinking] #{t || ""}"
  defp part_text(%Nest.Messages.Part.ToolUse{name: name, arguments: a}), do: "[tool_use] #{name}(#{inspect(a, limit: 5)})"
  defp part_text(%Nest.Messages.Part.ToolResult{tool_call_id: id, content: c}), do: "[tool_result] id=#{id} content=#{inspect(c, limit: 3)}"
  defp part_text(other), do: inspect(other, limit: 5)

  defp truncate_for_log(text, n) when byte_size(text) <= n, do: text |> escape_for_log()
  defp truncate_for_log(text, n), do: (String.slice(text, 0, n) <> "...") |> escape_for_log()

  # Escape newlines and tabs so each request_preview entry stays
  # on a single log line.
  defp escape_for_log(text) do
    text
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end

  defp summarize_stream_result(log, run, total, label, response, acc, in_band_error, elapsed, input_tokens, verbose) do
    text = text_from(response, acc)
    thinking = thinking_from(response, acc)
    usage = usage_from(response, acc)
    stop_reason = stop_reason_from(response, acc)
    refusal = refusal_from(response, acc)
    model = model_from(response, acc)

    text_chars = byte_size(text || "")
    thinking_chars = byte_size(thinking || "")

    summary = %{
      elapsed_ms: elapsed,
      input_tokens: input_tokens,
      text_chars: text_chars,
      thinking_chars: thinking_chars,
      stop_reason: stop_reason,
      usage: usage,
      refusal: refusal,
      model: model
    }

    log_line(log, "[#{format_ts()}] run=#{run}/#{total} kind=usage input_tokens=#{usage_input(usage)} output_tokens=#{usage_output(usage)} cache_read=#{usage_cache(usage)} reasoning=#{usage_reasoning(usage)} total=#{usage_total(usage)}")
    log_line(log, "[#{format_ts()}] run=#{run}/#{total} kind=finish_reason value=#{inspect(stop_reason)}")
    log_line(log, "[#{format_ts()}] run=#{run}/#{total} kind=accumulator text_chars=#{text_chars} thinking_chars=#{thinking_chars} refusal=#{inspect(refusal)} model=#{inspect(model)}")

    cond do
      not is_nil(in_band_error) ->
        log_line(log, "[#{format_ts()}] run=#{run}/#{total} kind=run_summary result=error reason=#{inspect(in_band_error)} elapsed_ms=#{elapsed}")
        Logger.warning("#{label} run #{run}/#{total}: stream error in #{elapsed}ms: #{inspect(in_band_error)}")
        {:error, in_band_error, summary}

      String.trim(text || "") == "" ->
        log_line(log, "[#{format_ts()}] run=#{run}/#{total} kind=run_summary result=empty elapsed_ms=#{elapsed} text_chars=#{text_chars} stop_reason=#{inspect(stop_reason)}")
        Logger.warning("LLM returned EMPTY summary in #{elapsed}ms (finish_reason=#{inspect(stop_reason)}, text_chars=#{text_chars})")
        {:empty, summary}

      true ->
        log_line(log, "[#{format_ts()}] run=#{run}/#{total} kind=run_summary result=ok elapsed_ms=#{elapsed} text_chars=#{text_chars} stop_reason=#{inspect(stop_reason)}")

        preview = truncate(text, 500)
        Logger.info("LLM returned #{byte_size(text)}-byte summary in #{elapsed}ms; finish_reason=#{inspect(stop_reason)}")
        Logger.info("preview:\n#{if verbose, do: text, else: preview}")

        {:ok, text, summary}
    end
  end

  # Read a field preferring the producer's `RunResponse` (which
  # may have parsed value from the wire — e.g. AnthropicClient
  # puts `stop_reason` into `RunResponse.stop_reason`) but
  # falling back to the accumulator on nil.
  #
  # OpenAI-style streams emit `:text` deltas into the accumulator's
  # `acc.text` IO-list but the `{:done, _}` `RunResponse` they
  # build is empty (text: nil) since the consumer is expected to
  # merge via `Runner.normalize_response/2`. The probe bypasses
  # the Runner, so without the fallback we'd see `text_chars=0`
  # even though deltas were streamed.
  defp text_from(%RunResponse{text: t}, acc) when is_binary(t), do: t
  defp text_from(%RunResponse{}, acc), do: iolist_to_binary_or_nil(acc.text)
  defp text_from(nil, acc), do: iolist_to_binary_or_nil(acc.text)

  defp thinking_from(%RunResponse{thinking: t}, acc) when is_binary(t), do: t
  defp thinking_from(%RunResponse{}, acc), do: iolist_to_binary_or_nil(acc.thinking)
  defp thinking_from(nil, acc), do: iolist_to_binary_or_nil(acc.thinking)

  defp usage_from(%RunResponse{usage: u}, _acc) when not is_nil(u), do: u
  defp usage_from(%RunResponse{}, acc), do: acc.usage
  defp usage_from(nil, acc), do: acc.usage

  defp stop_reason_from(%RunResponse{stop_reason: s}, _acc) when not is_nil(s), do: s
  defp stop_reason_from(%RunResponse{}, acc), do: acc.stop_reason
  defp stop_reason_from(nil, acc), do: acc.stop_reason

  defp refusal_from(%RunResponse{refusal: r}, acc) when is_binary(r), do: r
  defp refusal_from(%RunResponse{}, acc), do: acc.refusal
  defp refusal_from(nil, acc), do: acc.refusal

  defp model_from(%RunResponse{model: m}, _acc) when is_binary(m), do: m
  defp model_from(%RunResponse{}, _acc), do: nil
  defp model_from(nil, _acc), do: nil

  defp iolist_to_binary_or_nil([]), do: nil
  defp iolist_to_binary_or_nil(iolist), do: IO.iodata_to_binary(iolist)

  defp usage_input(nil), do: "?"
  defp usage_input(%{input_tokens: n}), do: n

  defp usage_output(nil), do: "?"
  defp usage_output(%{output_tokens: n}), do: n

  defp usage_cache(nil), do: "?"
  defp usage_cache(%{cache_read_input_tokens: n}), do: n

  defp usage_reasoning(nil), do: "?"
  defp usage_reasoning(%{reasoning_tokens: n}), do: n

  defp usage_total(nil), do: "?"
  defp usage_total(%{total_tokens: n}), do: n

  ## --- verbose LLM call (inline; not shared with recovery) ------

  # Builds the LLM callback the probe uses. The callback:
  # 1. Computes the compactor's dynamic budget hint.
  # 2. Builds a `RunRequest` matching what the live compactor
  #    sends — the agent's prior messages PLUS the
  #    `[mode: compact]` suffix system message as the trailing
  #    entry. The agent's own [mode: compact] paragraph (in its
  #    initial system prompt) stays at position 0; KV cache
  #    reuse relies on that.
  # 3. Sends the request through the configured client.
  # 4. Streams every canonical event into `log` (text delta,
  #    thinking delta, finish_reason, usage, refusal, error, done).
  # 5. Returns `:no_response` if the client returns an error tuple, or
  #    `{:text_event, _, acc, in_band_error}` if the stream was processed.
  defp build_verbose_llm_call(%ClientConfig{} = client_config, log, run, total, label) do
    fn messages ->
      context_limit = Map.get(client_config, :context_limit, 200_000)

      suffix =
        if is_integer(context_limit) and context_limit > 0 do
          system_msg = Enum.find(messages, &match?({:system, _}, &1)) || {:system, %{parts: []}}

          case Nest.Tokens.Compactor.compute_summary_budget(context_limit, system_msg, messages, nil) do
            {:ok, _n, rendered} ->
              rendered

            {:error, :reserve_exhausted} ->
              # Probe never refuses — fall back to a minimal suffix
              # so the LLM gets at least one instruction.
              CompactionProbeSupport.suffix_system_message(1_000, nil)
          end
        else
          CompactionProbeSupport.suffix_system_message(1_000, nil)
        end

      request = %RunRequest{
        messages: messages ++ [suffix],
        tools: nil,
        tool_choice: :none,
        model: client_config.model,
        stream: true,
        metadata: %{}
      }

      log_line(
        log,
        "[#{format_ts()}] run=#{run}/#{total} kind=suffix_logged text=#{quote_for_log(elem(suffix, 1).parts |> hd() |> Map.get(:text))}"
      )

      opts = [
        base_url: client_config.base_url,
        api_key: client_config.api_key,
        receive_timeout: client_config.receive_timeout
      ]

      case client_config.client.run(request, opts) do
        {:ok, stream} ->
          consume_verbose(stream, log, run, total, label)

        {:error, reason} ->
          log_line(log, "[#{format_ts()}] run=#{run}/#{total} kind=client_error reason=#{inspect(reason)}")
          log_line(log, "[#{format_ts()}] run=#{run}/#{total} kind=run_summary result=error reason=#{inspect(reason)} elapsed_ms=0")
          :no_response
      end
    end
  end

  defp consume_verbose(stream, log, run, total, _label) do
    consumer = %StreamConsumer{
      on_text: fn text, sent ->
        log_line(log, "[#{format_ts()}] run=#{run}/#{total} kind=text_delta text=#{quote_for_log(text)}")
        sent
      end,
      on_thinking: fn text, sent ->
        log_line(log, "[#{format_ts()}] run=#{run}/#{total} kind=thinking_delta text=#{quote_for_log(text)}")
        sent
      end,
      on_signature: fn sig ->
        log_line(log, "[#{format_ts()}] run=#{run}/#{total} kind=thinking_signature value=#{inspect(sig)}")
        :ok
      end
    }

    {acc, response, in_band_error, _sent} = StreamConsumer.reduce(stream, consumer)

    log_accumulator_extras(log, run, total, acc)

    {:text_event, response, acc, in_band_error}
  end

  defp log_accumulator_extras(log, run, total, acc) do
    case acc.refusal do
      nil -> :ok
      refusal -> log_line(log, "[#{format_ts()}] run=#{run}/#{total} kind=refusal text=#{quote_for_log(refusal)}")
    end

    case Map.get(acc, :tool_calls, %{}) do
      tools when map_size(tools) > 0 ->
        log_line(log, "[#{format_ts()}] run=#{run}/#{total} kind=tool_calls count=#{map_size(tools)}")

      _ ->
        :ok
    end
  end

  # Single-quote the text and escape embedded quotes/newlines
  # so each event line stays one line. Big text blocks (>4 KB)
  # get truncated to keep the log readable.
  defp quote_for_log(text) when is_binary(text) do
    capped = if byte_size(text) > 4096, do: String.slice(text, 0, 4096) <> "...(truncated)", else: text

    capped
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
    |> then(&"\"#{&1}\"")
  end

  ## --- aggregate summary ----------------------------------------

  defp write_aggregate(log, label, results) do
    log_section(log, "[#{label}] aggregate (#{length(results)} runs)")

    counts = Enum.reduce(results, %{"ok" => 0, "empty" => 0, "error" => 0}, fn
      {:ok, _, _}, acc -> Map.update!(acc, "ok", &(&1 + 1))
      {:empty, _}, acc -> Map.update!(acc, "empty", &(&1 + 1))
      {:error, _, _}, acc -> Map.update!(acc, "error", &(&1 + 1))
      _, acc -> acc
    end)

    log_line(log, "[#{format_ts()}] kind=aggregate_result result_distribution=ok:#{counts["ok"]}/empty:#{counts["empty"]}/error:#{counts["error"]}")

    Enum.each(results, fn result -> log_run_summary_line(log, label, result) end)

    histogram(log, label, results, fn summary -> summary.stop_reason end, "finish_reason")
    histogram(log, label, results, fn summary -> summary[:output_tokens] || "?" end, "output_tokens")
    histogram(log, label, results, fn summary -> summary.elapsed_ms end, "elapsed_ms")
  end

  defp histogram(log, label, results, accessor, kind) do
    values = Enum.map(results, &access_summary/1) |> Enum.map(accessor)

    grouped = Enum.frequencies_by(values, & &1)
    pairs = Enum.map_join(grouped, " ", fn {k, v} -> "#{inspect(k)}=#{v}" end)

    log_line(log, "[#{format_ts()}] kind=#{kind}_histogram[#{label}] #{pairs}")
  end

  defp access_summary({:ok, _, summary}), do: summary
  defp access_summary({:empty, summary}), do: summary
  defp access_summary({:error, _, summary}), do: summary

  defp log_run_summary_line(log, label, {:ok, text, summary}) do
    log_line(log, "[#{format_ts()}] kind=run_line[#{label}] result=ok text_chars=#{summary.text_chars} elapsed_ms=#{summary.elapsed_ms}")
  end

  defp log_run_summary_line(log, label, {:empty, summary}) do
    log_line(log, "[#{format_ts()}] kind=run_line[#{label}] result=empty text_chars=#{summary.text_chars} elapsed_ms=#{summary.elapsed_ms} stop_reason=#{inspect(summary.stop_reason)}")
  end

  defp log_run_summary_line(log, label, {:error, reason, summary}) do
    log_line(log, "[#{format_ts()}] kind=run_line[#{label}] result=error reason=#{inspect(reason)} elapsed_ms=#{summary.elapsed_ms}")
  end

  ## --- console aggregation --------------------------------------

  defp summarize_console(label, results) do
    counts = Enum.reduce(results, %{ok: 0, empty: 0, error: 0}, fn
      {:ok, _, _}, acc -> %{acc | ok: acc.ok + 1}
      {:empty, _}, acc -> %{acc | empty: acc.empty + 1}
      {:error, _, _}, acc -> %{acc | error: acc.error + 1}
      _, acc -> acc
    end)

    Logger.info("""

    Probe summary (#{label})
    ────────────────────────
    runs:      #{length(results)}
    ok:        #{counts.ok}
    empty:     #{counts.empty}
    errors:    #{counts.error}
    """)
  end

  ## --- helpers --------------------------------------------------

  defp truncate(text, n) when byte_size(text) <= n, do: text
  defp truncate(text, n), do: String.slice(text, 0, n) <> "...(truncated)"

  # ISO-8601 with millisecond precision. Built by hand because
  # `DateTime.to_iso8601/2` doesn't accept `:millisecond` as a
  # format (it expects `:extended` or `:basic`).
  defp format_ts do
    %DateTime{microsecond: {us, _}} = dt = DateTime.utc_now()

    base = Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%S")
    ms = us |> Integer.to_string() |> String.pad_leading(3, "0")

    "#{base}.#{ms}Z"
  end

  defp usage do
    """

    usage: mix run scripts/compaction_probe.exs <agent_name>
                                  [--pass=head|tail|full]
                                  [--repeat=N]
                                  [--snapshot=FILE]
                                  [--replay=FILE]
                                  [--verbose]

    Reads the agent's active messages from the DB (or from a
    snapshot via --replay) and replays the compactor's
    summarization call against the configured LLM. Always
    writes a full event log to /tmp; nothing is committed to
    the database.

    """
  end
end

Nest.Scripts.CompactionProbe.run(System.argv())