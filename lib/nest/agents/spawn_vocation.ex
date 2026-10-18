defmodule Nest.Agents.SpawnVocation do
  @moduledoc """
  Which vocation a spawned child gets, and what the model is told when it may not
  have one.

  Split out of `Nest.Agents.Supervisor` (which is at the credo file-length cap)
  because it is a self-contained decision: a slug the caller named, or the
  space's blueprint default, held against the blueprint's `spawnable_vocations`
  whitelist. `Nest.Agents.Supervisor.resolve_spawn_vocation/2` delegates here, so
  the docs that describe the rules still name the supervisor.

  An **unnamed** vocation is never invented: the space's blueprint says which one
  an unnamed spawn gets, and when the blueprint says nothing the caller's own
  vocation is exactly the wrong thing to fall back to (a `programmer` coordinator
  spawning a reviewer would get another `programmer`). The refusal names the
  missing argument, and the vocations the space does allow when it is restricted.
  """

  alias Nest.Spaces
  alias Nest.Vocations
  alias Nest.Vocations.Vocation

  @doc """
  Resolve the effective `vocation_id` for a fresh spawn, applying the blueprint's
  whitelist. See `Nest.Agents.Supervisor.spawn_agent_in_space/5`'s doc for the
  resolution rules.

  Refusals carry the whitelisted vocations (as `{name, slug}` labels) so the
  caller can tell the model what it may actually spawn.
  """
  @spec resolve(map(), String.t() | nil) ::
          {:ok, integer()}
          | {:error,
             {:vocation_not_found, String.t()}
             | {:vocation_required, [{String.t(), String.t()}]}
             | {:vocation_not_spawnable, [{String.t(), String.t()}]}}
  def resolve(parent_state, requested)
      when is_binary(requested) and requested != "" do
    case Vocations.get_by_slug(requested) do
      nil ->
        {:error, {:vocation_not_found, requested}}

      %Vocation{id: id} ->
        allowed = Spaces.spawnable_vocations_for_space(parent_state.space_id)

        if slug_allowed?(allowed, requested) do
          {:ok, id}
        else
          {:error, vocation_error(allowed)}
        end
    end
  end

  # No `vocation` was named — or a blank one was, which is the same request, and
  # which is why this clause catches `""` rather than sending it to
  # `Vocations.get_by_slug/1` as a slug that cannot exist.
  #
  # The space's blueprint says which vocation an unnamed spawn gets. When the
  # blueprint says nothing there is no answer to invent, and the caller's own
  # vocation is exactly the wrong one to invent: a `programmer` coordinator
  # spawning a reviewer would get another `programmer`, which is the glitch this
  # replaces. Refuse, naming the argument the model has to supply — and the
  # vocations it may pick from, when the space is restricted.
  def resolve(parent_state, _omitted) do
    case Spaces.default_spawnable_vocation_for_space(parent_state.space_id) do
      nil -> {:error, {:vocation_required, default_refusal_labels(parent_state)}}
      slug -> resolve(parent_state, slug)
    end
  end

  defp default_refusal_labels(parent_state) do
    parent_state.space_id
    |> Spaces.spawnable_vocations_for_space()
    |> Kernel.||([])
    |> vocation_labels()
  end

  # `nil`/`[]` from `spawnable_vocations_for_space/1` mean the
  # space is unrestricted (anything is allowed).
  defp slug_allowed?(nil, _slug), do: true
  defp slug_allowed?([], _slug), do: true
  defp slug_allowed?(allowed, slug), do: slug in allowed

  defp vocation_error(allowed) do
    {:vocation_not_spawnable, vocation_labels(allowed)}
  end

  # Resolve the allowed vocation slugs to `{name, slug}` labels for the
  # model-facing error message. Missing/deleted slugs degrade to a
  # placeholder rather than crashing.
  defp vocation_labels(slugs) when is_list(slugs) do
    by_slug = Map.new(Vocations.list_vocations(), &{&1.slug, &1.name})
    Enum.map(slugs, fn slug -> {Map.get(by_slug, slug, "<#{slug}>"), slug} end)
  end
end
