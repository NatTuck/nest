defmodule Nest.Persistence.AgentCompaction.Summarizer do
  @moduledoc """
  Bounded, iterative summarizer for the offline agent compaction tool.

  Unlike `Nest.Tokens.Compactor` (single-pass, and it refuses when the
  history does not fit the context window), this module folds an
  arbitrarily large history down in chunks:

      running = ""
      for chunk <- chunks, do: running = llm(system ‖ running ‖ chunk)

  Each call's input is `system + running + chunk`, bounded by the
  planner's `chunk_budget` (which reserves room for the running
  summary). After the last chunk the summary is verified against
  `summary_budget`; if the model overshot, one or two bounded compress
  calls bring it back under budget.

  The `llm_call` is injected (`[Message.t()] -> {:ok, text} | {:error,
  reason}`) so the fold is unit-testable without HTTP. Production
  builds it with `llm_call/1`, which uses the generic LLM client
  plumbing directly — no live agent/compaction modules are involved.
  """

  alias Nest.LLM.ClientConfig
  alias Nest.LLM.Runner
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Message
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Persistence.AgentCompaction.Planner
  alias Nest.Tokens.Estimator

  @type llm_call :: ([Message.t()] -> {:ok, String.t()} | {:error, term()})

  @max_compress_passes 2

  @doc """
  Summarize `plan.chunks` into one summary string bounded by
  `plan.summary_budget`. Returns `{:ok, summary}` or `{:error, reason}`.
  """
  @spec summarize(Planner.t(), llm_call(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def summarize(%Planner{} = plan, llm_call, _opts \\ []) when is_function(llm_call, 1) do
    plan
    |> fold(llm_call, plan.chunks, "")
    |> case do
      {:ok, summary} -> finalize(plan, summary, llm_call)
      other -> other
    end
  end

  @doc """
  Build the production `llm_call/1` for a `ClientConfig`.
  """
  @spec llm_call(ClientConfig.t()) :: llm_call()
  def llm_call(%ClientConfig{} = config) do
    fn messages ->
      request = %RunRequest{
        messages: messages,
        tools: nil,
        tool_choice: :none,
        model: config.model,
        thinking_effort: config.thinking_effort,
        stream: true,
        metadata: %{}
      }

      opts = [
        base_url: config.base_url,
        api_key: config.api_key,
        receive_timeout: config.receive_timeout
      ]

      case config.client.run(request, opts) do
        {:ok, stream} -> consume_quietly(stream)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # --- fold ---

  defp fold(plan, llm_call, chunks, running) do
    Enum.reduce_while(chunks, {:ok, running}, fn chunk, {:ok, running} ->
      case call(llm_call, request(plan, running, chunk)) do
        {:ok, text} -> {:cont, {:ok, text}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp request(plan, running, chunk) do
    system = %System{
      index: 0,
      parts: [%Part.Text{text: plan.system_text <> "\n\n" <> instruction(plan, running)}],
      timestamp: DateTime.utc_now(),
      api_logs: []
    }

    [{:system, system} | renumber(chunk, 1)]
  end

  defp instruction(plan, "") do
    focus(
      plan,
      "[mode: compact] Summarize the conversation that follows in at most " <>
        "#{plan.summary_budget} tokens."
    )
  end

  defp instruction(plan, running) do
    focus(
      plan,
      "[mode: compact] A running summary of the earlier conversation is provided " <>
        "below. Incorporate the conversation that follows into it, keeping the whole " <>
        "summary to at most #{plan.summary_budget} tokens.\n\n" <>
        "<running_summary>\n" <> running <> "\n</running_summary>"
    )
  end

  defp focus(%Planner{focus: nil}, text), do: text
  defp focus(%Planner{focus: ""}, text), do: text
  defp focus(%Planner{focus: focus}, text), do: text <> " " <> focus

  # --- final size guard ---

  defp finalize(plan, summary, llm_call) do
    if Estimator.estimate(summary) <= plan.summary_budget do
      {:ok, summary}
    else
      compress(plan, summary, llm_call, 1)
    end
  end

  defp compress(_plan, _summary, _llm_call, pass) when pass > @max_compress_passes do
    {:error, :summary_too_large}
  end

  defp compress(plan, summary, llm_call, pass) do
    case call(llm_call, compress_request(plan, summary)) do
      {:ok, text} ->
        if Estimator.estimate(text) <= plan.summary_budget do
          {:ok, text}
        else
          compress(plan, text, llm_call, pass + 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compress_request(plan, summary) do
    system = %System{
      index: 0,
      parts: [%Part.Text{text: plan.system_text}],
      timestamp: DateTime.utc_now(),
      api_logs: []
    }

    user = %User{
      index: 1,
      parts: [
        %Part.Text{
          text:
            "[mode: compact] Compress the following summary to at most " <>
              "#{plan.summary_budget} tokens, preserving every key fact.\n\n" <> summary
        }
      ],
      timestamp: DateTime.utc_now(),
      api_logs: []
    }

    [{:system, system}, {:user, user}]
  end

  # --- shared call wrapper ---

  defp call(llm_call, messages) do
    case llm_call.(messages) do
      {:ok, text} when is_binary(text) ->
        case String.trim(text) do
          "" -> {:error, :llm_returned_empty}
          trimmed -> {:ok, trimmed}
        end

      {:ok, nil} ->
        {:error, :llm_returned_empty}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:bad_llm_response, other}}
    end
  end

  # Consume without broadcasting. `Runner.consume/2` normalizes the
  # accumulator into the final response (a client whose `:done` event
  # omits the streamed text still yields it here), which is exactly
  # what the live runner does.
  defp consume_quietly(stream) do
    callbacks = %{
      on_text: fn _text, sent -> sent end,
      on_thinking: fn _text, sent -> sent end,
      on_signature: fn _sig -> :ok end
    }

    case Runner.consume(stream, callbacks) do
      {:ok, %RunResponse{text: text}} -> {:ok, text || ""}
      {:ok, nil} -> {:error, :no_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp renumber(messages, start) do
    {result, _} =
      Enum.map_reduce(messages, start, fn {role, struct}, idx ->
        {{role, %{struct | index: idx}}, idx + 1}
      end)

    result
  end
end
