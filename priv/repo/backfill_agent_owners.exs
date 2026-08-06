# Backfill script: assign a default `created_by_user_id` to
# every existing agent row, so the new visibility filter in
# the lobby continues to see pre-multi-user agents under
# some account.
#
# Usage (run inside a Mix project after `mix ecto.migrate`):
#
#     # Pick a specific user
#     mix run priv/repo/backfill_agent_owners.exs --user admin
#
#     # Or: pick the first user in the table (default fallback)
#     mix run priv/repo/backfill_agent_owners.exs
#
# Idempotent: subsequent runs only touch rows whose
# `created_by_user_id IS NULL`. After this script reports
# "0 updated" the DB is fully owned.
#
# Notes:
#   - Requires at least one user to exist. If the users
#     table is empty the script aborts and points the
#     operator at the bootstrap path
#     (`/register?token=first-user`).
#   - The script does NOT touch shared/private state — those
#     defaults are unchanged. Agents created via this script
#     are private (owned, not shared).

defmodule BackfillAgentOwners do
  import Ecto.Query

  alias Mix.Task
  alias Nest.Accounts
  alias Nest.Accounts.User
  alias Nest.Agents.PersistedAgent
  alias Nest.Repo

  @switches [user: :string]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    Repo.start_link()
    {:ok, _} = Application.ensure_all_started(:nest)

    owner = resolve_owner(opts)
    updated = backfill(owner)

    Mix.shell().info(
      "Backfill complete: #{updated} agent row(s) assigned to user id=#{owner.id} (#{owner.username})."
    )

    :ok
  end

  defp resolve_owner(opts) do
    cond do
      username = opts[:user] ->
        Repo.get_by(User, username: String.downcase(username))

      true ->
        Repo.one(from u in User, order_by: [asc: u.id], limit: 1)
    end
    |> case do
      nil ->
        Mix.shell().error("""
        No user found. Create one first:

            Visit /register?token=first-user   (browser)
            or POST /api/v1/register            (curl)
        """)

        Task.re_raise("backfill_agent_owners: no user available")

      %User{id: id, username: username} = user ->
        Mix.shell().info("Using user id=#{id} (#{username}) as the backfill owner.")
        user
    end
  end

  defp backfill(%User{id: owner_id}) do
    {updated, _} =
      Repo.transaction(fn ->
        Repo.update_all(
          from(a in PersistedAgent, where: is_nil(a.created_by_user_id)),
          set: [created_by_user_id: owner_id]
        )
      end)

    updated
  end
end

BackfillAgentOwners.run(System.argv())