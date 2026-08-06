defmodule Nest.Accounts.Password do
  @moduledoc """
  Thin wrapper around `Argon2.hash_pwd_salt/1` and
  `Argon2.verify_pass/2`. Exists so the rest of the codebase
  doesn't import `Argon2` directly and so we have one place to
  swap the algorithm if we ever want to (e.g. move to argon2id
  with custom cost parameters, or scrypt).

  The default `argon2_elixir` parameters ($argon2id$v=19$,
  `m=65536,t=3,p=4`) are appropriate for a small trusted
  deployment. Tightening would lengthen every login and every
  password change — not worth it for the v1 threat model.
  """

  @doc """
  Hash a plaintext password. Returns the encoded hash as a
  string suitable for storage in `users.password_hash`.
  """
  @spec hash(String.t()) :: String.t()
  def hash(plaintext) when is_binary(plaintext) do
    Argon2.hash_pwd_salt(plaintext)
  end

  @doc """
  Verify a plaintext password against a stored hash. Returns
  `true` on match, `false` on mismatch. Does not raise on
  malformed hashes (e.g. corrupted DB rows); treats them as
  mismatches and lets the caller decide what to do.
  """
  @spec verify(String.t(), String.t() | nil) :: boolean()
  def verify(plaintext, hash) when is_binary(plaintext) and is_binary(hash) do
    Argon2.verify_pass(plaintext, hash)
  end

  def verify(_plaintext, _hash), do: false
end
