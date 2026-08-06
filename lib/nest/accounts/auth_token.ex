defmodule Nest.Accounts.AuthToken do
  @moduledoc """
  Wraps `Phoenix.Token` for Nest's per-user authentication.

  Each token carries `user_id` (an integer `users.id`) signed
  with `Phoenix.Token` and the literal salt `"user_token"`.
  The signing key is `NestWeb.Endpoint`'s `secret_key_base`,
  which is required at boot in prod (see `config/runtime.exs`)
  and auto-derived in dev/test from a stable key.

  Tokens are long-lived. There is **no** server-side revocation
  table for v1 — `SECRET_KEY_BASE` rotation is the only way to
  invalidate outstanding tokens. Password changes do not
  invalidate existing tokens either; if that becomes a need,
  add `users.token_version` and embed it in the signed payload
  to enable cheap revocation.

  The literal salt is intentionally fixed and visible — salts
  here are a Phoenix.Token convention, not a cryptographic
  secret. The actual entropy comes from `secret_key_base`.
  """

  @salt "user_token"

  @max_age 365 * 24 * 60 * 60

  @doc """
  Sign a `user_id` and return a Phoenix.Token string suitable
  for the client to send on subsequent HTTP/WebSocket auth.

  The token encodes `%{user_id: id}` and is valid for
  `max_age` seconds (1 year) — long enough to outlive typical
  browser sessions, short enough that a stolen token has a
  bounded lifespan if rotation is enabled.
  """
  @spec sign(integer()) :: String.t()
  def sign(user_id) when is_integer(user_id) do
    Phoenix.Token.sign(NestWeb.Endpoint, @salt, %{user_id: user_id}, max_age: @max_age)
  end

  @doc """
  Verify a token string and return its `user_id` on success.
  Returns `:error` for any failure mode — bad signature,
  expired, malformed, or wrong salt (which Phoenix handles
  internally as a signature failure).
  """
  @spec verify(String.t() | nil) :: {:ok, integer()} | :error
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(NestWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{user_id: user_id}} when is_integer(user_id) -> {:ok, user_id}
      _ -> :error
    end
  end

  def verify(_), do: :error
end
