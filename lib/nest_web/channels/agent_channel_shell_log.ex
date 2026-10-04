defmodule NestWeb.AgentChannel.ShellLog do
  @moduledoc """
  Bounded, JSON-safe view of a background shell job's captured log for
  the agent channel's `shell:log` reply.

  Background-job logs are uncapped on disk (a job may produce output for
  as long as it runs), but a single websocket frame must stay bounded:
  the reply carries only the head of the log, with an explicit
  truncation marker when there is more. Shell output can be raw binary
  (invalid UTF-8), which `Jason` refuses to encode, so it is coerced to
  valid UTF-8 as well as trimmed.
  """

  @max_bytes 65_536

  @doc """
  A valid-UTF-8 head of `content`, at most `@max_bytes`, with an explicit
  truncation marker appended when the input was longer.
  """
  @spec bounded(binary()) :: String.t()
  def bounded(content) when byte_size(content) <= @max_bytes do
    valid_utf8(content)
  end

  def bounded(content) do
    total = byte_size(content)
    head = binary_part(content, 0, @max_bytes)

    valid_utf8(head) <>
      "\n... [log truncated: showing first #{@max_bytes} of #{total} bytes]"
  end

  # Decode as much valid UTF-8 as possible. `:unicode.characters_to_binary/3`
  # reports the undecodable remainder rather than raising; an invalid byte
  # mid-stream (raw binary output) drops the rest, which is flagged so the
  # omission is visible rather than silent.
  defp valid_utf8(bin) do
    case :unicode.characters_to_binary(bin, :utf8, :utf8) do
      text when is_binary(text) -> text
      {:error, converted, _rest} -> converted <> "\n... [non-text output omitted]"
      {:incomplete, converted, _rest} -> converted
    end
  end
end
