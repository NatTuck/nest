defmodule Nest.Models.MultiModalTest do
  @moduledoc """
  The three-valued multi-modal vocabulary, and the gate that decides
  whether a model is handed to `Nest.LLM.MultimodalProbe`.

  `resolve/4` takes the probe as an argument, so the gate is pinned
  without an HTTP call. The seam the two changes are joined at --
  `resolve/3` calling the *real* `Nest.LLM.MultimodalProbe.probe/2` --
  is exercised too, with `Req` stubbed, so nothing there is faked.
  """
  use ExUnit.Case, async: true

  import Mimic

  alias Nest.DotConfig
  alias Nest.LLM.MultimodalCache
  alias Nest.Models.MultiModal

  setup :verify_on_exit!

  # `resolve/3` consults the probe cache on every miss, and stores what the
  # probe settles on. These tests are about the gate and the probe, not about
  # the file: without these stubs a run would read and write the real cache
  # file, and one run's verdict would answer the next run's probe. The cache
  # itself is pinned in `test/nest/llm/multimodal_cache_test.exs`, and each
  # test below that expects a verdict to be stored says so explicitly.
  setup do
    Mimic.stub(MultimodalCache, :get, fn _provider, _name -> nil end)
    Mimic.stub(MultimodalCache, :put, fn _provider, _name, _verdict -> :ok end)
    :ok
  end

  @image %{"input" => ["image"]}
  @text_only %{"input" => []}

  # Exactly right for the probe's image A and image B respectively, and
  # different from each other. The ground truth is documented in
  # `Nest.LLM.MultimodalProbe`, and the probe's own tests pin the payloads.
  @answer_a "There are 4 shapes and the largest is the green circle."
  @answer_b "There are 7 shapes and the largest is a yellow triangle."

  # The measured real-world rejection OpenRouter returns when none of the
  # endpoints behind a model accept image input.
  @rejection %{
    "error" => %{"message" => "No endpoints found that support image input", "code" => 404}
  }

  # A provider configured well enough for the probe to build a request: a
  # base URL it can speak, an OpenAI protocol, a literal key, and the opt-in.
  defp opted_in(overrides \\ []) do
    struct!(
      %DotConfig.Provider{
        name: "p",
        base_url: "http://provider.test",
        api_key: "sk-test-key",
        protocol: "openai",
        timeout_seconds: 30,
        probe_multimodal: true
      },
      overrides
    )
  end

  defp openai_answer(text) do
    {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}}]}}}
  end

  defp rejected(status, body), do: {:ok, %{status: status, body: body}}

  # A probe that must not be reached: if a test that passes this fails,
  # it fails with the provider and model it was wrongly called for.
  defp forbidden_probe do
    fn provider, name ->
      raise "probe must not run for #{provider.name}/#{name}"
    end
  end

  describe "resolve/4 metadata gate" do
    test "keeps a definite metadata answer without probing" do
      opted_in_provider = %DotConfig.Provider{name: "p", probe_multimodal: true}
      opted_out_provider = %DotConfig.Provider{name: "p"}

      assert MultiModal.resolve(opted_in_provider, "m", @image, forbidden_probe()) == @image

      assert MultiModal.resolve(opted_in_provider, "m", @text_only, forbidden_probe()) ==
               @text_only

      assert MultiModal.resolve(opted_out_provider, "m", @image, forbidden_probe()) == @image

      assert MultiModal.resolve(opted_out_provider, "m", @text_only, forbidden_probe()) ==
               @text_only
    end

    test "leaves an unknown model unknown when the provider did not opt in" do
      assert MultiModal.resolve(%DotConfig.Provider{name: "p"}, "m", nil, forbidden_probe()) ==
               nil

      assert MultiModal.resolve(
               %DotConfig.Provider{name: "p", probe_multimodal: false},
               "m",
               nil,
               forbidden_probe()
             ) == nil
    end

    test "maps each probe answer onto the vocabulary when the provider opted in" do
      provider = %DotConfig.Provider{name: "p", probe_multimodal: true}

      assert MultiModal.resolve(provider, "m", nil, fn _p, _n -> :positive end) == @image
      assert MultiModal.resolve(provider, "m", nil, fn _p, _n -> :negative end) == @text_only
      assert MultiModal.resolve(provider, "m", nil, fn _p, _n -> :unknown end) == nil
    end

    test "hands the probe the provider and the model name" do
      provider = %DotConfig.Provider{name: "p", probe_multimodal: true}
      parent = self()

      probe = fn p, n ->
        send(parent, {:probed, p, n})
        :positive
      end

      assert MultiModal.resolve(provider, "some-model", nil, probe) == @image
      assert_received {:probed, ^provider, "some-model"}
    end
  end

  describe "resolve/3 (the seam onto the real probe)" do
    test "keeps a definite metadata answer, with no probe in reach" do
      Mimic.stub(Req, :post, fn _url, _opts ->
        flunk("a definite metadata answer must never be probed")
      end)

      assert MultiModal.resolve(%DotConfig.Provider{name: "p"}, "m", @text_only) == @text_only
      assert MultiModal.resolve(%DotConfig.Provider{name: "p"}, "m", @image) == @image

      # The same, for a provider that *did* opt in: a definite answer is kept
      # without the probe being consulted at all, because the probe gate is
      # `detected == nil` as well as `probe_multimodal: true`.
      assert MultiModal.resolve(opted_in(), "m", @text_only) == @text_only
      assert MultiModal.resolve(opted_in(), "m", @image) == @image
    end

    test "an unknown model on a provider that did not opt in is never probed" do
      Mimic.stub(Req, :post, fn _url, _opts ->
        flunk("the probe must not run for a provider that did not opt in")
      end)

      assert MultiModal.resolve(%DotConfig.Provider{name: "p"}, "m", nil) == nil

      assert MultiModal.resolve(%DotConfig.Provider{name: "p", probe_multimodal: false}, "m", nil) ==
               nil
    end

    test "an unknown model on an opted-in provider is resolved by the real probe" do
      # `resolve/3` calls `Nest.LLM.MultimodalProbe.probe/2` itself here, so
      # this is the only test that drives the two changes joined. The probe
      # sends image A first and image B second (its own tests pin that by
      # sha256), so each answer below is exactly right for the image it is
      # sent with -- and the two differ, which is what makes the verdict
      # perception rather than a guess.
      Mimic.expect(Req, :post, 1, fn _url, _opts -> openai_answer(@answer_a) end)
      Mimic.expect(Req, :post, 1, fn _url, _opts -> openai_answer(@answer_b) end)

      # The verdict the probe settles on is what the cache is handed, once.
      Mimic.expect(MultimodalCache, :put, 1, fn _provider, "unknown-model", :positive -> :ok end)

      assert MultiModal.resolve(opted_in(), "unknown-model", nil) == @image
    end

    test "an unknown model whose probe is rejected resolves to text-only" do
      # The measured rejection for a model whose endpoints take no images.
      # It settles the verdict, so the second image is never sent: the
      # expected count of 1 is itself the assertion that the probe halts.
      Mimic.expect(Req, :post, 1, fn _url, _opts -> rejected(404, @rejection) end)

      Mimic.expect(MultimodalCache, :put, 1, fn _provider, "text-only-model", :negative -> :ok end)

      assert MultiModal.resolve(opted_in(), "text-only-model", nil) == @text_only
    end

    test "a probe that settles nothing is not cached" do
      # A transport error is `:unknown`: not a finding, and storing it would
      # leave the model looking unprobed for a week. The rejected `put/3`
      # (verified on exit) is the assertion that the cache never sees it.
      Mimic.reject(MultimodalCache, :put, 3)
      Mimic.expect(Req, :post, 1, fn _url, _opts -> {:error, :timeout} end)

      assert MultiModal.resolve(opted_in(), "unreachable-model", nil) == nil
    end

    test "a cached verdict answers without any request at all" do
      # The whole point of the cache: a hit costs nothing. The rejected
      # `Req.post/2` (verified on exit) is the assertion of that.
      Mimic.reject(Req, :post, 2)

      Mimic.stub(MultimodalCache, :get, fn %DotConfig.Provider{name: "p"}, name ->
        if name == "cached-image", do: :positive, else: :negative
      end)

      assert MultiModal.resolve(opted_in(), "cached-image", nil) == @image
      assert MultiModal.resolve(opted_in(), "cached-text", nil) == @text_only
    end
  end

  describe "effective/2" do
    test "keeps a static multi-modal verbatim, whatever discovery found" do
      static = %{"input" => ["image", "file"]}
      model = %DotConfig.Model{name: "m", provider_name: "p", multi_modal: static}

      auto = %{"m" => %DotConfig.Model{name: "m", provider_name: "p", multi_modal: @text_only}}

      assert MultiModal.effective(model, auto) == static
    end

    test "fills in from the auto entry for the same provider, keeping negative apart from unknown" do
      model = %DotConfig.Model{name: "m", provider_name: "p"}

      for detected <- [@image, @text_only, nil] do
        auto = %{"m" => %DotConfig.Model{name: "m", provider_name: "p", multi_modal: detected}}
        assert MultiModal.effective(model, auto) == detected
      end
    end

    test "does not take a capability from a same-named model under another provider" do
      model = %DotConfig.Model{name: "m", provider_name: "p"}
      auto = %{"m" => %DotConfig.Model{name: "m", provider_name: "other", multi_modal: @image}}

      assert MultiModal.effective(model, auto) == nil
    end

    test "returns nil when discovery has no entry for the model" do
      model = %DotConfig.Model{name: "m", provider_name: "p"}

      assert MultiModal.effective(model, %{}) == nil
      assert MultiModal.effective(model, %{"other" => %DotConfig.Model{name: "other"}}) == nil
    end
  end
end
