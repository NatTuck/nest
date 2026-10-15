defmodule Nest.Messages.Part do
  @moduledoc """
  A part of a chat message. Messages (system, user, assistant, tool)
  carry a `:parts` list of `t()` structs, in the order they were
  produced or received. The runtime shape matches the persisted
  jsonb `content.parts` shape so there is no translation layer
  between the live `state.chat_state.messages` list and the rows
  in the `messages` table.

  ## Kinds

  Six part kinds, one struct each:

    * `Text` — visible text content. Used by every role.
    * `Thinking` — reasoning / chain-of-thought text. Carries an
      optional `signature` (Anthropic's extended-thinking signature
      that must be echoed back on subsequent turns).
    * `ToolUse` — a tool call the assistant is requesting. Carries
      the call's `id`, the tool `name`, and the parsed `arguments`.
    * `ToolResult` — the result of a tool call. Carries the
      `tool_call_id` (matches the `ToolUse.id`), the tool `name`,
      the `content` (string), and `is_error`. The optional `state`
      says something `is_error` cannot: a call the machine moved to
      the background (issue #36) has no result yet, so it is neither
      a success nor a failure, and the panel badges it as what it is
      rather than inventing a verdict. `nil` is an ordinary finished
      result and `"backgrounded"` is the one value written today; the
      panel renders an unrecognised value as such instead of falling
      back to a success/failure badge.
    * `Refusal` — the assistant refusing to comply. Carries the
      `refusal` text.
    * `Media` — binary media (an image today) a tool returned, as a
      sibling of the `ToolResult` it answers. Carries the base64
      `data`, the DECODED `bytes`, the `media_type`, the sandbox
      `path` the agent asked for, and the `tool_call_id` that ties it
      to its result.

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

    `state` is the wire's own word for a result that is not a
    verdict at all: `"backgrounded"` is the machine's synthetic
    answer to a call it moved to the background (issue #36), and
    `"waiting"` is a wait tool's answer for a call that registered
    a watch (`agents-wait`/`shell-wait`, issue #54). Both mean the
    same thing to a reader — the call's real result has not
    arrived and will arrive later as a message — and the panel
    badges both rather than reading either as a verdict. It is
    `nil` for a result a tool produced, and the value is kept
    verbatim — a value this version does not know is the panel's
    to render explicitly, not this module's to map away.
    """
    defstruct [:tool_call_id, :name, :content, :arguments, :is_error, :state]

    @type t :: %__MODULE__{
            tool_call_id: String.t(),
            name: String.t(),
            content: String.t(),
            arguments: map() | nil,
            is_error: boolean(),
            state: String.t() | nil
          }
  end

  defmodule Refusal do
    @moduledoc "Assistant refusal text."
    defstruct [:refusal]
    @type t :: %__MODULE__{refusal: String.t()}
  end

  defmodule Media do
    @moduledoc """
    Binary media a tool returned, attached to the `ToolResult` it
    answers as a sibling part in the same `{:tool, _}` message.

    `data` is base64 with **no** `data:` prefix — each provider
    encoder adds its own framing. `bytes` is the DECODED byte count,
    so it describes the file rather than the encoding, and it is what
    the UI shows. `path` is the sandbox spelling of the file the
    agent asked for, and it is the one optional key: omitted from the
    wire when `nil`, so the persisted shape of every other row is
    unchanged (the same mechanism `ToolResult.state` uses).

    `tool_call_id` ties the media to its result, and the two
    providers need it for different reasons. Anthropic's
    `tool_result` block accepts image content, so the image folds
    *into* that block; OpenAI's `role: "tool"` message accepts text
    parts only, so the image is hoisted into a following user
    message. Both need to know which call it belongs to.

    Build one with `Nest.Messages.Part.new_media/1` and nothing else.

    ## Restoring a row this build cannot interpret

    `new_media/1` accepts only the modalities this build can produce, but a
    *stored* row may name one written by a build with a wider vocabulary.
    That is not a malformed row — it is data from a build we are not — so
    `from_json/1` preserves it and carries the name through as the string it
    holds. Dropping it would make a message silently lose an attachment on
    restore, which is exactly what the transparency rule forbids. The panel
    renders an unrecognised modality with an explicit indicator, and an
    encoder that cannot send it says so on the wire rather than crashing the
    turn or dropping it quietly.
    """
    defstruct [:tool_call_id, :modality, :media_type, :data, :bytes, :path]

    @type modality :: :image

    # What a restored `modality` field may hold: the atom this build uses for
    # one it knows, or the raw name for one it does not.
    @type stored_modality :: modality() | String.t()

    @type t :: %__MODULE__{
            tool_call_id: String.t(),
            modality: stored_modality(),
            media_type: String.t(),
            data: String.t(),
            bytes: non_neg_integer(),
            path: String.t() | nil
          }
  end

  @type kind :: :text | :thinking | :tool_use | :tool_result | :refusal | :media

  @type t ::
          Text.t()
          | Thinking.t()
          | ToolUse.t()
          | ToolResult.t()
          | Refusal.t()
          | Media.t()

  # The media modalities this build can produce, encode and price.
  #
  # Deliberately one entry. `Nest.LLM.Discover` normalizes every
  # provider's declared input modalities to `"image"` and states that
  # image is the only modality in our vocabulary, so an `:audio` or
  # `:video` entry here would be a value nothing can produce — and the
  # OpenAI wire has no video content part at all. Grow this list only
  # when a detector *and* an encoder both exist for the new modality.
  #
  # `Nest.Tokens.Estimator`'s per-modality pricing ceiling is keyed by
  # the same vocabulary, and a test asserts the two lists are equal, so
  # they cannot drift.
  @modalities [:image]

  # Stored modalities are decoded through this explicit map, never
  # `String.to_atom/1` — the input is a jsonb column, which is exactly
  # the untrusted input that rule exists for.
  @modality_names %{"image" => :image}

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
  def kind(%Media{}), do: :media

  @doc "True for a `Media` part, false for every other part."
  @spec media?(t() | term()) :: boolean()
  def media?(%Media{}), do: true
  def media?(_), do: false

  @doc """
  The media modalities this build can build, encode and price.

  Exposed so a test can assert it equals
  `Nest.Tokens.Estimator.media_token_ceilings/0`'s key set — the two must
  not drift, or a buildable part would be unpriceable.
  """
  @spec modalities() :: [Media.modality()]
  def modalities, do: @modalities

  @doc """
  Build and validate a `Media` part from atom-keyed attributes.

  This is the only place a media part is constructed. Keeping it
  single is what stops the modality vocabulary here from drifting
  away from `Nest.Tokens.Estimator`'s pricing ceiling — a modality
  that could be built but not priced would raise inside the sizing
  path.

  Validates, in order: the modality is one this build can encode, the
  `media_type` is a string whose type prefix matches the modality,
  `bytes` is a positive integer, `data` is base64 that decodes to
  exactly `bytes`, and `tool_call_id` is a non-empty string.

  Returns `{:error, message}` rather than raising: the caller is a
  tool, and a rejected attachment has to reach the model as an
  ordinary tool result it can act on.
  """
  @spec new_media(map()) :: {:ok, Media.t()} | {:error, String.t()}
  def new_media(attrs) when is_map(attrs) do
    with {:ok, shape} <- check_shape(attrs),
         {:ok, payload} <- check_payload(attrs) do
      {:ok, build_media(attrs, Map.merge(shape, payload))}
    end
  end

  def new_media(other), do: {:error, "media attributes must be a map, got #{inspect(other)}"}

  # The three fields that say what the part *is*.
  defp check_shape(attrs) do
    with {:ok, modality} <- check_modality(attrs[:modality]),
         {:ok, media_type} <- check_media_type(attrs[:media_type], modality),
         {:ok, tool_call_id} <- check_tool_call_id(attrs[:tool_call_id]) do
      {:ok, %{modality: modality, media_type: media_type, tool_call_id: tool_call_id}}
    end
  end

  # The two fields that carry the bytes. `bytes` is checked first because `data`
  # is validated against it.
  defp check_payload(attrs) do
    with {:ok, bytes} <- check_bytes(attrs[:bytes]),
         {:ok, data} <- check_data(attrs[:data], bytes) do
      {:ok, %{bytes: bytes, data: data}}
    end
  end

  defp build_media(attrs, fields) do
    struct!(Media, Map.put(fields, :path, attrs[:path]))
  end

  defp check_modality(modality) when modality in @modalities, do: {:ok, modality}

  defp check_modality(other),
    do: {:error, "media modality #{inspect(other)} is not one of #{inspect(@modalities)}"}

  defp check_media_type(type, modality) when is_binary(type) do
    if String.starts_with?(type, "#{modality}/") do
      {:ok, type}
    else
      {:error, "media type #{inspect(type)} does not match modality #{modality}"}
    end
  end

  defp check_media_type(other, _modality),
    do: {:error, "media type must be a string, got #{inspect(other)}"}

  defp check_bytes(bytes) when is_integer(bytes) and bytes > 0, do: {:ok, bytes}

  defp check_bytes(other),
    do: {:error, "media byte count must be a positive integer, got #{inspect(other)}"}

  defp check_data(data, bytes) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, decoded} when byte_size(decoded) == bytes ->
        {:ok, data}

      {:ok, decoded} ->
        {:error, "media data decodes to #{byte_size(decoded)} bytes, not the declared #{bytes}"}

      :error ->
        {:error, "media data is not valid base64"}
    end
  end

  defp check_data(other, _bytes),
    do: {:error, "media data must be a string, got #{inspect(other)}"}

  defp check_tool_call_id(id) when is_binary(id) and id != "", do: {:ok, id}

  defp check_tool_call_id(other),
    do: {:error, "media tool call id must be a non-empty string, got #{inspect(other)}"}

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

  def to_json(%ToolResult{} = r) do
    %{
      "kind" => "tool_result",
      "toolCallId" => r.tool_call_id,
      "name" => r.name,
      "content" => r.content,
      "arguments" => r.arguments,
      "isError" => r.is_error || false
    }
    |> maybe_put_optional("state", r.state)
  end

  def to_json(%Refusal{refusal: refusal}),
    do: %{"kind" => "refusal", "refusal" => refusal}

  def to_json(%Media{} = m) do
    %{
      "kind" => "media",
      "toolCallId" => m.tool_call_id,
      "modality" => modality_name(m.modality),
      "mediaType" => m.media_type,
      "bytes" => m.bytes,
      "data" => m.data
    }
    |> maybe_put_optional("path", m.path)
  end

  # A modality this build produced is an atom; one it restored from a row it
  # could not interpret is already the string that row held.
  defp modality_name(modality) when is_atom(modality), do: Atom.to_string(modality)
  defp modality_name(modality), do: modality

  # A key that is absent and a key whose value is `nil` are the same thing to
  # every reader of this shape, so the key is omitted rather than written as
  # null. That keeps the persisted bytes of every part that carries no such
  # value exactly as they were: `ToolResult.state` (#57) and `Media.path`.
  defp maybe_put_optional(map, _key, nil), do: map
  defp maybe_put_optional(map, key, value), do: Map.put(map, key, value)

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
      is_error: map["isError"] || false,
      state: map["state"]
    }

  def from_json(%{"kind" => "refusal", "refusal" => refusal}),
    do: %Refusal{refusal: refusal}

  # Two different cases, deliberately handled differently:
  #
  #   * A row this build cannot *interpret* — a modality name it does not know,
  #     written by a build whose vocabulary is wider — is preserved with that
  #     name intact. It is real data, and dropping it would make a message
  #     silently lose an attachment on restore.
  #   * A row that is not a media part at all — no `modality`, or no `data` to
  #     carry — is rejected, like every other malformed row this function sees.
  #
  # The line between them is "does it still describe bytes we can show?".
  # `mediaType` and `bytes` are deliberately not required: the panel has an
  # explicit indicator for each of them being absent.
  def from_json(%{"kind" => "media"} = map) do
    with {:ok, modality} <- restore_modality(map["modality"]),
         {:ok, data} <- restore_binary(map["data"]) do
      %Media{
        tool_call_id: map["toolCallId"],
        modality: modality,
        media_type: map["mediaType"],
        data: data,
        bytes: map["bytes"],
        path: map["path"]
      }
    else
      :error -> nil
    end
  end

  def from_json(_), do: nil

  defp restore_modality(name) when is_binary(name) do
    case @modality_names[name] do
      nil -> {:ok, name}
      modality -> {:ok, modality}
    end
  end

  defp restore_modality(_other), do: :error

  defp restore_binary(value) when is_binary(value), do: {:ok, value}
  defp restore_binary(_other), do: :error
end
