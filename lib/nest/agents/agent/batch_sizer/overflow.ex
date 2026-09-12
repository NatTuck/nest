defmodule Nest.Agents.Agent.BatchSizer.Overflow do
  @moduledoc """
  Shared "write an oversized result to the agent's scratch dir"
  helper. Both `BatchSizer` (shell-cmd / file-read overflow) and
  `BatchLoop` (an `agents-batch` aggregate that exceeds its inline
  cap) write their full content to a scratch file and return a
  short pointer + head summary inline.

  The scratch dir is `ctx.tmp_path` — the same per-agent directory
  the sandbox binds read-write at `/tmp`. Writing on the host
  directly (rather than through the sandbox gatekeeper) is
  intentional internal scratch management, mirroring `BatchSizer`.
  """

  @doc """
  Write `content` to a scratch file under `ctx.tmp_path` and return
  the path, or `nil` when the tmp dir is unavailable or the write
  fails. `prefix` distinguishes the artifact type in the filename
  (e.g. `"exec"` for shell output, `"agents-batch"` for a batch
  aggregate).
  """
  @spec write(binary(), map(), String.t(), String.t()) :: String.t() | nil
  def write(content, ctx, prefix, ext) do
    case Map.get(ctx, :tmp_path) do
      nil ->
        nil

      dir ->
        path = Path.join(dir, "#{prefix}-#{token()}.#{ext}")

        try do
          File.write!(path, content)
          path
        rescue
          _ -> nil
        end
    end
  end

  defp token do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
