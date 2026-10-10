defmodule Nest.Sandbox.Paths do
  @moduledoc """
  Host/sandbox path translation for the space scratch bind.

  The space scratch dir is bound at `/tmp` inside the sandbox, so an agent's
  own scratch dir (the host `<space_dir>/<agent-name>`) is `/tmp/<agent-name>`
  inside. This module is the single definition of that mapping, shared by the
  bwrap argument builder (`Nest.Sandbox.append_tmp_bind/2`, via
  `scratch_root/1`) and the stat/glob fast-path translation
  (`to_host/3`, `to_sandbox/2`), so the mount and the translation cannot
  drift.

  ## Host paths must not escape `Nest.Sandbox`

  The host scratch spelling (`/tmp/nest-<ospid>/space-<id>/<agent>/...`) is an
  internal detail: the LLM must only ever see sandbox paths
  (`/tmp/<agent>/...`). Every function here that receives or returns a host
  path is called only from `Nest.Sandbox`, and its result must never be put in
  a tool description, tool result, or anything else the agent sees.
  """

  alias Nest.FSPath

  @doc """
  The HOST directory bound at `/tmp` inside the sandbox: the parent of the
  agent's own scratch dir. Refuses `/` or `/tmp` (binding the whole host
  `/tmp` would be a sandbox escape).
  """
  @spec scratch_root(String.t()) :: String.t()
  def scratch_root(tmp_path) do
    # HOST PATH: this is the host directory bound at /tmp — the agent must
    # only ever see the sandbox spelling (/tmp/<agent>/...), never this.
    root = Path.dirname(tmp_path)

    if root in ["/", "/tmp"] do
      raise ArgumentError, "refusing to use #{inspect(root)} as a scratch bind root"
    end

    FSPath.canonical(root)
  end

  @doc """
  Translate a sandbox-domain path (what the LLM sees) onto its HOST backing
  path. `nil` tmp means "no scratch binding"; a path under `workspace` is left
  alone first (a workspace root may itself live under `/tmp`), then a path
  under `/tmp` is mapped onto the scratch root, and everything else is
  returned unchanged.

  HOST PATH result — called only from `Nest.Sandbox`, and never returned to
  the agent.
  """
  @spec to_host(String.t(), String.t() | nil, String.t() | nil) :: String.t()
  def to_host(path, _workspace, nil), do: path

  def to_host(path, workspace, tmp_path) do
    # HOST PATH result — only handed to `File.*` inside Nest.Sandbox; the
    # agent must only ever see the sandbox spelling, never what this returns.
    expanded = Path.expand(path)

    cond do
      is_binary(workspace) and FSPath.under?(workspace, expanded) ->
        path

      FSPath.under?("/tmp", expanded) ->
        Path.join(scratch_root(tmp_path), Path.relative_to(expanded, "/tmp"))

      true ->
        path
    end
  end

  @doc """
  Translate a HOST backing path back to the sandbox spelling the LLM sees.
  `nil` tmp means "no scratch binding"; paths outside the scratch bind root
  are returned unchanged.

  HOST PATH input — called only from `Nest.Sandbox`, and only on paths it
  produced itself.
  """
  @spec to_sandbox(String.t(), String.t() | nil) :: String.t()
  def to_sandbox(path, nil), do: path

  def to_sandbox(path, tmp_path) do
    # HOST PATH input: `path` came out of a host walk and is translated back to
    # the sandbox spelling the agent sees. Never hand the host spelling on.
    expanded = Path.expand(path)
    root = scratch_root(tmp_path)

    if FSPath.under?(root, expanded) do
      Path.join("/tmp", Path.relative_to(expanded, root))
    else
      path
    end
  end
end
