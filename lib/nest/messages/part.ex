defmodule Nest.Messages.Part do
  @moduledoc """
  A part of a chat message. Messages (system, user, assistant, tool)
  carry a `:parts` list of `t()` structs, in the order they were
  produced or received. The runtime shape matches the persisted
  jsonb `content.parts` shape so there is no translation layer
  between the live `state.chat_state.messages` list and the rows
  in the `messages` table.

  ## Kinds

  Five part kinds, one struct each:

    * `Text` — visible text content. Used by every role.
    * `Thinking` — reasoning / chain-of-thought text. Carries an
      optional `signature` (Anthropic's extended-thinking signature
      that must be echoed back on subsequent turns).
    * `ToolUse` — a tool call the assistant is requesting. Carries
      the call's `id`, the tool `name`, and the parsed `arguments`.
    * `ToolResult` — the result of a tool call. Carries the
      `tool_call_id` (matches the `ToolUse.id`), the tool `name`,
      the `content` (string), and `is_error`.
    * `Refusal` — the assistant refusing to comply. Carries the
      `refusal` text.

  No `IsError`/arg name mismatch: the spec uses `is_error` (snake
  case) for the wire format / Ecto field. The struct field is
  `:is_error` and the wire key is `isError` (see `to_json/1`).

  The wire format used by the `to_json/1` callbacks matches the
  persisted jsonb shape; the persisted keys are the camelCase form
  (e.g. `"toolCallId"`, `"isError"`) and the `arguments` map uses
  string keys (matching the JSON decode on read).
  """

  defmodule Text do
    @moduledoc "Visible text content."
    defstruct [:text]
    @type t :: %__MODULE__{text: String.t()}
  end

  defmodule Thinking do
    @moduledoc """
    Reasoning / chain-of-thought text. The optional `signature` is
    Anthropic's extended-thinking signature that must be echoed
    back on subsequent turns so the model can verify the prior
    reasoning block. `nil` for providers that don't emit one
    (OpenAI reasoning models emit `thinking` text only).
    """
    defstruct [:thinking, :signature]

    @type t :: %__MODULE__{
            thinking: String.t(),
            signature: String.t() | nil
          }
  end

  defmodule ToolUse do
    @moduledoc """
    A tool call the assistant is requesting. `id` matches the
    `tool_call_id` on the `ToolResult` part that responds to it.
    """
    defstruct [:id, :name, :arguments]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            arguments: map()
          }
  end

  defmodule ToolResult do
    @moduledoc """
    The result of a tool call. `tool_call_id` matches the `id` on
    the `ToolUse` part that triggered the call. `is_error` is true
    when the tool execution failed (the LLM should treat the
    `content` as an error message and retry or fall back).
    """
    defstruct [:tool_call_id, :name, :content, :arguments, :is_error]

    @type t :: %__MODULE__{
            tool_call_id: String.t(),
            name: String.t(),
            content: String.t(),
            arguments: map() | nil,
            is_error: boolean()
          }
  end

  defmodule Refusal do
    @moduledoc "Assistant refusal text."
    defstruct [:refusal]
    @type t :: %__MODULE__{refusal: String.t()}
  end

  @type kind :: :text | :thinking | :tool_use | :tool_result | :refusal

  @type t ::
          Text.t()
          | Thinking.t()
          | ToolUse.t()
          | ToolResult.t()
          | Refusal.t()

  @doc """
  The discriminator atom for the given part. Used by
  `to_json/1` to emit the wire `"kind"` key and by consumers that
  pattern-match on a part's role (e.g. UI renderers).
  """
  @spec kind(t()) :: kind()
  def kind(%Text{}), do: :text
  def kind(%Thinking{}), do: :thinking
  def kind(%ToolUse{}), do: :tool_use
  def kind(%ToolResult{}), do: :tool_result
  def kind(%Refusal{}), do: :refusal

  @doc """
  Convert a part to a JSON-compatible map (atom keys, suitable for
  Jason encoding and for the persisted jsonb `content.parts[*]`
  shape).

  The `arguments` field on `ToolUse` keeps atom keys; callers
  encoding to wire JSON should `Jason.encode!/1` the surrounding
  map and the arguments become a JSON object with atom keys, which
  Postgres jsonb stores as text. On read, `from_json/1` decodes
  the JSON and the arguments are re-keyed to atoms. This avoids
  string-key drift between the in-memory struct and the persisted
  shape.
  """
  @spec to_json(t()) :: map()
  def to_json(%Text{text: text}), do: %{"kind" => "text", "text" => text}

  def to_json(%Thinking{thinking: text, signature: signature}),
    do: %{"kind" => "thinking", "thinking" => text, "signature" => signature}

  def to_json(%ToolUse{id: id, name: name, arguments: arguments}),
    do: %{"kind" => "tool_use", "id" => id, "name" => name, "arguments" => arguments}

  def to_json(%ToolResult{} = r),
    do: %{
      "kind" => "tool_result",
      "toolCallId" => r.tool_call_id,
      "name" => r.name,
      "content" => r.content,
      "arguments" => r.arguments,
      "isError" => r.is_error || false
    }

  def to_json(%Refusal{refusal: refusal}),
    do: %{"kind" => "refusal", "refusal" => refusal}

  @doc """
  Build a part struct from a JSON-compatible map (the shape
  produced by `to_json/1` and the shape stored in jsonb).
  Returns `nil` for unknown kinds so a corrupt row doesn't
  crash the restore path.
  """
  @spec from_json(map()) :: t() | nil
  def from_json(%{"kind" => "text", "text" => text}),
    do: %Text{text: text}

  def from_json(%{"kind" => "thinking", "thinking" => text} = map),
    do: %Thinking{thinking: text, signature: map["signature"]}

  def from_json(%{"kind" => "tool_use", "id" => id, "name" => name, "arguments" => args})
      when is_map(args),
      do: %ToolUse{id: id, name: name, arguments: args}

  def from_json(%{"kind" => "tool_result"} = map),
    do: %ToolResult{
      tool_call_id: map["toolCallId"],
      name: map["name"],
      content: map["content"],
      arguments: map["arguments"],
      is_error: map["isError"] || false
    }

  def from_json(%{"kind" => "refusal", "refusal" => refusal}),
    do: %Refusal{refusal: refusal}

  def from_json(_), do: nil
end
