defmodule Nest.Messages.Sanitize do
  @moduledoc """
  Make message text storable and wire-safe.

  External bytes — shell output, file reads, shell-job logs — can
  contain characters Postgres cannot store in a text/jsonb column
  (notably `U+0000`) and invalid UTF-8 that JSON encoders and the
  database both reject. Persisting such a message raises
  `Postgrex.Error` (`22P05 untranslatable_character`), which kills the
  Agent.

  `message/1` walks a message tuple and replaces every offending byte
  with `U+FFFD` (REPLACEMENT CHARACTER), so the sequence is identical
  in memory, in the `messages` row, in the UI, and on the provider
  wire.

  It is applied at both write boundaries:

    * `Nest.Agents.Agent.MessageAppender.append_stamped/2` — the live
      path (in-memory, DB, broadcast all see the same text);
    * `Nest.Agents.PersistedMessage.from_runtime/2` — direct inserts
      such as the initial system row.

  Both call sites are idempotent.
  """

  alias Nest.Messages.Part

  @replacement "\uFFFD"

  @doc "Sanitize every text field reachable from a message tuple."
  @spec message(Nest.Messages.Message.t()) :: Nest.Messages.Message.t()
  def message({role, struct}) when is_atom(role) and is_map(struct) do
    {role, sanitize_struct(struct)}
  end

  def message(other), do: other

  @doc """
  Replace NUL and invalid UTF-8 in a binary with `U+FFFD`. `nil` and
  non-binaries pass through unchanged.
  """
  @spec text(binary() | nil) :: binary() | nil
  def text(nil), do: nil

  def text(bin) when is_binary(bin) do
    bin
    |> valid_utf8()
    |> String.replace(<<0>>, @replacement)
  end

  def text(other), do: other

  @doc """
  True when `bin` is usable as text: valid UTF-8 and free of NUL.

  NUL (`U+0000`) is valid UTF-8, so `String.valid?/1` alone would call
  it text; but Postgres `text`/`jsonb` rejects it, so it is treated as
  binary output here. Callers use this to route producer output (shell
  bytes, file reads) to their non-text handling instead of persisting
  raw bytes.
  """
  @spec text?(term()) :: boolean()
  def text?(bin) when is_binary(bin) do
    String.valid?(bin) and not String.contains?(bin, <<0>>)
  end

  def text?(_other), do: false

  defp sanitize_struct(%Part.Text{text: text} = part), do: %{part | text: text(text)}

  defp sanitize_struct(%Part.Thinking{thinking: text, signature: signature} = part),
    do: %{part | thinking: text(text), signature: text(signature)}

  defp sanitize_struct(%Part.ToolUse{id: id, name: name, arguments: args} = part),
    do: %{part | id: text(id), name: text(name), arguments: deep(args)}

  defp sanitize_struct(%Part.ToolResult{} = part) do
    %{
      part
      | tool_call_id: text(part.tool_call_id),
        name: text(part.name),
        content: text(part.content),
        arguments: deep(part.arguments)
    }
  end

  defp sanitize_struct(%Part.Refusal{refusal: refusal} = part),
    do: %{part | refusal: text(refusal)}

  # System/User/Assistant/Tool carry `parts` plus `metadata` and
  # `api_logs`; a compaction message carries neither text nor parts, so
  # it falls through to the catch-all.
  defp sanitize_struct(%{parts: parts} = struct) when is_list(parts) do
    struct
    |> Map.put(:parts, Enum.map(parts, &sanitize_struct/1))
    |> Map.update(:metadata, nil, &deep/1)
    |> Map.update(:api_logs, [], &deep/1)
  end

  defp sanitize_struct(struct), do: struct

  defp deep(value) when is_binary(value), do: text(value)
  defp deep(value) when is_list(value), do: Enum.map(value, &deep/1)

  defp deep(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, val} -> {deep(key), deep(val)} end)
  end

  defp deep(value), do: value

  # Decode as much valid UTF-8 as possible, replacing each undecodable
  # byte with U+FFFD and continuing, so a raw-binary blob never
  # truncates the rest of the message. Tail-recursive with an
  # accumulator so a large blob cannot blow the stack.
  defp valid_utf8(bin), do: valid_utf8(bin, [])

  defp valid_utf8(<<>>, acc), do: IO.iodata_to_binary(Enum.reverse(acc))

  defp valid_utf8(bin, acc) do
    case :unicode.characters_to_binary(bin, :utf8, :utf8) do
      text when is_binary(text) ->
        IO.iodata_to_binary(Enum.reverse([text | acc]))

      {:error, converted, <<_bad, rest::binary>>} ->
        valid_utf8(rest, [@replacement, converted | acc])

      {:error, converted, ""} ->
        IO.iodata_to_binary(Enum.reverse([@replacement, converted | acc]))

      {:incomplete, converted, _rest} ->
        IO.iodata_to_binary(Enum.reverse([@replacement, converted | acc]))
    end
  end
end
