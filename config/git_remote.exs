defmodule Config.GitRemote do
  @moduledoc """
  Build-time helper for converting git remote URLs to HTTPS.

  This module is loaded during config compilation to set the source_url
  application config from the git origin remote.
  """

  @doc """
  Gets the origin remote URL and converts it to HTTPS format.
  Returns nil if not in a git repository or if origin doesn't exist.
  """
  @spec get_origin_url() :: String.t() | nil
  def get_origin_url do
    case System.cmd("git", ["remote", "get-url", "origin"], stderr_to_stdout: true) do
      {url, 0} -> to_https_url(String.trim(url))
      {_, _} -> nil
    end
  end

  @doc """
  Converts a git remote URL to HTTPS URL.

  ## Examples

      iex> Config.GitRemote.to_https_url("git@github.com:user/repo.git")
      "https://github.com/user/repo"

      iex> Config.GitRemote.to_https_url("https://github.com/user/repo.git")
      "https://github.com/user/repo"
  """
  @spec to_https_url(String.t()) :: String.t() | nil
  def to_https_url(url) when is_binary(url) do
    cond do
      String.starts_with?(url, "https://") ->
        String.replace_suffix(url, ".git", "")

      String.starts_with?(url, "http://") ->
        String.replace_suffix(url, ".git", "")

      String.starts_with?(url, "git@") ->
        parse_ssh_url(url)

      String.match?(url, ~r/^[^\/]+:[^\/].*/) ->
        parse_ssh_url("git@" <> url)

      true ->
        nil
    end
  end

  def to_https_url(_), do: nil

  defp parse_ssh_url(url) do
    case Regex.run(~r/^git@([^:]+):(.+?)(?:\.git)?$/, url) do
      [_, host, path] -> "https://#{host}/#{path}"
      _ -> nil
    end
  end
end
