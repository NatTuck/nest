 Here's a complete schema set in Elixir that covers everything discussed:

```elixir
defmodule LLM.Schema do
  @moduledoc """
  Canonical schemas for LLM API interactions.
  OpenAI-inspired normalized form with provider-agnostic streaming.
  """

  # ─── Roles ─────────────────────────────────────────────────────────

  defmodule Role do
    @type t :: :system | :developer | :user | :assistant | :tool
  end

  # ─── Content Blocks ──────────────────────────────────────────────

  defmodule ContentBlock do
    @type t ::
        {:text, String.t()}
      | {:thinking, keyword()}
      | {:tool_use, keyword()}
      | {:tool_result, keyword()}

    def text(content), do: {:text, content}

    def thinking(text, opts \\ []) do
      {:thinking, text: text, signature: opts[:signature]}
    end

    def tool_use(id, name, arguments) do
      {:tool_use, id: id, name: name, arguments: arguments}
    end

    def tool_result(tool_use_id, content, opts \\ []) do
      {:tool_result,
        tool_use_id: tool_use_id,
        content: content,
        is_error: Keyword.get(opts, :is_error, false)
      }
    end
  end

  # ─── Messages ────────────────────────────────────────────────────

  defmodule Message do
    @type t :: %__MODULE__{
      role: Role.t(),
      content: [ContentBlock.t()],
      metadata: map() | nil
    }

    defstruct [:role, :content, :metadata]

    def new(role, content, opts \\ []) do
      %__MODULE__{
        role: role,
        content: List.wrap(content),
        metadata: opts[:metadata]
      }
    end
  end

  # ─── Tool Definitions ────────────────────────────────────────────

  defmodule ToolDefinition do
    @type t :: %__MODULE__{
      name: String.t(),
      description: String.t(),
      parameters: map(),  # JSON Schema
      strict: boolean()
    }

    defstruct [:name, :description, :parameters, strict: false]
  end

  defmodule ToolChoice do
    @type t :: :auto | :none | :required | {:tool, String.t()}
  end

  # ─── Request ───────────────────────────────────────────────────────

  defmodule ChatRequest do
    @type t :: %__MODULE__{
      messages: [Message.t()],
      tools: [ToolDefinition.t()],
      tool_choice: ToolChoice.t(),
      model: String.t() | nil,
      temperature: float() | nil,
      max_tokens: integer() | nil,
      top_p: float() | nil,
      stream: boolean(),
      metadata: map() | nil
    }

    defstruct [
      :messages, :tools, :tool_choice, :model,
      :temperature, :max_tokens, :top_p,
      stream: false,
      metadata: nil
    ]
  end

  # ─── Streaming Events ──────────────────────────────────────────────

  defmodule StreamEvent do
    @type t ::
        {:text_delta, String.t()}
      | {:thinking_delta, keyword()}
      | {:tool_call_start, keyword()}
      | {:tool_call_delta, keyword()}
      | {:tool_call_end, String.t()}
      | {:refusal, String.t()}
      | {:finish, keyword()}
      | {:error, term()}
      | {:ping}  # keepalive

    def text_delta(text), do: {:text_delta, text}

    def thinking_delta(text, opts \\ []) do
      {:thinking_delta, text: text, signature: opts[:signature]}
    end

    def tool_call_start(call_id, name) do
      {:tool_call_start, call_id: call_id, name: name}
    end

    def tool_call_delta(call_id, fragment) do
      {:tool_call_delta, call_id: call_id, argument_fragment: fragment}
    end

    def tool_call_end(call_id), do: {:tool_call_end, call_id}

    def refusal(reason), do: {:refusal, reason}

    def finish(opts \\ []) do
      {:finish,
        reason: opts[:reason] || :stop,
        usage: opts[:usage],
        model: opts[:model]
      }
    end
  end

  # ─── Response (Non-streaming) ────────────────────────────────────

  defmodule ChatResponse do
    @type t :: %__MODULE__{
      message: Message.t(),
      usage: Usage.t() | nil,
      model: String.t() | nil,
      finish_reason: atom(),
      metadata: map() | nil
    }

    defstruct [:message, :usage, :model, :finish_reason, :metadata]
  end

  defmodule Usage do
    @type t :: %__MODULE__{
      prompt_tokens: integer(),
      completion_tokens: integer(),
      total_tokens: integer(),
      reasoning_tokens: integer() | nil
    }

    defstruct [:prompt_tokens, :completion_tokens, :total_tokens, :reasoning_tokens]
  end

  # ─── Wire Preservation ─────────────────────────────────────────────

  defmodule WireFrame do
    @type t :: %__MODULE__{
      provider: atom(),
      direction: :in | :out,
      timestamp: DateTime.t(),
      raw: String.t() | map(),
      normalized: StreamEvent.t() | Message.t() | nil,
      parse_error: term() | nil
    }

    defstruct [:provider, :direction, :timestamp, :raw, :normalized, :parse_error]
  end

  # ─── Accumulator State (Streaming) ────────────────────────────────

  defmodule StreamState do
    @moduledoc """
    Accumulator for reconstructing partial tool calls and interleaved content.
    """
    @type t :: %__MODULE__{
      message: Message.t(),
      tool_calls: %{String.t() => PartialToolCall.t()},
      buffer: String.t(),           # SSE buffer
      wire_log: [WireFrame.t()]
    }

    defstruct [
      message: %Message{role: :assistant, content: []},
      tool_calls: %{},
      buffer: "",
      wire_log: []
    ]
  end

  defmodule PartialToolCall do
    @type t :: %__MODULE__{
      id: String.t() | nil,
      name: String.t() | nil,
      arguments_buffer: String.t(),
      complete?: boolean()
    }

    defstruct [id: nil, name: nil, arguments_buffer: "", complete?: false]
  end

  # ─── Provider Behavior ─────────────────────────────────────────────

  defmodule Provider do
    @callback stream(request :: ChatRequest.t(), opts :: keyword()) ::
      Enumerable.t(StreamEvent.t())

    @callback complete(request :: ChatRequest.t(), opts :: keyword()) ::
      {:ok, ChatResponse.t()} | {:error, term()}

    @callback normalize_event(raw :: map(), provider :: atom()) ::
      {:ok, StreamEvent.t()} | {:error, term()}

    @callback to_native_request(ChatRequest.t()) :: map()
    @callback from_native_response(map()) :: ChatResponse.t()
  end
end
```

