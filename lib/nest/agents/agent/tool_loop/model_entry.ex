defmodule Nest.Agents.Agent.ToolLoop.ModelEntry do
  @moduledoc """
  Renders one `Models.list/0` entry as a single `models-list` line.

  The line is the `provider/model-name` string the caller feeds to
  `agents-spawn`'s `model` argument, followed by the fields that decide whether
  it is the *right* model. A field is rendered only when it carries information,
  so a model with nothing to say keeps the bare `provider/model-name` line and
  the listing does not widen.

  A value that cannot be read renders as `<prefix>: invalid` rather than being
  omitted: omitting it would let a broken config pass for a field that said
  nothing, which is a different and false claim. `nil`, by contrast, really does
  mean "no claim was made" and renders nothing — see `input_field/1`.

  Extracted from `Nest.Agents.Agent.ToolLoop`, which was at 693 of its 700-line
  cap: this is a self-contained unit and issue #80's remedy is to extract a
  coherent unit before the file is next touched.
  """

  @doc """
  Format `entry` against the `exposed` providers (keyed by name).
  """
  @spec format(map(), map()) :: String.t()
  def format(%{"provider" => provider, "name" => name} = entry, exposed) do
    fields =
      [input_field(entry), ctx_field(entry), tags_field(entry, exposed)]
      |> Enum.reject(&is_nil/1)

    Enum.join(["#{provider}/#{name}" | fields], "  ")
  end

  # `multi_modal` is a pass-through map — from TOML config, from the
  # discovery cache, or from a static `DotConfig.Model` — so it is read
  # with `Map.get/3` and never destructured: a model entry may carry no
  # key at all, and a hand-written `multi-modal = { image = true }`
  # reaches us verbatim. The canonical shape is `%{"input" => [...]}`.
  # `"image"` is the only modality discovery reports, but static config
  # may name others, so the list is joined rather than matched.
  #
  # `nil` renders nothing rather than an explicit "none": it means *no
  # claim was made*, which is not the same as "cannot see images".
  # `Discover.extract_multi_modal_from_model/1` keeps those apart — a
  # provider that publishes a modality list without `"image"` reports
  # `%{"input" => []}` (rendered `input: none` below), and only a body
  # with no modality field we recognize reports `nil`.
  # Rendering `input: none` for the latter would turn "we were not told"
  # into a false negative.
  defp input_field(entry) do
    case Map.get(entry, "multi_modal") do
      nil -> nil
      %{"input" => []} -> "input: none"
      %{"input" => list} when is_list(list) -> list_field(list, "input")
      _malformed -> "input: invalid"
    end
  end

  # Renders a list of names as `<prefix>: <a,b>`, or `<prefix>: invalid` when
  # it is not one we can read — so a broken config never passes for a field
  # that said nothing. Callers decide what an empty list means: `input`
  # renders it `none`, `tags` omits the field.
  defp list_field(list, prefix) when is_list(list) do
    if joinable?(list), do: "#{prefix}: " <> Enum.join(list, ","), else: "#{prefix}: invalid"
  end

  defp list_field(_unreadable, prefix), do: "#{prefix}: invalid"

  defp ctx_field(entry) do
    case Map.get(entry, "context_limit") do
      limit when is_integer(limit) -> "ctx: #{limit}"
      _ -> nil
    end
  end

  # Tags live on the provider, not the model. `Models.list/0` does not
  # carry them — adding the key would change the lobby payload for every
  # model, and `models.ex` is close to its line cap — so they are read
  # from the provider struct the listing already loaded.
  defp tags_field(entry, exposed) do
    provider = Map.get(exposed, Map.get(entry, "provider"), %{})
    tags = Map.get(provider, :tags)

    unless tags in [nil, []], do: list_field(tags, "tags")
  end

  # `multi_modal` and `tags` reach us unvalidated from discovery, so an element
  # that is not a name we can render — `input = [{ a = 1 }]`, `tags = [1]` —
  # must not reach `Enum.join/2`, which raises on some non-binaries.
  defp joinable?(values), do: Enum.all?(values, &is_binary/1)
end
