defmodule NestWeb.LobbyChannel.SpaceJobs do
  @moduledoc """
  The space-wide shell-job view's transport (#225): its refresh read, a kill,
  a log read, and the `space:jobs` push the manager's space frame becomes.

  The per-agent job panel rides the agent channel (`shell:list` / `shell:kill`
  / `shell:log`, owner-scoped). This is the space's own view: every agent's
  jobs in one list, so a job a sibling left running is visible — and stoppable
  — from the space page without joining its owner's conversation. It is built
  on the manager's space-scoped operations (`Nest.Sandbox.ShellJobs.list_space/1`,
  `kill_space/2`, `output_space/2`); the first two are what `shell-list
  scope: "space"` and a sibling's `shell-kill` already use.

  ## Why the lobby carries it

  `Nest.Sandbox.ShellJobs.Frames` broadcasts `{:space_jobs, %{space_id, jobs}}`
  on the space's topic whenever any job in the space changes — a start, an
  exit, a kill, a drop, or the namespace-lost marking when the space's holder
  dies (#224). `NestWeb.LobbyChannel` already subscribes to that topic for
  every space its user can see, so the view needs no new socket and no new
  topic: the frame becomes a `space:jobs` push, and the `init` payload carries
  each visible space's list so a page load renders what is already running.

  ## The wire

  | direction | event | payload |
  |---|---|---|
  | server → client | `init` (its `space_jobs` field) | `[%{"space_id" => id, "jobs" => [job]}]` |
  | server → client | `space:jobs` | `%{"space_id" => id, "jobs" => [job]}` |
  | client → server | `space_jobs` | `%{"space_id" => id}` |
  | server → client | (its reply) | `%{"jobs" => [job]}` |
  | client → server | `kill_space_job` | `%{"space_id" => id, "id" => job_id}` |
  | server → client | (its reply) | `%{"agent" => owner_name}` |
  | client → server | `space_job_log` | `%{"space_id" => id, "id" => job_id}` |
  | server → client | (its reply) | `%{"content" => text}` |

  A `job` is `Nest.Sandbox.ShellJobs.Info.t()` — the same shape the per-agent
  panel renders, `agent` included, so the space view can say whose job each
  row is.

  ## Scoping

  `Authz.authorize_space_owner/2` — the check the space feed's read makes, and
  exactly the set `after_join` subscribes to. A client names the space it is
  asking about, so it cannot read, kill or log a job in a space it does not
  own. The kill is the manager's `kill_space/2`, which notifies the owning
  agent: a job stopped from the space page is one its owner did not ask to
  lose, the same as a sibling's `shell-kill`.
  """

  alias Nest.Sandbox.ShellJobs
  alias Nest.Spaces
  alias NestWeb.ErrorPayload
  alias NestWeb.LobbyChannel.Authz

  @doc """
  The manager's `{:space_jobs, _}` frame, as this client's `space:jobs` push.

  The space is already scoped by the subscription the frame arrived on (see
  the moduledoc), so there is nothing left to check here.
  """
  @spec frame(map(), Phoenix.Socket.t()) :: {:noreply, Phoenix.Socket.t()}
  def frame(payload, socket) do
    Phoenix.Channel.push(socket, "space:jobs", payload)
    {:noreply, socket}
  end

  @doc """
  The view's refresh read (`space_jobs`): every job of every agent in the
  space, running first — the same list the `space:jobs` frames carry, so a
  refresh and a broadcast render the same rows.
  """
  @spec read(map(), Phoenix.Socket.t()) :: {:reply, term(), Phoenix.Socket.t()}
  def read(%{"space_id" => space_id}, socket) when is_integer(space_id) do
    case Authz.authorize_space_owner(space_id, socket.assigns.current_user) do
      {:ok, :owner} ->
        {:reply, {:ok, %{jobs: ShellJobs.list_space(space_id)}}, socket}

      {:error, reason} ->
        {:reply, {:error, ErrorPayload.from_reason(reason)}, socket}
    end
  end

  def read(_payload, socket), do: {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}

  @doc """
  Stop a running job owned by any agent in the space (`kill_space_job`).

  The reply names the owner, so the client can say whose job it stopped. The
  lookup and the kill are one manager call (`kill_space/2`), so a job that
  exits in between cannot be reported as killed from a stale read.
  """
  @spec kill(map(), Phoenix.Socket.t()) :: {:reply, term(), Phoenix.Socket.t()}
  def kill(%{"space_id" => space_id, "id" => id}, socket)
      when is_integer(space_id) and is_binary(id) do
    case Authz.authorize_space_owner(space_id, socket.assigns.current_user) do
      {:ok, :owner} ->
        kill_in_space(space_id, id, socket)

      {:error, reason} ->
        {:reply, {:error, ErrorPayload.from_reason(reason)}, socket}
    end
  end

  def kill(_payload, socket), do: {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}

  defp kill_in_space(space_id, id, socket) do
    case ShellJobs.kill_space(space_id, id) do
      {:ok, {_space_id, name}} ->
        {:reply, {:ok, %{agent: name}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "not_found"}}, socket}
    end
  end

  @doc """
  One job's captured output (`space_job_log`), for the view's log reader.
  """
  @spec log(map(), Phoenix.Socket.t()) :: {:reply, term(), Phoenix.Socket.t()}
  def log(%{"space_id" => space_id, "id" => id}, socket)
      when is_integer(space_id) and is_binary(id) do
    case Authz.authorize_space_owner(space_id, socket.assigns.current_user) do
      {:ok, :owner} ->
        case ShellJobs.output_space(space_id, id) do
          {:ok, content} -> {:reply, {:ok, %{content: content}}, socket}
          {:error, :not_found} -> {:reply, {:error, %{"reason" => "not_found"}}, socket}
        end

      {:error, reason} ->
        {:reply, {:error, ErrorPayload.from_reason(reason)}, socket}
    end
  end

  def log(_payload, socket), do: {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}

  @doc """
  The `init` payload's `space_jobs` field: one `%{space_id, jobs}` entry per
  visible space, so a session that joins while jobs are running renders them
  without waiting for the next change. One manager read per space, like the
  running counts the agent rows carry.
  """
  @spec across_spaces([Spaces.Space.t()]) :: [map()]
  def across_spaces(spaces) do
    Enum.map(spaces, fn %Spaces.Space{id: id} ->
      %{space_id: id, jobs: ShellJobs.list_space(id)}
    end)
  end
end
