defmodule Nest.GitRemote do
  @moduledoc """
  Runtime access to the configured source URL.

  The URL is set at build time from the git origin remote.
  See config/git_remote.exs for the conversion logic.
  """

  @doc """
  Gets the source code HTTPS URL for the application.

  This is set at build time from the git origin remote in config.exs.
  """
  @spec source_url() :: String.t() | nil
  def source_url do
    Application.get_env(:nest, :source_url)
  end
end
