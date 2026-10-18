defmodule NestWeb.LobbyChannel.SpaceFeed do
  @moduledoc """
  The space feed's transport: its initial read, the composer's send, and the
  `user_note:created` push.

  The feed is `/space/:slug` — the space's **note log**, one table
  (`user_notes`) read by the human at one end of each row. It is deliberately not
  the transcript: tool calls, tool results, thinking blocks and compaction
  markers are the *agent* page's (`/space/:slug/agent/:name`), which is why
  nothing here reads `messages`. The feed answers "what did we say to each
  other"; the agent page answers "what did this agent do".

  ## Why the lobby carries it

  Every `user_notes` insert broadcasts `{:user_note, %UserNote{}}` on the space's
  topic (`Nest.Agents.Agent.Broadcasts.space_topic/1`), and `NestWeb.LobbyChannel`
  already subscribes to that topic for every space its user can see. So the feed
  needs no new socket, no new channel and no new topic: a PubSub frame becomes a
  `user_note:created` push, and the composer's send is one `handle_in`.

  ## The wire

  | direction | event | payload |
  |---|---|---|
  | client → server | `space_feed` | `%{"space_id" => integer}` |
  | server → client | (its reply) | `%{"notes" => [row], "modes" => [name], "default_mode" => name}` |
  | client → server | `send_note` | `%{"space_id" => integer, "to" => name, "content" => text, "mode" => name \\| nil}` |
  | server → client | (its reply) | `%{"disposition" => "delivered" \\| "queued"}` |
  | server → client | `user_note:created` | `%{"note" => row}` |

  A `row` is `Nest.Notes.UserNote`'s own JSON — its `@derive`d field list — so
  the client renders exactly the columns the table has and nothing derived, and
  a column added to that list reaches the feed without a second mapping here.

  `modes` and `default_mode` ride the read because the feed is the one page with
  no agent channel behind it, and a mode is not something the browser may invent:
  `Nest.Modes.names/0` is the authority on which modes exist, and the space's
  blueprint says which one a message from here asks for by default. Both come
  from the same modules `NestWeb.AgentChannel`'s `init` uses, so the two pages
  cannot disagree about the catalog.

  ## Scoping

  Two predicates, and both are needed:

    * **the space** — `Authz.authorize_space_owner/2`, the check `archive_space`
      already makes and exactly the set `after_join` subscribes to. A client
      names the space it is asking about, so it cannot read one it is not in.
    * **the human at one end** — `Nest.Notes.for_user?/2`, which is
      `Nest.Notes.list_for/2`'s rule asked about one row. The space's topic
      reaches every session of every human in the space, and a note between two
      other humans is in the space and is none of this human's business. The push
      applies the same predicate as the read, so a frame can never show a note
      the next read would not return.
  """

  require Logger

  alias Nest.Address
  alias Nest.Agents
  alias Nest.Blueprints
  alias Nest.Modes
  alias Nest.Notes
  alias Nest.Spaces
  alias NestWeb.ErrorPayload
  alias NestWeb.LobbyChannel.Authz

  @doc """
  The feed's initial read (`space_feed`): the notes the caller is an end of, the
  mode catalog, and the mode a message from this feed asks for by default.

  The notes are `Nest.Notes.list_for/2` — `id` order, which is the table's own
  monotonic key, so `inserted_at` is for display only.
  """
  @spec read(map(), Phoenix.Socket.t()) :: {:reply, term(), Phoenix.Socket.t()}
  def read(%{"space_id" => space_id}, socket) when is_integer(space_id) do
    case Authz.authorize_space_owner(space_id, socket.assigns.current_user) do
      {:ok, :owner} ->
        {:reply, {:ok, feed_payload(space_id, socket)}, socket}

      {:error, reason} ->
        {:reply, {:error, ErrorPayload.from_reason(reason)}, socket}
    end
  end

  def read(_payload, socket), do: {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}

  @doc """
  The composer's send (`send_note`): one **`:query`** from the caller to the
  agent they picked.

  A query and not a plain note, because a query is what makes the recipient owe
  a reply — and an agent that owes `@nat` a reply is an agent that will answer
  (`notes/space-chat.md` § "The conversation loop"). The reply itself is the
  agent's own `agents-send`, not a turn's output: picking one assistant message
  out of a turn would be a guess.

  The send also writes the human's side of it (`Nest.Notes`' row, which is what
  the feed reads) and clears the queries that agent had outstanding
  (`Nest.Notes.mark_answered/3`), so the composer is the banner's clear as well
  as its cause.
  """
  @spec send_note(map(), Phoenix.Socket.t()) :: {:reply, term(), Phoenix.Socket.t()}
  def send_note(%{"space_id" => space_id, "to" => to, "content" => content} = payload, socket)
      when is_integer(space_id) and is_binary(to) and is_binary(content) do
    mode = payload["mode"]

    with :ok <- validate(content, mode),
         {:ok, :owner} <- Authz.authorize_space_owner(space_id, socket.assigns.current_user) do
      reply_with_delivery(space_id, to, content, mode, socket)
    else
      {:error, reason} -> {:reply, {:error, ErrorPayload.from_reason(reason)}, socket}
    end
  end

  def send_note(_payload, socket),
    do: {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}

  @doc """
  One `user_note:created` frame for a note the caller is an end of.

  The space is already scoped by the subscription the frame arrived on (see the
  moduledoc); the human at one end is not, so it is checked here.
  """
  @spec note_created(Notes.UserNote.t(), Phoenix.Socket.t()) ::
          {:noreply, Phoenix.Socket.t()}
  def note_created(%Notes.UserNote{} = note, socket) do
    if Notes.for_user?(note, me(socket)) do
      Phoenix.Channel.push(socket, "user_note:created", %{"note" => note})
    end

    {:noreply, socket}
  end

  # ---- private ----

  defp feed_payload(space_id, socket) do
    %{
      "notes" => Notes.list_for(space_id, me(socket)),
      "modes" => Modes.names(),
      "default_mode" => default_mode(space_id)
    }
  end

  # The human whose feed this is: the socket's user, as the parsed address
  # `Nest.Notes` takes (`{:user, username}`). Built here rather than sent by the
  # client, so a client cannot read or speak as somebody else.
  defp me(socket), do: {:user, socket.assigns.current_user.username}

  # The mode a message from this feed asks for by default. A blueprint's
  # `default_mode` is `NOT NULL`, so the second arm is only a space that names no
  # blueprint — and there `Nest.Modes`' own default is the answer, the same value
  # `Nest.Agents.Agent.PreSpawn` gives a new agent in such a space. Computed
  # here rather than in the browser because a mode name is a code constant, and a
  # client that guessed one would be a second authority on which modes exist.
  defp default_mode(space_id) do
    with %{blueprint_id: id} when is_integer(id) <- Spaces.get_space(space_id),
         %{default_mode: mode} when is_binary(mode) <- Blueprints.get_blueprint(id) do
      mode
    else
      _ -> Modes.default()
    end
  end

  # A blank note is not a note, and a mode this build does not know must not
  # reach the agent: `Nest.Modes` refuses it in the sandbox, but the message
  # would still claim it. Both are refused before anything is written.
  defp validate(content, mode) do
    cond do
      String.trim(content) == "" -> {:error, :blank_content}
      is_nil(mode) or Modes.valid?(mode) -> :ok
      true -> {:error, :invalid_mode}
    end
  end

  defp reply_with_delivery(space_id, to, content, mode, socket) do
    case deliver(space_id, to, content, mode, socket) do
      {:ok, disposition} ->
        {:reply, {:ok, %{"disposition" => Atom.to_string(disposition)}}, socket}

      # The one refusal the composer can act on: the picker offered an agent the
      # server no longer has. The target is named so the banner can say which.
      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "agent_not_found", "target" => to}}, socket}

      {:error, reason} ->
        {:reply, {:error, ErrorPayload.from_reason(reason)}, socket}
    end
  end

  # `Nest.Agents.send_note/6` reaches the target's `GenServer.call` (5 s). An
  # exit there would take the whole lobby channel down — and with it every frame
  # this session is waiting on — so it is answered as a failed send the composer
  # can show. Same reasoning as `LobbyChannel.safe_models_list/0`.
  defp deliver(space_id, to, content, mode, socket) do
    Agents.send_note(space_id, Address.format(me(socket)), to, content, :query, mode)
  catch
    :exit, reason ->
      Logger.error("space feed send to #{inspect(to)} exited: #{inspect(reason)}")
      {:error, :timeout}
  end
end
