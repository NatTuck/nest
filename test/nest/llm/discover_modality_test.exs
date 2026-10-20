defmodule Nest.LLM.DiscoverModalityTest do
  @moduledoc """
  `Discover.extract_multi_modal_from_model/1`: how each recognized provider
  shape's modality field normalizes to the static TOML vocabulary.

  Split out of `Nest.LLM.DiscoverTest`, which went over the file-length cap
  (issue #80) once the non-positive-limit test landed. This block shares
  nothing with the rest of that file — no `build_config/1`, no `Mimic`, no
  `Req` — so it moves cleanly and stays a unit test of the pure extractor.
  """

  use ExUnit.Case, async: true

  alias Nest.LLM.Discover

  describe "extract_multi_modal_from_model/1" do
    # Every recognized shape normalizes to the static TOML vocabulary
    # (`multi-modal = { input = ["image"] }` in config.toml), and every
    # shape answers all three ways: positive, a *negative* (the body
    # publishes input modalities and none is "image"), and *unknown* (no
    # modality field we recognize). The negative/unknown split is the
    # point — `file-read` refuses a media part differently for each.
    test "normalizes each recognized provider shape to the static vocabulary" do
      # OpenRouter: the measured shape lists every modality the model
      # accepts. Only "image" is in our vocabulary.
      assert Discover.extract_multi_modal_from_model(%{
               "id" => "openai/gpt-4o",
               "architecture" => %{"input_modalities" => ["text", "image", "file"]}
             }) == %{"input" => ["image"]}

      # atlascloud: the same list at the top level.
      assert Discover.extract_multi_modal_from_model(%{
               "id" => "atlas-model",
               "input_modalities" => ["image", "text"]
             }) == %{"input" => ["image"]}

      # Anthropic: a capability flag rather than a modality list.
      assert Discover.extract_multi_modal_from_model(%{
               "id" => "claude-3-opus-20240229",
               "capabilities" => %{"image_input" => %{"supported" => true}}
             }) == %{"input" => ["image"]}
    end

    test "reports a published modality list without \"image\" as text-only" do
      # A list is the provider *declaring* input, so "no image" is an
      # answer of its own — an empty `input` list, not `nil`. (Live:
      # DeepSeek's `deepseek-v4-pro` reports `["text"]`.)
      assert Discover.extract_multi_modal_from_model(%{
               "id" => "deepseek-v4-pro",
               "input_modalities" => ["text"]
             }) == %{"input" => []}

      # An empty list is still a list: the provider declared that the
      # model accepts no input modality at all.
      assert Discover.extract_multi_modal_from_model(%{
               "id" => "text-only",
               "input_modalities" => []
             }) == %{"input" => []}

      # Anthropic's flag is a declaration in both directions.
      assert Discover.extract_multi_modal_from_model(%{
               "id" => "claude-3-opus-20240229",
               "capabilities" => %{"image_input" => %{"supported" => false}}
             }) == %{"input" => []}
    end

    test "returns nil when no recognized shape publishes a modality field" do
      # Nothing at all.
      assert Discover.extract_multi_modal_from_model(%{"id" => "no-metadata"}) == nil

      # A malformed (non-list) modality field is not a shape we can
      # read, so the answer stays unknown rather than claiming a
      # negative. Both positions are pinned because each is its own
      # guard clause.
      assert Discover.extract_multi_modal_from_model(%{
               "id" => "no-metadata",
               "input_modalities" => "image"
             }) == nil

      assert Discover.extract_multi_modal_from_model(%{
               "id" => "no-metadata",
               "architecture" => %{"input_modalities" => "text"}
             }) == nil

      # An Anthropic capability object with a non-boolean `supported`
      # says nothing.
      assert Discover.extract_multi_modal_from_model(%{
               "id" => "claude-3-opus-20240229",
               "capabilities" => %{"image_input" => %{"supported" => "yes"}}
             }) == nil
    end

    test "returns nil for a non-map entry" do
      assert Discover.extract_multi_modal_from_model(nil) == nil
      assert Discover.extract_multi_modal_from_model("not-a-model") == nil
    end

    test "prefers a modality list over the capability flag, and nested over flat" do
      assert Discover.extract_multi_modal_from_model(%{
               "id" => "both-shapes",
               "architecture" => %{"input_modalities" => ["text", "image"]},
               "input_modalities" => ["text"]
             }) == %{"input" => ["image"]}

      # An explicit list is the stronger statement, so it is consulted
      # first: a text-only list outranks a capability flag that says
      # otherwise. (Flag-first would answer `%{"input" => ["image"]}`.)
      assert Discover.extract_multi_modal_from_model(%{
               "id" => "list-says-no-flag-says-yes",
               "architecture" => %{"input_modalities" => ["text"]},
               "capabilities" => %{"image_input" => %{"supported" => true}}
             }) == %{"input" => []}

      # The nested shape only wins when it is actually published: an
      # `architecture` object without a usable list falls through to the
      # flat field.
      assert Discover.extract_multi_modal_from_model(%{
               "id" => "both-shapes",
               "architecture" => %{"tokenizer" => "cl100k"},
               "input_modalities" => ["text"]
             }) == %{"input" => []}

      # Nested-wins has a sharp edge, pinned here as the documented
      # consequence: a nested list that omits "image" answers *text-only* even
      # when the flat list names it -- a wrong negative rather than an unknown.
      # Reading the shapes as a union would answer `%{"input" => ["image"]}`.
      assert Discover.extract_multi_modal_from_model(%{
               "id" => "nested-says-no-flat-says-yes",
               "architecture" => %{"input_modalities" => ["text"]},
               "input_modalities" => ["text", "image"]
             }) == %{"input" => []}
    end
  end
end
