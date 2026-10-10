defmodule Nest.Sandbox.Paths do
  @sandbox_root "/tmp"

  @moduledoc """
  The single definition of the space scratch bind and the sandbox-domain
  spelling of a scratch path.

  The space scratch dir is bound at `#{@sandbox_root}` inside the sandbox,
  so an agent's own scratch dir (the host `<space_dir>/<agent-name>`) is
  `#{@sandbox_root}/<agent-name>` inside. `scratch_root/1` is the one bind
  source (`Nest.Sandbox.append_tmp_bind/2` uses it) and `sandbox_tmp_path/1`
  is the one inverse mapping, so the mount and the spelling cannot drift.

  There is deliberately **no** host/sandbox path translation here: the
  sandbox's filesystem view is bwrap's view, and every `read`/`stat`/`glob`
  executes inside bwrap (see `Nest.Sandbox`). `TmpSpace` produces the host
  `tmp_path`; `Paths` derives the mount and the spelling from it. `Paths`
  must not depend on `TmpSpace`.

  ## Host paths must not escape `Nest.Sandbox`

  The host scratch spelling (`#{@sandbox_root}/nest-<ospid>/space-<id>/<agent>/...`)
  is an internal detail: the LLM must only ever see sandbox paths
  (`#{@sandbox_root}/<agent>/...`). Every function here that receives or
  returns a host path is called only from `Nest.Sandbox`, and its result must
  never be put in a tool description, tool result, or anything else the agent
  sees.
  """

  alias Nest.FSPath

  @doc """
  The mount point the space scratch dir is bound at inside the sandbox.
  """
  @spec sandbox_root() :: String.t()
  def sandbox_root, do: @sandbox_root

  @doc """
  The HOST directory bound at `#{@sandbox_root}` inside the sandbox: the parent
  of the agent's own scratch dir. Refuses `/` or `#{@sandbox_root}` (binding the
  whole host `#{@sandbox_root}` would be a sandbox escape).
  """
  @spec scratch_root(String.t()) :: String.t()
  def scratch_root(tmp_path) do
    # HOST PATH: this is the host directory bound at /tmp — the agent must
    # only ever see the sandbox spelling (/tmp/<agent>/...), never this.
    root = Path.dirname(tmp_path)

    if root in ["/", @sandbox_root] do
      raise ArgumentError, "refusing to use #{inspect(root)} as a scratch bind root"
    end

    FSPath.canonical(root)
  end

  @doc """
  The path an agent's own scratch dir (`tmp_path`) appears at inside the
  sandbox: `#{@sandbox_root}/<agent-name>` (the space dir is bound at
  `#{@sandbox_root}`).

  This is the only spelling an agent should ever be told about or hand back;
  the host backing path is internal to `Nest.Sandbox`.
  """
  @spec sandbox_tmp_path(String.t()) :: String.t()
  def sandbox_tmp_path(tmp_path), do: Path.join(@sandbox_root, Path.basename(tmp_path))
end
