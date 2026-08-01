defmodule Nest.Agents.Agent.BatchSizer.FilePolicy do
  @moduledoc """
  Read-before-write policy check for the `write_file` tool.

  ## Why this lives here

  LLM tool outputs sometimes include `write_file` calls without
  a preceding `read_file` of the target path. The downstream
  effect — a silent overwrite of the user's file — is
  surprising; agents that read the file before writing report
  the contents as part of the LLM context, and the policy
  enforces that flow.

  Two failure modes, both surfaced to the LLM as a
  `ToolResult{is_error: true, content: <reason>}` so the
  agent retries the read or gets a clear "file changed"
  signal:

    * `:never_read`        — no `read_file` result has populated
      `state.chat_state.read_files[path]` (or the path was
      cleared by a post-compaction reset). User-facing
      message: `"You must read that file before overwriting it."`.

    * `:contents_changed`   — a `read_file` (or successful
      `write_file`) recorded the file's `{mtime, size}` at
      access time, but a subsequent on-disk `File.stat/1`
      returns a different pair. User-facing message:
      `"File contents have changed, re-read that file before
      writing it."`.

  ## On-disk check

  Detection is mtime+size based (no SHA-256): the goal is to
  catch "the file was modified since the agent last looked at
  it", not "the bytes are byte-for-byte identical". A
  same-content re-touch (preserved size, unchanged mtime) is
  treated as "no change" — which is the safe default (the
  agent's view of the file is still correct). A `touch` (mtime
  bumped, content preserved) is treated as "changed" — the
  conservative answer, since the agent can't know whether
  something else intends to write through it next.

  ## Insertion point

  Called from `Nest.Agents.Agent.BatchSizer.execute_one/2`
  *before* `LLMTools.execute_one/3` runs the tool closure.
  The worker calls back to the agent pid via
  `GenServer.call(pid, {:check_read_policy, ...}, 5_000)`.
  If the call fails (agent stopped mid-flight) we fall
  through to `:ok` — better to allow the write than to
  over-restrict on a transient GenServer issue.
  """

  alias Nest.Messages.ToolCall

  @never_read_msg "You must read that file before overwriting it."
  @contents_changed_msg "File contents have changed, re-read that file before writing it."

  @doc """
  Pre-call hook for `write_file`. Returns one of:

    * `:ok` — the call may proceed.
    * `{:error, :never_read}` — caller translates to
      `"You must read that file before overwriting it."`.
    * `{:error, :contents_changed}` — caller translates to
      `"File contents have changed, re-read that file before
      writing it."`.

  Non-`write_file` calls (or calls with no `path`) pass
  through as `:ok`. Workers that have no `agent_pid` in
  their `ctx` (defensive — shouldn't happen in production)
  also pass through.
  """
  @spec check(ToolCall.t(), map()) :: :ok | {:error, :never_read | :contents_changed}
  def check(%ToolCall{name: "write_file"} = tc, ctx) do
    path = path_of(tc)
    do_check(ctx, path)
  end

  def check(_tc, _ctx), do: :ok

  defp path_of(%ToolCall{arguments: %{"path" => path}}) when is_binary(path),
    do: path

  defp path_of(_tc), do: nil

  defp do_check(_ctx, nil), do: :ok
  defp do_check(%{agent_pid: pid}, path) when not (is_binary(pid) and is_binary(path)), do: :ok

  defp do_check(%{agent_pid: pid}, path) do
    GenServer.call(pid, {:check_read_policy, %{path: path}}, 5_000)
  rescue
    _ -> :ok
  end

  @doc """
  Translate the policy decision into the user-facing error
  string the LLM will see in its tool result.
  """
  @spec error_message(:ok | {:error, atom()}) :: :ok | String.t()
  def error_message(:ok), do: :ok
  def error_message({:error, :never_read}), do: @never_read_msg
  def error_message({:error, :contents_changed}), do: @contents_changed_msg
end
