defmodule NestWeb.LobbyChannel.Invites do
  @moduledoc """
  Invite-related `handle_in` handlers for the LobbyChannel,
  extracted so the parent module stays under the credo 500-
  line cap.

  Pure functions over `(payload, socket)` — returns the
  same shape `handle_in/3` is expected to (a
  `{:reply, reply, socket}` tuple). Side effects (push to
  the socket) happen here, no logging at this layer.

  ## Permission rules

    * `create_invite` — any authenticated user can mint a
      invite; `Accounts.create_invite/1` enforces the 10-
      per-user cap (counts active + used + revoked) and
      returns `{:error, :too_many_invites}` when full.
    * `revoke_invite` — only the invite's
      `created_by_user_id` may revoke it
      (`Accounts.revoke_invite/2` enforces ownership; this
      module surfaces its error shape to the JS side).
  """

  alias Nest.Accounts
  alias NestWeb.InviteJSON

  @doc """
  Issue a fresh invite for the caller. The reply is
  `{:ok, invite}` on success, `{:error, %{error: ...}}` on
  the typical failure modes — the JS side surfaces the
  error string via `setInvitesError`. The successful path
  also pushes `invite:created` so the InvitesPage's
  in-memory list updates without a re-fetch.
  """
  def create_invite(_payload, socket) do
    user = socket.assigns.current_user

    case Accounts.create_invite(user.id) do
      {:ok, invite, _token} ->
        public = InviteJSON.public_invite(invite)
        Phoenix.Channel.push(socket, "invite:created", public)
        {:reply, {:ok, public}, socket}

      {:error, :too_many_invites} ->
        {:reply, {:error, %{error: "too_many_invites"}}, socket}

      {:error, _cs} ->
        {:reply, {:error, %{error: "failed_to_create_invite"}}, socket}
    end
  end

  @doc """
  Revoke a previously-issued invite. The id comes from the
  `"id"` payload field. The JS client sends it as a JSON
  number (so it decodes to an integer here), but older
  clients may send it as a string; both shapes are
  accepted. `Accounts.revoke_invite/2` enforces ownership.
  On success, push `invite:revoked` so the UI can drop
  the row without re-fetching.
  """
  def revoke_invite(%{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, int_id} <- coerce_invite_id(id),
         :ok <- Accounts.revoke_invite(int_id, user.id) do
      Phoenix.Channel.push(socket, "invite:revoked", %{id: int_id})
      {:reply, :ok, socket}
    else
      {:error, reason} ->
        {:reply, {:error, %{error: Atom.to_string(reason)}}, socket}

      :invalid_id ->
        {:reply, {:error, %{error: "invalid_id"}}, socket}
    end
  end

  # Normalize the wire-shape `id` (JSON number → integer,
  # string → integer) into a parsed integer. Returns
  # `:invalid_id` for non-integer strings or other shapes.
  defp coerce_invite_id(id) when is_integer(id), do: {:ok, id}

  defp coerce_invite_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> {:ok, int_id}
      _ -> :invalid_id
    end
  end

  defp coerce_invite_id(_), do: :invalid_id
end
