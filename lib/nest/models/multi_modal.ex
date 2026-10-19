defmodule Nest.Models.MultiModal do
  @moduledoc """
  The three-valued multi-modal input vocabulary for a discovered model.

  Image-input support has three states, and the merged catalog keeps
  them distinct because `file-read` refuses a media part differently
  for each:

    * **positive** — `%{"input" => ["image"]}`: the provider says the
      model takes images;
    * **negative** — `%{"input" => []}`: the provider publishes a
      modality list and it does not name `"image"` — a text-only model;
    * **unknown** — `nil`: the provider publishes no modality field we
      recognize.

  `resolve/3` derives that value for one discovered model.
  `Nest.LLM.Discover` reads the provider's `/models` body; a definite
  answer from it is always kept. Only when the body says nothing *and*
  the provider opted in with `probe-multimodal = true` is the model
  handed to `Nest.LLM.MultimodalProbe`, whose three-valued answer maps
  onto the same vocabulary. That probe is the expensive one — a request
  per model — so its answer is kept in `Nest.LLM.MultimodalCache` and
  reused until it expires or the provider's endpoint changes.

  `effective/2` picks between a static `multi-modal` and the
  discovered value for the merged catalog entry: static config is
  authoritative and is never overwritten by a differing discovery
  answer.

  `input_support/2` is the *reader* of that vocabulary for a model the
  runtime only knows by name: it answers the same three states for a
  merged catalog entry, and it is the one place both readers of the answer
  go through — `file-read`'s media gate, which refuses an image on
  anything but `:supported`, and the system prompt's model section, which
  states the verdict to the agent.
  """

  alias Nest.DotConfig.Provider
  alias Nest.LLM.MultimodalCache
  alias Nest.LLM.MultimodalProbe

  @image_input %{"input" => ["image"]}
  @text_only %{"input" => []}

  @doc """
  The multi-modal vocabulary for `name` as discovered from `provider`.

  `detected` is what the provider's `/models` body said: `nil` when it
  published no recognized modality field. The probe runs only for a
  provider with `probe_multimodal: true` and only while `detected` is
  `nil`.
  """
  @spec resolve(Provider.t(), String.t(), map() | nil) :: map() | nil
  def resolve(%Provider{} = provider, name, detected),
    do: resolve(provider, name, detected, &cached_probe/2)

  # A cached verdict answers for free; a miss falls through to the real
  # probe and remembers what it settles on. `:unknown` is not a finding
  # and is deliberately not stored (`MultimodalCache.put/3` ignores it),
  # so a provider that is momentarily unreachable is probed again next
  # scan instead of staying unknown for a week.
  defp cached_probe(provider, name) do
    case MultimodalCache.get(provider, name) do
      :positive -> :positive
      :negative -> :negative
      nil -> probe_and_cache(provider, name)
    end
  end

  defp probe_and_cache(provider, name) do
    case MultimodalProbe.probe(provider, name) do
      :unknown ->
        :unknown

      verdict ->
        MultimodalCache.put(provider, name, verdict)
        verdict
    end
  end

  @doc false
  # The probe seam: probing costs a request per model, and its gate is
  # worth testing without the real HTTP call, so the two-argument probe
  # is passed in. `resolve/3` is the only caller in production code.
  @spec resolve(Provider.t(), String.t(), map() | nil, (Provider.t(), String.t() ->
                                                          :positive | :negative | :unknown)) ::
          map() | nil
  def resolve(%Provider{probe_multimodal: true} = provider, name, nil, probe) do
    case probe.(provider, name) do
      :positive -> @image_input
      :negative -> @text_only
      :unknown -> nil
    end
  end

  def resolve(_provider, _name, detected, _probe), do: detected

  @doc """
  The multi-modal vocabulary for a merged catalog entry. An explicit
  static `multi-modal` is authoritative and is never overwritten by a
  differing discovery answer; detection is a fill-in for when static
  config sets nothing.

  When static config has no entry at all, `model` *is* the
  auto-discovered entry and already carries the detected value, so the
  first clause covers it. Otherwise the fill-in is looked up for this
  model's own {provider, name} pair — the key the context-limit cache
  uses — so a same-named model discovered under a *different* provider
  cannot contribute a capability this one lacks.
  """
  @spec effective(map(), map()) :: map() | nil
  def effective(%{multi_modal: static}, _auto) when static != nil, do: static

  def effective(model, auto) do
    case Map.get(auto, model.name) do
      %{provider_name: provider, multi_modal: detected} ->
        if provider == model.provider_name, do: detected, else: nil

      _ ->
        nil
    end
  end

  @doc """
  What the merged catalog declares about `modality` input for the model named
  `model_name`: `:supported`, `:unsupported` or `:unknown`.

  It is a catalog lookup rather than a field read because the persisted model is
  `%{name, provider, thinking_level}` — `multi_modal` is not on the row — so a
  caller holding an agent's model has only its name.

  Matched on **name alone**: the callers hold a name and no provider
  (`Nest.LLM.ClientConfig`'s `model` is a string, and the row's name is what the
  prompt states), and the catalog merges models from every provider by name. A
  positive claim from any provider serving that model is the best evidence
  available, so it wins over a negative one.

  `:unknown` is not a claim of support, and it is not a claim of text-only
  either: it is "nothing declares this", which is why a caller must word it
  differently from `:unsupported`. A name no catalog entry has — including a
  name that is not a usable binary — is `:unknown` for the same reason.

  Two readers depend on this being one answer: `Nest.Tools.FileTools`' media gate
  (which refuses an image on anything but `:supported`) and
  `Nest.Agents.Agent.SystemPrompt`'s model section (which tells the agent what
  its own model accepts).
  """
  @spec input_support(String.t() | nil, atom()) :: :supported | :unsupported | :unknown
  def input_support(model_name, modality) when is_binary(model_name) and model_name != "" do
    name = Atom.to_string(modality)

    declarations =
      Nest.Models.list()
      |> Enum.filter(&(&1["name"] == model_name))
      |> Enum.map(&declared_inputs/1)
      |> Enum.reject(&is_nil/1)

    cond do
      declarations == [] -> :unknown
      Enum.any?(declarations, &(name in &1)) -> :supported
      true -> :unsupported
    end
  end

  def input_support(_model_name, _modality), do: :unknown

  # The input modalities one merged catalog entry declares, or `nil` when it
  # declares none. `%{"input" => []}` is a declaration of no input modalities at
  # all, so it is `[]` here rather than `nil`.
  defp declared_inputs(%{"multi_modal" => %{"input" => inputs}}) when is_list(inputs), do: inputs
  defp declared_inputs(_entry), do: nil
end
