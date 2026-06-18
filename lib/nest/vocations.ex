defmodule Nest.Vocations do
  @moduledoc """
  The Nest.Vocations context.
  """

  import Ecto.Query, warn: false
  alias Nest.Repo

  alias Nest.Vocations.Vocation

  @doc """
  Returns the list of vocations.

  ## Examples

      iex> list_vocations()
      [%Vocation{}, ...]

  """
  def list_vocations do
    Repo.all(Vocation)
  end

  @doc """
  Gets a single vocation.

  Raises `Ecto.NoResultsError` if the Vocation does not exist.

  ## Examples

      iex> get_vocation!(123)
      %Vocation{}

      iex> get_vocation!(456)
      ** (Ecto.NoResultsError)

  """
  def get_vocation!(id), do: Repo.get!(Vocation, id)

  @doc """
  Gets a single vocation.

  Returns `nil` if the Vocation does not exist.

  ## Examples

      iex> get_vocation(123)
      %Vocation{}

      iex> get_vocation(456)
      nil

  """
  def get_vocation(id), do: Repo.get(Vocation, id)

  @doc """
  Creates a vocation.

  ## Examples

      iex> create_vocation(%{field: value})
      {:ok, %Vocation{}}

      iex> create_vocation(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_vocation(attrs) do
    %Vocation{}
    |> Vocation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a vocation.

  ## Examples

      iex> update_vocation(vocation, %{field: new_value})
      {:ok, %Vocation{}}

      iex> update_vocation(vocation, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_vocation(%Vocation{} = vocation, attrs) do
    vocation
    |> Vocation.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a vocation.

  ## Examples

      iex> delete_vocation(vocation)
      {:ok, %Vocation{}}

      iex> delete_vocation(vocation)
      {:error, %Ecto.Changeset{}}

  """
  def delete_vocation(%Vocation{} = vocation) do
    Repo.delete(vocation)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking vocation changes.

  ## Examples

      iex> change_vocation(vocation)
      %Ecto.Changeset{data: %Vocation{}}

  """
  def change_vocation(%Vocation{} = vocation, attrs \\ %{}) do
    Vocation.changeset(vocation, attrs)
  end

  @doc """
  Resolves the capability map for a given mode on a vocation.

  * Returns `{:ok, caps}` when the mode exists on the vocation.
  * Returns `{:ok, default_caps()}` for the special mode `"chat"` when
    the vocation has no modes defined (the legacy/no-vocation case).
  * Returns `{:error, :unknown_mode}` when the mode isn't in the
    vocation's `modes` map.

  ## Examples

      iex> get_caps(vocation, "build")
      {:ok, %{"net" => false, "fs" => %{"read" => ["/"], "write" => []}}}

      iex> get_caps(%Vocation{modes: nil}, "chat")
      {:ok, Nest.Sandbox.default_caps()}

      iex> get_caps(vocation, "nonexistent")
      {:error, :unknown_mode}

  """
  @spec get_caps(Vocation.t() | nil, String.t()) ::
          {:ok, map()} | {:error, :unknown_mode}
  def get_caps(nil, "chat"), do: {:ok, Nest.Sandbox.default_caps()}
  def get_caps(_vocation, "chat"), do: {:ok, Nest.Sandbox.default_caps()}

  def get_caps(nil, _mode), do: {:error, :unknown_mode}

  def get_caps(%Vocation{modes: modes}, mode_name) when is_map(modes) do
    case Map.get(modes, mode_name) do
      %{"caps" => caps} -> {:ok, caps}
      _ -> {:error, :unknown_mode}
    end
  end

  def get_caps(%Vocation{}, _mode), do: {:error, :unknown_mode}

  @doc """
  Returns the sorted list of mode names for a vocation.

  Returns `["chat"]` for vocations with no modes defined (the
  legacy/no-vocation case where `"chat"` is the only valid mode).

  ## Examples

      iex> list_modes(%Vocation{modes: %{"build" => %{}, "plan" => %{}}})
      ["build", "plan"]

      iex> list_modes(%Vocation{modes: nil})
      ["chat"]

  """
  @spec list_modes(Vocation.t() | nil) :: [String.t()]
  def list_modes(nil), do: ["chat"]

  def list_modes(%Vocation{modes: nil}), do: ["chat"]

  def list_modes(%Vocation{modes: modes}) when map_size(modes) == 0 do
    ["chat"]
  end

  def list_modes(%Vocation{modes: modes}) when is_map(modes) do
    modes |> Map.keys() |> Enum.sort()
  end

  @doc """
  Returns the default mode for a vocation — the lexicographically
  first mode in `vocation.modes`, or `"chat"` if no modes are defined.

  Used by the frontend to pre-select the mode chip in the composer.
  """
  @spec default_mode(Vocation.t() | nil) :: String.t()
  def default_mode(vocation) do
    case list_modes(vocation) do
      [] -> "chat"
      [first | _] -> first
    end
  end

  @doc """
  Builds a human-readable catalog section describing the vocation's
  available modes, suitable for appending to the system prompt.

  Returns an empty string when the vocation has no modes (or has nil
  modes). The catalog is sorted alphabetically by mode name.
  """
  @spec mode_catalog(Vocation.t() | nil) :: String.t()
  def mode_catalog(nil), do: ""

  def mode_catalog(%Vocation{modes: nil}), do: ""
  def mode_catalog(%Vocation{modes: modes}) when map_size(modes) == 0, do: ""

  def mode_catalog(%Vocation{modes: modes}) do
    catalog =
      modes
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map_join("\n", fn {name, mode_def} ->
        description = Map.get(mode_def, "description", "")
        caps = Map.get(mode_def, "caps", %{})

        caps_text = caps_sentences(caps)
        description_text = if(description == "", do: "", else: description)

        line =
          if description_text == "" do
            "- #{name}: #{caps_text}."
          else
            "- #{name}: #{caps_text}. #{description_text}"
          end

        line
      end)

    "\n\n[Available modes]\n\n" <>
      "The user picks a mode per message via the UI. " <>
      "Each mode changes the sandbox profile (filesystem permissions, network access).\n\n" <>
      "#{catalog}\n"
  end

  # Builds the per-mode capabilities text from a caps map, as a
  # series of short sentences.
  #
  # The read/write lists come straight from `caps.fs.read` and
  # `caps.fs.write` — no implicit prepending of "/tmp" or workspace.
  # `":workspace"` is a symbolic placeholder that `Sandbox.build/2`
  # resolves to the agent's actual workspace path at runtime. We
  # render it as the bare name "workspace" in the catalog so the LLM
  # doesn't see the internal symbol.
  defp caps_sentences(%{"net" => net, "fs" => %{"read" => read, "write" => write}}) do
    [read_sentence(read), write_sentence(write), net_sentence(net)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(". ")
  end

  defp caps_sentences(_), do: "custom profile"

  defp read_sentence(["/"]), do: ~s(Read only "/")
  defp read_sentence([]), do: "No filesystem read"
  defp read_sentence([single]), do: "Read only #{format_path(single)}"

  defp read_sentence(paths) do
    "Read only #{format_list(Enum.map(paths, &format_path/1))}"
  end

  # Translates the caps.fs.write list into a human-readable sentence.
  # The symbolic placeholders ":workspace" and "/tmp" are rendered
  # unquoted (they're symbolic locations, not real paths the LLM
  # needs to spell out). Other entries are formatted as paths.
  #
  # Ordering: ":workspace" is moved to the front (so the natural
  # English reads "workspace and /tmp"), then "/tmp", then any
  # explicit extras in their original order.
  defp write_sentence([]), do: ""

  defp write_sentence(paths) do
    symbolic = [":workspace", "/tmp"]
    {sym_hits, extras} = Enum.split_with(paths, &(&1 in symbolic))

    ordered_symbols =
      Enum.sort_by(sym_hits, fn p -> Enum.find_index(symbolic, &(&1 == p)) end)

    rendered = Enum.map(ordered_symbols ++ extras, &format_path/1)
    "Read and write #{format_list(rendered)}"
  end

  # Symbolic names (":workspace", "/tmp") are rendered unquoted. Real
  # paths (starting with `/` or `:`) are wrapped in double-quotes so
  # the boundary between the path and surrounding text is clear.
  defp format_path(":workspace"), do: "workspace"
  defp format_path("/tmp"), do: "/tmp"
  defp format_path(<<"/", _::binary>> = path), do: ~s("#{path}")
  defp format_path(<<":", _::binary>> = path), do: ~s("#{path}")
  defp format_path(other), do: other

  defp net_sentence(true), do: "Network enabled"
  defp net_sentence(false), do: "Network disabled"

  # Renders a list as a human-readable enumeration with a final
  # "and": ["a"] -> "a", ["a", "b"] -> "a and b",
  # ["a", "b", "c"] -> "a, b, and c".
  defp format_list([single]), do: single
  defp format_list([a, b]), do: "#{a} and #{b}"

  defp format_list(list) do
    {last, rest} = List.pop_at(list, -1)
    "#{Enum.join(rest, ", ")}, and #{last}"
  end
end
