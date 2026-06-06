defmodule NestWeb.SurgicalReloaderPlug do
  @moduledoc """
  Plug interface for the SurgicalReloader. This plug runs on every HTTP
  request and ensures code is reloaded when files change.
  """
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # The SurgicalReloader GenServer handles file watching independently,
    # so this plug just passes through
    conn
  end
end
