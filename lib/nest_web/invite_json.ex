defmodule NestWeb.InviteJSON do
  @moduledoc """
  JSON shape for invite rows sent over the lobby channel.

  The `token` field is intentionally included in every push
  (init, `invite:created`, etc.). The plaintext token lives
  in the `invites.token` column as stored; the UI always
  surfaces it alongside the row so the user can copy it.
  There is no server-side hash to mask.

  Used by the lobby channel's `:after_join` push and the
  `create_invite` reply/push. Mirrored on the JS side via
  the `useStore` `invites` slice + `setInvites` action.
  """

  def public_invite(invite) do
    %{
      id: invite.id,
      created_by_user_id: invite.created_by_user_id,
      token: invite.token,
      expires_at: invite.expires_at,
      used_by_user_id: invite.used_by_user_id,
      used_at: invite.used_at,
      revoked_at: invite.revoked_at,
      inserted_at: invite.inserted_at
    }
  end
end
