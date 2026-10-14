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
  onto the same vocabulary.

  `effective/2` picks between a static `multi-modal` and the
  discovered value for the merged catalog entry: static config is
  authoritative and is never overwritten by a differing discovery
  answer.
  """

  alias Nest.DotConfig.Provider
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
    do: resolve(provider, name, detected, &MultimodalProbe.probe/2)

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
end
