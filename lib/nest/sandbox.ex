defmodule Nest.Sandbox do
  @moduledoc """
  Pure builder for bwrap sandbox arguments from a capability map.

  The Sandbox module is intentionally a pure function: it does not run
  commands, talk to the OS, or hold any state. Callers (e.g. `ShellCmd`)
  combine `Sandbox.build/3` output with their own execution concerns
  (stdin, timeout, erlexec, etc.).

  ## Caps shape

  Caps are a raw map matching the JSONB shape stored on `Vocation.modes`:

      %{
        "net" => boolean(),
        "fs" => %{
          "read" => [String.t()],
          "write" => [String.t()]
        }
      }

  * `"net"` — when `true`, the sandbox shares the host's network namespace
    (bwrap receives `--share-net`). When `false`, network is unshared
    (`--unshare-net`).
  * `"fs.read"` — must include `"/"` to run any command (bwrap needs
    `/bin/sh` and its libraries). `"read": ["/"]` produces
    `--ro-bind / /`. `"read": []` is a build-time error.
  * `"fs.write"` — the explicit list of paths the sandbox binds
    read-write. Three kinds of values may appear:

      * `":workspace"` (symbolic) — resolves at runtime to the
        agent's actual workspace directory. The sandbox binds
        `workspace_path` to itself read-write.
      * `"/tmp"` (symbolic) — the per-agent scratch directory. The
        sandbox binds the runtime `tmp_path` (e.g.
        `/tmp/nest-123/agent-456`) at `/tmp` read-write. The literal
        path inside the sandbox is always `/tmp`, regardless of where
        the host `tmp_path` actually lives.
      * Any other path (e.g. `"/data"`, `":extra"`) — bound at the
        same path inside the sandbox read-write.

    Anything NOT in the write list stays read-only via the
    `--ro-bind / /`. So a mode with `write: ["/tmp"]` can write to
    the per-agent scratch directory but NOT to the workspace — the
    workspace falls under the read-only bind of `/`.

    The `":workspace"` and `"/tmp"` placeholders are stripped from the
    write list before binding (they're resolved by their dedicated
    bind steps), so they won't appear as `--bind /tmp /tmp` or similar
    redundant directives.

  ## Design notes

  The path `"/tmp"` is symbolic but `/tmp/nest-123/agent-456` is the
  actual host location. Inside the sandbox, both shell commands and
  tools see `/tmp` — the bind mount makes the path translation
  invisible. The same is true for the workspace: the seed stores
  `":workspace"`, the sandbox resolves it to the agent's actual
  workspace path (e.g. `/Users/you/projects/foo`), and shell commands
  see that path at its original location.
  """

  @doc """
  Build the bwrap argument list for the given caps, workspace, and tmp path.

  Returns `{:ok, args}` with the bwrap argument list, or
  `{:error, reason}` if the caps map is malformed.
  """
  @spec build(map(), String.t(), String.t() | nil) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def build(caps, workspace_path, tmp_path) do
    with :ok <- validate_caps(caps) do
      args =
        base_args()
        |> append_net_flag(caps)
        |> append_workspace_bind(caps, workspace_path)
        |> append_write_binds(caps, workspace_path)
        |> append_tmp_bind(tmp_path)
        |> append_chdir(workspace_path)

      {:ok, args}
    end
  end

  @doc """
  The default "build" profile (full host read, workspace + /tmp
  writable, no network). Used by callers that haven't been migrated to
  pass real caps (and as the fallback in `ShellCmd.execute/5` when
  no caps are provided).

  This is the "everything writable" baseline. Modes that want fewer
  permissions pass their own caps (e.g. `plan` mode uses
  `write: ["/tmp"]` so the workspace stays read-only).
  """
  @spec default_caps() :: map()
  def default_caps do
    %{
      "net" => false,
      "fs" => %{
        "read" => ["/"],
        "write" => ["/tmp", ":workspace"]
      }
    }
  end

  @doc """
  Build bwrap args using `default_caps/0`. Equivalent to
  `ShellCmd.build_bwrap_args/2`'s historical behavior.
  """
  @spec build_default(String.t(), String.t() | nil) :: {:ok, [String.t()]}
  def build_default(workspace_path, tmp_path) do
    {:ok, args} = build(default_caps(), workspace_path, tmp_path)
    {:ok, args}
  end

  @doc """
  Validates a caps map. Returns `:ok` or `{:error, reason}`.

  Exposed publicly so the Vocation changeset can call it, and so tests
  can assert on specific error messages.
  """
  @spec validate_caps(map()) :: :ok | {:error, String.t()}
  def validate_caps(%{"net" => net, "fs" => %{"read" => read, "write" => write}})
      when is_boolean(net) and is_list(read) and is_list(write) do
    cond do
      "/" not in read ->
        {:error, "caps.fs.read must include \"/\" (bwrap needs /bin/sh)"}

      not Enum.all?(read, &is_binary/1) ->
        {:error, "caps.fs.read entries must be strings"}

      not Enum.all?(write, &is_binary/1) ->
        {:error, "caps.fs.write entries must be strings"}

      true ->
        :ok
    end
  end

  # Malformed `fs` (missing keys or wrong types) — match these before
  # the generic `fs` map clause so we give a precise error.
  def validate_caps(%{"net" => _, "fs" => %{"read" => _, "write" => write}})
      when not is_list(write) do
    {:error, "caps.fs.write must be a list"}
  end

  def validate_caps(%{"net" => _, "fs" => %{"read" => read, "write" => _}})
      when not is_list(read) do
    {:error, "caps.fs.read must be a list"}
  end

  def validate_caps(%{"net" => _, "fs" => %{"read" => _}}) do
    {:error, "caps.fs.write must be a list"}
  end

  def validate_caps(%{"net" => _, "fs" => %{"write" => _}}) do
    {:error, "caps.fs.read must be a list"}
  end

  def validate_caps(%{"net" => _, "fs" => _}) do
    {:error, "caps.fs must be a map with \"read\" (list) and \"write\" (list) keys"}
  end

  def validate_caps(%{"net" => _}) do
    {:error, "caps.fs is required"}
  end

  def validate_caps(%{"fs" => _}) do
    {:error, "caps.net is required"}
  end

  def validate_caps(caps) do
    {:error, "invalid caps: #{inspect(caps)}"}
  end

  # Internal helpers (private)

  defp base_args do
    [
      # Unshare everything by default; re-share net below if requested.
      "--unshare-all",
      "--die-with-parent",
      "--new-session",
      "--proc",
      "/proc",
      # Read-only bind of the host root. Must come BEFORE --dev /dev
      # so the devtmpfs overlays it (not the other way around).
      # This also means paths NOT in caps.fs.write (including the
      # workspace when ":workspace" is not in the write list) are
      # read-only.
      "--ro-bind",
      "/",
      "/",
      # Fresh devtmpfs over the read-only bind. Makes /dev/null,
      # /dev/zero, etc. writable for shell redirects.
      "--dev",
      "/dev"
    ]
  end

  defp append_net_flag(args, %{"net" => true}), do: args ++ ["--share-net"]
  defp append_net_flag(args, %{"net" => false}), do: args ++ ["--unshare-net"]

  # Bind the workspace read-write ONLY when the mode's caps include
  # the symbolic ":workspace" entry. Otherwise the workspace stays
  # read-only via the `--ro-bind / /` above, so writes to it
  # (e.g. `cat > $WORKSPACE/file`) fail at the kernel level.
  defp append_workspace_bind(args, %{"fs" => %{"write" => writes}}, workspace_path) do
    if ":workspace" in writes do
      args ++ ["--bind", workspace_path, workspace_path]
    else
      args
    end
  end

  # Bind the remaining paths in caps.fs.write at their literal paths.
  # `:workspace` is rejected because append_workspace_bind/3 handles
  # it. `/tmp` is rejected because append_tmp_bind/2 handles it.
  # The literal workspace_path is also rejected defensively, in case
  # someone includes both ":workspace" and the resolved path.
  defp append_write_binds(args, %{"fs" => %{"write" => writes}}, workspace_path) do
    already_bound = [":workspace", "/tmp", workspace_path]

    extras =
      writes
      |> Enum.reject(&(&1 in already_bound))
      |> Enum.flat_map(fn path -> ["--bind", path, path] end)

    args ++ extras
  end

  # Bind the runtime tmp_path (e.g. /tmp/nest-123/agent-456) at
  # /tmp inside the sandbox. This is what makes "/tmp" symbolic —
  # every agent gets its own scratch directory, but the path inside
  # the sandbox is always /tmp.
  defp append_tmp_bind(args, nil), do: args

  defp append_tmp_bind(args, tmp_path) do
    args ++ ["--bind", tmp_path, "/tmp"]
  end

  defp append_chdir(args, workspace_path) do
    args ++ ["--chdir", workspace_path]
  end
end