**Usage examples:**

```elixir
# Build a conversation
sys = Message.new(:system, ContentBlock.text("You are a helpful assistant."))
user = Message.new(:user, ContentBlock.text("What's the weather in NYC?"))

# Tool definition
weather_tool = %ToolDefinition{
  name: "get_weather",
  description: "Get current weather for a location",
  parameters: %{
    type: "object",
    properties: %{
      location: %{type: "string", description: "City name"}
    },
    required: ["location"]
  }
}

# Streaming request
req = %ChatRequest{
  messages: [sys, user],
  tools: [weather_tool],
  tool_choice: :auto,
  stream: true
}

# Consume stream
LLM.Provider.OpenAI.stream(req)
|> Enum.reduce(%StreamState{}, fn event, state ->
  case event do
    {:text_delta, text} ->
      IO.write(text)
      state

    {:tool_call_start, call_id: id, name: name} ->
      IO.puts("\n[Tool call: #{name}]")
      put_in(state.tool_calls[id], %PartialToolCall{id: id, name: name})

    {:tool_call_delta, call_id: id, argument_fragment: frag} ->
      update_in(state.tool_calls[id].arguments_buffer, &(&1 <> frag))

    {:tool_call_end, call_id: id} ->
      tool = state.tool_calls[id]
      args = Jason.decode!(tool.arguments_buffer)
      # Execute tool, create tool_result message
      state

    {:finish, reason: reason} ->
      IO.puts("\n[Done: #{reason}]")
      state
  end
end)
```

