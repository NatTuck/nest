defmodule Nest.WireFormatAssertions do
  @moduledoc """
  Assertion helper for payloads that cross the WebSocket wire.

  `Phoenix.ChannelTest` installs `Phoenix.ChannelTest.NoopSerializer`,
  whose `encode!/1` returns the payload unchanged. `assert_push`
  therefore never runs the JSON encoder, so a payload containing a
  term Jason cannot encode (a tuple, a pid, an un-derived struct)
  passes every channel test and only crashes in production — inside
  the channel process — with a bare `Protocol.UndefinedError`.

  `assert_wire_encodable!/1` closes that gap by running the same
  serializer the endpoint uses in production. On failure it reports
  the path to the first non-encodable value so the offending field is
  obvious.
  """

  import ExUnit.Assertions

  alias Phoenix.Socket.Message
  alias Phoenix.Socket.V2.JSONSerializer

  @doc """
  Assert that `payload` can be serialized by the real socket serializer.

  `event` is only used in the failure message. Returns `payload`
  unchanged so the call can be used inline.
  """
  @spec assert_wire_encodable!(term(), String.t()) :: term()
  def assert_wire_encodable!(payload, event \\ "wire-format-check") do
    message = %Message{
      topic: "wire-format-check",
      event: event,
      payload: payload,
      ref: nil,
      join_ref: nil
    }

    case encode(message) do
      {:ok, _encoded} ->
        payload

      {:error, _exception} ->
        flunk("""
        #{event} payload is not JSON-serializable.

        #{format_offender(payload)}

        Payload:
        #{inspect(payload, pretty: true, limit: :infinity)}
        """)
    end
  end

  defp encode(message) do
    {:ok, JSONSerializer.encode!(message)}
  rescue
    exception -> {:error, exception}
  end

  defp format_offender(payload) do
    case find_unencodable(payload, "$") do
      {path, value} ->
        "First non-encodable value at #{path}:\n  #{inspect(value, limit: :infinity)}"

      nil ->
        "Could not locate the non-encodable value."
    end
  end

  # Walk the payload to find the first term Jason cannot encode on its
  # own. Only reached on the failure path, so the repeated `encodable?`
  # probes never run for a healthy payload.
  defp find_unencodable(term, path) do
    if encodable?(term) do
      nil
    else
      descend(term, path) || {path, term}
    end
  end

  defp descend(term, path) when is_map(term) and not is_struct(term) do
    Enum.find_value(term, fn {key, value} -> descend_map_entry(key, value, path) end)
  end

  defp descend(term, path) when is_list(term) do
    term
    |> Enum.with_index()
    |> Enum.find_value(fn {value, index} -> find_unencodable(value, "#{path}[#{index}]") end)
  end

  defp descend(%_{} = struct, path), do: descend(Map.from_struct(struct), path)

  defp descend(_leaf, _path), do: nil

  defp descend_map_entry(key, value, path) do
    if encodable?(key) do
      find_unencodable(value, "#{path}.#{key}")
    else
      {"#{path} key #{inspect(key)}", key}
    end
  end

  defp encodable?(term) do
    _ = Phoenix.json_library().encode!(term)
    true
  rescue
    _exception -> false
  end
end
