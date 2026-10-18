defmodule NestWeb.ErrorPayload do
  @moduledoc false
  # The one spelling of the `%{"reason" => ...}` map a channel replies with.
  #
  # It exists because `to_string/1` is not total: a reason that carries a detail
  # term — `{:config_file_not_regular, path}` is the one the runtime produces on
  # a normal path — raises `Protocol.UndefinedError` inside the channel, which
  # kills the socket and leaves the client with no reply at all. Every
  # `{:error, reason}` a `handle_in/3` can get goes through here instead, so a
  # new tagged reason is answered rather than fatal.
  #
  # A reason that needs its detail on the wire (`path`, `parent`) gets a clause
  # of its own; the rest are answered with the tag, which is what the browser
  # switches on.

  require Logger

  @doc """
  The reply payload for a server error reason.

  A binary is passed through — a caller that already has a wire code (the
  `"agent_not_found"` spelling of `:not_found`, say) keeps it.
  """
  @spec from_reason(term()) :: %{required(String.t()) => term()}
  def from_reason({:config_file_not_regular, path}) do
    # The path is on the wire because the user has to know *which* file to
    # replace; `describeConfigFileError` in the browser renders it.
    %{"reason" => "config_file_not_regular", "path" => path}
  end

  def from_reason(reason) when is_binary(reason), do: %{"reason" => reason}
  def from_reason(reason) when is_atom(reason), do: %{"reason" => Atom.to_string(reason)}

  # A tagged reason with no clause above: answer with the tag, which is the part
  # the browser can act on. Losing the detail is worse than a crash, and keeping
  # it in a key nothing reads is worse than losing it — so it goes to the log.
  def from_reason({tag, detail}) when is_atom(tag) do
    Logger.warning("Unmapped error reason #{inspect(tag)}: #{inspect(detail)}")
    %{"reason" => Atom.to_string(tag)}
  end

  def from_reason(reason) do
    Logger.error("Unmapped error reason: #{inspect(reason)}")
    %{"reason" => "unknown_error"}
  end
end
