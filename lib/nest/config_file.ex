defmodule Nest.ConfigFile do
  @moduledoc """
  The two protected config files — `.nest` and `AGENTS.md` — and the one decision
  about their state.

  Both are **human-authored project config**, and an agent that can rewrite either
  drifts its own constraints: `.nest` grants host access, `AGENTS.md` states the
  project's policy. The runtime reads both on the **host** (`Nest.ProjectConfig`
  for one, `Nest.Agents.Agent.SystemPrompt` for the other) and hands them to the
  sandbox as read-only binds rather than letting it discover them, so a regular
  file at either path is the host's file by construction.

  A path that is *not* a regular file cannot be masked, and *omitting* the mask
  is not protection either — with no mount point over the path an `act` agent can
  delete a symlink and write a regular `.nest` declaring `[[mount]] path =
  "/home"`, which the next caps resolution honours. So `error/1` **refuses the
  workspace**, and it is called from every funnel: `Nest.Sandbox.workspace_error/1`
  (the choose-time path and `Sandbox.build/4`'s final gate),
  `Supervisor.start_under_supervisor/2` (the restart route, which never reaches
  `Sandbox.build/4`) and `Nest.Tools.ShellCmd` (the one place all three backends
  pass through for a command).

  The refusal is **unconditional on every backend**, `"none"` included. It is a
  property of the workspace rather than of the backend, so it answers the same
  question everywhere and cannot be sidestepped by changing the answer where
  enforcement is weaker.
  """

  require Logger

  @nest_name ".nest"
  @agents_md_name "AGENTS.md"

  @typedoc """
  What is at a config path: a regular file, nothing, or something Nest cannot
  protect (`:symlink`, `:directory`, `:unreadable`, or any other type).
  """
  @type state :: :regular | :absent | {:not_regular, atom()}

  @doc "The project's sandbox config file name."
  @spec nest_name() :: String.t()
  def nest_name, do: @nest_name

  @doc """
  The protected instruction file's name. One spelling, here, so nothing else has
  to carry a copy of the string.
  """
  @spec agents_md_name() :: String.t()
  def agents_md_name, do: @agents_md_name

  @doc """
  Which of the three states a config path is in.

  `{:not_regular, type}` is a path that exists but is not a regular file. Reading
  it would follow a symlink; masking it would either be a no-op (the mount lands
  on the target, leaving the link replaceable in the read-write workspace bind) or
  wedge every command in the workspace (`bwrap` cannot create the mount point when
  the target is outside it). So it is neither read nor masked, and `error/1`
  refuses the workspace.

  This function is pure. The warning lives in `error/1`, which is the gate.
  """
  @spec state(String.t()) :: state()
  def state(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        :regular

      {:ok, %File.Stat{type: type}} ->
        {:not_regular, type}

      {:error, :enoent} ->
        :absent

      # Anything else is a path we could not inspect — `:eacces` on a directory in
      # the way, `:eloop` on a symlink cycle. The safe default is the refusal, not
      # the mask: masking `/dev/null` over a path we could not look at would bind
      # over something we do not understand.
      {:error, _reason} ->
        {:not_regular, :unreadable}
    end
  end

  @doc """
  Read a config file: `{:ok, content}`, `:absent`, `{:not_regular, type}`, or
  `{:error, reason}` for a regular file the OS will not let us read.

  The type decision is `state/1`; this only adds the bytes.
  """
  @spec read(String.t()) :: {:ok, binary()} | {:error, term()} | :absent | {:not_regular, atom()}
  def read(path) do
    case state(path) do
      :regular ->
        case File.read(path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, reason}
        end

      other ->
        other
    end
  end

  @doc """
  Whether either protected config file in `workspace` is a path Nest cannot
  protect: `:ok`, or `{:error, {:config_file_not_regular, path}}`.

  Warns **once per path per BEAM**, in `:persistent_term`. `ProjectConfig.load/1`
  runs on every prompt composition *and* every caps resolution, so a per-call log
  would flood the output. `:persistent_term` rather than the ETS table the
  canonical-workspace memo uses: that table has an owner, so "once per BEAM" was
  really "once per table lifetime", which made a test flake. A concurrent first
  call can log twice; that is benign.
  """
  @spec error(String.t() | nil) :: :ok | {:error, {:config_file_not_regular, String.t()}}
  def error(workspace) when is_binary(workspace) do
    Enum.find_value([@nest_name, @agents_md_name], :ok, fn name ->
      path = Path.join(workspace, name)

      case state(path) do
        {:not_regular, type} -> refuse(path, type)
        _regular_or_absent -> nil
      end
    end)
  end

  def error(_no_workspace), do: :ok

  defp refuse(path, type) do
    key = {:nest_config_file_not_regular, path}

    if :persistent_term.get(key, :unset) == :unset do
      :persistent_term.put(key, true)

      Logger.warning(
        "#{path} is #{describe(type)}, so Nest cannot protect it from being " <>
          "rewritten. This workspace is refused until it is a regular file."
      )
    end

    {:error, {:config_file_not_regular, path}}
  end

  defp describe(:symlink), do: "a symlink"
  defp describe(:directory), do: "a directory"
  defp describe(:unreadable), do: "unreadable"
  defp describe(_other), do: "not a regular file"
end