**Key design decisions:**

- **Tagged tuples over structs for variants** — pattern matching is cleaner in Elixir, and you avoid a proliferation of tiny struct modules
- **`StreamState` tracks partial tool calls by ID** — handles parallel tool calls and interleaved text
- **`WireFrame` preserves raw bytes before normalization** — your debug/replay requirement
- **Separate `stream/2` and `complete/2` on provider** — some endpoints have different URLs or behaviors for streaming vs. non-streaming
- **`thinking` as a content block, not a message role** — reasoning is assistant output, not a separate speaker

  You're right — it's a schema smell. `Message` shouldn't be a grab bag where a `:user` message could theoretically carry `{:thinking, ...}` or `{:tool_use, ...}`. That's legal in your struct but semantically invalid.

Better to let the **role constrain the content** at the type level. In Elixir, that means separate structs or enforced validation:

```elixir
defmodule LLM.Message.System do
  defstruct [:content, :metadata]  # content is String.t() only
end

defmodule LLM.Message.User do
  defstruct [:content, :metadata]    # content is String.t() or [image, text, ...]
end

defmodule LLM.Message.Assistant do
  defstruct [:content, :thinking, :tool_calls, :refusal, :metadata]
  # content: String.t() | nil
  # thinking: String.t() | nil
  # tool_calls: [ToolCall.t()] | nil
  # refusal: String.t() | nil
end

defmodule LLM.Message.Tool do
  defstruct [:tool_use_id, :content, :is_error, :metadata]
end
```

Then your `Message` is a tagged tuple:

```elixir
{:system, %Message.System{...}} 
{:user, %Message.User{...}}
{:assistant, %Message.Assistant{...}}
{:tool, %Message.Tool{...}}
```

This makes invalid states unrepresentable. A `:user` message simply has no `thinking` field to misuse.

For the **request pipeline**, you'd normalize provider-specific formats into these structs, then serialize back out. Your `ChatRequest` becomes:

```elixir
%ChatRequest{
  messages: [
    {:system, %Message.System{content: "You are helpful."}},
    {:user, %Message.User{content: "What's the weather?"}},
    {:assistant, %Message.Assistant{
      content: nil,
      thinking: nil,
      tool_calls: [%ToolCall{id: "call_1", name: "weather", arguments: %{"city" => "NYC"}}],
      refusal: nil
    }},
    {:tool, %Message.Tool{tool_use_id: "call_1", content: "{\"temp\": 72}", is_error: false}},
    {:assistant, %Message.Assistant{
      content: "It's 72°F in NYC.",
      thinking: nil,
      tool_calls: nil,
      refusal: nil
    }}
  ]
}
```

For **streaming accumulation**, you'd build an `AssistantAccumulator` that only produces `%Message.Assistant{}` when the stream finishes:

```elixir
defmodule AssistantAccumulator do
  defstruct [
    text_buffer: "",
    thinking_buffer: "",
    thinking_signature: nil,
    tool_calls: %{},        # %{call_id => PartialToolCall}
    refusal: nil,
    current_block: nil       # :text | :thinking | {:tool_use, id} | nil
  ]

  def finalize(%__MODULE__{} = acc) do
    %Message.Assistant{
      content: if(acc.text_buffer == "", do: nil, else: acc.text_buffer),
      thinking: if(acc.thinking_buffer == "", do: nil, else: acc.thinking_buffer),
      tool_calls: finalize_tool_calls(acc.tool_calls),
      refusal: acc.refusal
    }
  end
end
```

This is cleaner than my first pass. The cost is more structs and conversion functions, but the win is that your application logic can pattern match on `{:assistant, %Message.Assistant{tool_calls: [_ | _]}}` and know exactly what it's getting.
