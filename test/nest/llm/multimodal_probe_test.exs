defmodule Nest.LLM.MultimodalProbeTest do
  @moduledoc """
  Tests for `Nest.LLM.MultimodalProbe`.

  The probe is driven only through its public interface: `Req.post/2` is
  stubbed per test process, and the assertions look at the request the probe
  actually built -- URL, headers, JSON body, image bytes -- as well as at the
  verdict it returned. Nothing here reaches into a private function.

  The two image payloads are checked against the sha256 of the files they were
  generated from, so the ground truth recorded in the module's comment cannot
  drift away from the bytes on the wire. What the test cannot re-derive is the
  ground truth itself (4 shapes / largest green, 7 shapes / largest yellow):
  that was measured from the rendered pixels with ImageMagick's connected
  components, and is documented in the module.
  """
  use ExUnit.Case, async: true

  import Mimic

  alias Nest.DotConfig
  alias Nest.LLM.MultimodalProbe

  setup :verify_on_exit!

  # sha256 of the probe images, as recorded in the module.
  @sha_a "33fe06145c3fe220eaffa5ab526fbc7559dd9e1f4167388ac68206dac647f7f1"
  @sha_b "7ea8e4293860703618f5a6c1377b2fae385395a86ab53fdab131c57f7399a169"

  # Exactly right for each image, and different from each other.
  @answer_a "There are 4 shapes and the largest is the green circle."
  @answer_b "There are 7 shapes and the largest is a yellow triangle."

  # The measured real-world rejection: OpenRouter returns this when none of the
  # endpoints behind a model accept image input.
  @rejection_body %{
    "error" => %{"message" => "No endpoints found that support image input", "code" => 404}
  }

  @openai_url "http://openai.test/chat/completions"
  @anthropic_url "https://api.anthropic.com/v1/messages"

  defp provider(overrides \\ []) do
    struct!(
      %DotConfig.Provider{
        name: "mm-probe-test",
        base_url: "http://openai.test",
        api_key: "sk-test-key",
        protocol: "openai",
        timeout_seconds: 30
      },
      overrides
    )
  end

  defp ok(body), do: {:ok, %{status: 200, body: body}}
  defp failed(status, body), do: {:ok, %{status: status, body: body}}

  # Answers each image by what the request actually carried, so a stub cannot
  # hand image A's answer to image B by accident. One answer per image is also
  # the expected request count.
  defp stub_answers(answers) do
    Mimic.expect(Req, :post, map_size(answers), fn _url, opts ->
      Map.fetch!(answers, sent_image(opts[:json]))
    end)
  end

  # Which image a request carries, identified by the sha256 of the bytes in it:
  # that check is itself the payload assertion.
  defp sent_image(json) do
    sha =
      json
      |> sent_base64()
      |> Base.decode64!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    case sha do
      @sha_a -> :a
      @sha_b -> :b
      other -> flunk("probe sent unrecognised image bytes (sha256 #{other})")
    end
  end

  # The image bytes out of either wire format.
  defp sent_base64(%{"messages" => [%{"content" => parts}]}) do
    Enum.find_value(parts, fn
      %{"image_url" => %{"url" => "data:" <> rest}} ->
        [_media_type, data] = String.split(rest, ";base64,", parts: 2)
        data

      %{"source" => %{"data" => data}} ->
        data

      _other_part ->
        nil
    end)
  end

  defp answer_for(:a), do: @answer_a
  defp answer_for(:b), do: @answer_b

  defp openai_answer(text) do
    %{"choices" => [%{"message" => %{"role" => "assistant", "content" => text}}]}
  end

  defp openai_parts_answer(text) do
    parts = [%{"type" => "refusal"}, %{"type" => "text", "text" => text}]
    %{"choices" => [%{"message" => %{"role" => "assistant", "content" => parts}}]}
  end

  defp openai_body(content, finish_reason) do
    %{
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => content},
          "finish_reason" => finish_reason
        }
      ]
    }
  end

  # Leads with a `thinking` block, as a real reasoning reply can.
  defp anthropic_answer(text) do
    %{
      "content" => [
        %{"type" => "thinking", "thinking" => "counting the shapes one by one"},
        %{"type" => "text", "text" => text}
      ]
    }
  end

  describe "an openai-protocol provider" do
    test "answers both images correctly and differently -> :positive" do
      Mimic.expect(Req, :post, 2, fn url, opts ->
        assert url == @openai_url
        assert opts[:headers] == [{"authorization", "Bearer sk-test-key"}]
        # The key is an auth header and nothing else: the body is the only
        # thing a log line or an error report could echo.
        refute inspect(opts[:json]) =~ "sk-test-key"

        assert %{
                 "model" => "gpt-vision",
                 "max_tokens" => 4_000,
                 "temperature" => 0,
                 "messages" => [%{"role" => "user", "content" => [text_part, image_part]}]
               } = opts[:json]

        assert text_part["type"] == "text"
        assert text_part["text"] =~ "How many shapes"
        assert text_part["text"] =~ "colour is the largest shape"
        assert image_part["type"] == "image_url"
        assert image_part["image_url"]["url"] =~ ~r/\Adata:image\/png;base64,[A-Za-z0-9+\/=]+\z/

        # A scan must not be able to hang the boot path, and must not multiply
        # its own cost with retries.
        assert opts[:receive_timeout] == 20_000
        assert opts[:connect_options] == [timeout: 20_000]
        assert opts[:retry] == false

        ok(openai_answer(answer_for(sent_image(opts[:json]))))
      end)

      assert MultimodalProbe.probe(provider(), "gpt-vision") == :positive
    end

    test "reads a content list of parts" do
      stub_answers(%{
        a: ok(openai_parts_answer(@answer_a)),
        b: ok(openai_parts_answer(@answer_b))
      })

      assert MultimodalProbe.probe(provider(), "gpt-vision") == :positive
    end
  end

  describe "an anthropic-protocol provider" do
    test "answers both images correctly and differently -> :positive" do
      Mimic.expect(Req, :post, 2, fn url, opts ->
        # A base that already ends in /v1 must not get a second one.
        assert url == @anthropic_url

        assert opts[:headers] == [
                 {"x-api-key", "sk-ant-key"},
                 {"anthropic-version", "2023-06-01"}
               ]

        assert %{"messages" => [%{"content" => [image_part, text_part]}]} = opts[:json]
        assert image_part["type"] == "image"
        assert image_part["source"]["type"] == "base64"
        assert image_part["source"]["media_type"] == "image/png"
        assert text_part["type"] == "text"
        assert text_part["text"] =~ "colour is the largest shape"

        # The provider's own timeout wins when it is the shorter one.
        assert opts[:receive_timeout] == 5_000
        assert opts[:connect_options] == [timeout: 5_000]

        ok(anthropic_answer(answer_for(sent_image(opts[:json]))))
      end)

      p =
        provider(
          protocol: "anthropic",
          base_url: "https://api.anthropic.com/v1",
          api_key: "sk-ant-key",
          timeout_seconds: 5
        )

      assert MultimodalProbe.probe(p, "claude-vision") == :positive
    end
  end

  describe "an explicit unsupported-image rejection" do
    test "the measured 'no endpoints support image input' 404 -> :negative in one request" do
      # The rejection settles the pair, so the second image is never sent.
      Mimic.expect(Req, :post, 1, fn url, opts ->
        assert url == @openai_url
        assert [_, _] = opts[:json]["messages"] |> hd() |> Map.fetch!("content")
        failed(404, @rejection_body)
      end)

      assert MultimodalProbe.probe(provider(), "text-only-model") == :negative
    end

    test "the same rejection for the second image -> :negative" do
      # Returned as text/plain here, so Req hands the body over as a raw string
      # rather than a decoded map: the same rejection, read from either shape.
      stub_answers(%{
        a: ok(openai_answer(@answer_a)),
        b: failed(404, Jason.encode!(@rejection_body))
      })

      assert MultimodalProbe.probe(provider(), "half-blind-model") == :negative
    end

    test "the measured content-type wordings -> :negative" do
      # OpenAI's measured wording is "Invalid content type. image_url is only
      # supported by certain models." -- which also names `image_url`, and so
      # was already caught by the older pattern. The phrase alone is the signal
      # the new pattern adds, so it is what is tested here. Anthropic's measured
      # wording names the block path and no "image_url" at all.
      cases = [
        {"openai invalid content type", 400,
         %{"error" => %{"message" => "Invalid content type"}}},
        {"anthropic unexpected media type", 400,
         %{
           "error" => %{
             "message" => "messages.0.content.0.image.source.base64: unexpected media type"
           }
         }}
      ]

      for {label, status, body} <- cases do
        Mimic.expect(Req, :post, 1, fn _url, _opts -> failed(status, body) end)

        assert MultimodalProbe.probe(provider(), "m") == :negative,
               "expected :negative for #{label}"
      end
    end
  end

  describe "a 2xx that does not show perception" do
    test "both answers wrong for the image sent -> :negative" do
      stub_answers(%{
        a: ok(openai_answer("There are 6 shapes and the largest is blue.")),
        b: ok(openai_answer("There are 2 shapes and the largest is red."))
      })

      assert MultimodalProbe.probe(provider(), "guessing-model") == :negative
    end

    test "unusable text for the first image -> :unknown in one request" do
      cases = [
        {"openai null content with finish_reason length", [], openai_body(nil, "length")},
        # Whitespace is the case that needs the trim: `""` is unknown whether
        # or not the text is trimmed.
        {"openai whitespace content", [], openai_body("  \n ", "stop")},
        {"openai no choices", [], %{"id" => "gen-1"}},
        {"openai JSON string body", [], Jason.encode!(openai_body(nil, "length"))},
        {"openai non-JSON body", [], "<html><body>Bad gateway</body></html>"},
        {"openai nil body", [], nil},
        {"anthropic no content list", [protocol: "anthropic"], %{"type" => "message"}},
        {"anthropic thinking block only", [protocol: "anthropic"],
         %{"content" => [%{"type" => "thinking"}]}},
        {"anthropic non-map block", [protocol: "anthropic"], %{"content" => ["raw text"]}}
      ]

      for {label, overrides, body} <- cases do
        Mimic.expect(Req, :post, 1, fn _url, _opts -> ok(body) end)

        assert MultimodalProbe.probe(provider(overrides), "m") == :unknown,
               "expected :unknown for #{label}"
      end
    end

    test "an answer for the first image and unusable text for the second -> :unknown" do
      stub_answers(%{a: ok(openai_answer(@answer_a)), b: ok(openai_body(nil, "length"))})

      assert MultimodalProbe.probe(provider(), "reasoning-model") == :unknown
    end
  end

  describe "a request that never lands" do
    test "a timeout -> :unknown, in one request" do
      # Every transport failure -- a refused connection, a DNS failure, a
      # timeout -- reaches the same `{:error, _reason}` clause, so one
      # representative pins the whole path. Req's own error shape (a
      # `Mint.TransportError`) is the one used.
      Mimic.expect(Req, :post, 1, fn _url, _opts ->
        {:error, %Mint.TransportError{reason: :timeout}}
      end)

      assert MultimodalProbe.probe(provider(), "hanging") == :unknown
    end
  end

  describe "a non-2xx that is not a modality rejection" do
    test "-> :unknown, never :negative" do
      cases = [
        {"401 invalid key", 401, %{"error" => %{"message" => "Invalid API key provided"}}},
        # The measured modality rejection is a 404 too, so the status alone
        # must not be the signal.
        {"404 unknown model", 404, %{"error" => %{"message" => "The model `x` does not exist"}}},
        # Not a 4xx at all: the other clause of `modality_rejection?/2`.
        {"500 html", 500, "<html><body>Bad gateway</body></html>"},
        # Near misses: these mention images without rejecting image input, and
        # `provisioned` must not read as `vision`.
        {"400 image too large", 400, %{"error" => %{"message" => "image dimensions too large"}}},
        {"400 provisioned quota", 400, %{"error" => %{"message" => "provisioned quota exceeded"}}}
      ]

      for {label, status, body} <- cases do
        Mimic.expect(Req, :post, 1, fn _url, _opts -> failed(status, body) end)

        assert MultimodalProbe.probe(provider(), "m") == :unknown,
               "expected :unknown for #{label}"
      end
    end
  end

  describe "the answer checker" do
    test "rejects an answer that is right in only one of the two facts" do
      # Image A with the right colour but the wrong count: if the count were
      # not checked, this pair (B is answered correctly) would be a :positive.
      stub_answers(%{
        a: ok(openai_answer("There are 5 shapes and the largest is green.")),
        b: ok(openai_answer(@answer_b))
      })

      assert MultimodalProbe.probe(provider(), "m") == :unknown

      # ... and the mirror image: right count, wrong colour.
      stub_answers(%{
        a: ok(openai_answer("There are 4 shapes and the largest is blue.")),
        b: ok(openai_answer(@answer_b))
      })

      assert MultimodalProbe.probe(provider(), "m") == :unknown
    end

    test "accepts a count written as a word" do
      stub_answers(%{
        a: ok(openai_answer("There are four shapes; the largest one is green.")),
        b: ok(openai_answer("There are seven shapes and the largest is yellow."))
      })

      assert MultimodalProbe.probe(provider(), "m") == :positive
    end

    test "an identical answer to both images is not perception" do
      # Names both counts and both colours, so it passes the checker for either
      # image -- but it cannot be an answer to two different pictures.
      hedge = "I count 4 or 7 shapes; the largest might be green or yellow."

      stub_answers(%{a: ok(openai_answer(hedge)), b: ok(openai_answer(hedge))})

      assert MultimodalProbe.probe(provider(), "m") == :unknown
    end

    test "a stated inability to see the image is never a right answer" do
      # A realistic blind-model hedge: it recites image A's exact facts (4
      # shapes, green largest) while saying it cannot see the image. Graded as
      # an answer it would pair with B's correct one for a `:positive`; the
      # blindness check makes it `:wrong`, so the pair is `:unknown`.
      hedge =
        "I cannot see the image, but such pictures usually have 4 shapes " <>
          "and a green largest one."

      stub_answers(%{a: ok(openai_answer(hedge)), b: ok(openai_answer(@answer_b))})

      assert MultimodalProbe.probe(provider(), "blind-hedger") == :unknown

      # The same blindness on both images is two wrong answers, which the
      # vocabulary calls `:negative`: the model answered without seeing.
      other =
        "I can't view the picture, but it is probably 7 shapes with a yellow largest one."

      stub_answers(%{a: ok(openai_answer(hedge)), b: ok(openai_answer(other))})

      assert MultimodalProbe.probe(provider(), "blind-both") == :negative
    end
  end

  describe "a request that cannot be built" do
    test "a protocol we cannot speak, or no base URL -> :unknown with no request" do
      Mimic.stub(Req, :post, fn _url, _opts ->
        flunk("the probe must not send a request it cannot build")
      end)

      assert MultimodalProbe.probe(provider(protocol: "gemini"), "m") == :unknown
      assert MultimodalProbe.probe(provider(base_url: nil), "m") == :unknown
      assert MultimodalProbe.probe(provider(base_url: ""), "m") == :unknown
    end

    test "a provider with no API key or timeout -> no auth header, and the probe's own timeout" do
      Mimic.expect(Req, :post, 1, fn _url, opts ->
        assert opts[:headers] == []

        # `timeout_seconds` can be absent on a provider built from a map (the
        # lobby channel builds one that way), so the probe's own ceiling stands
        # in rather than crashing on `nil`.
        assert opts[:receive_timeout] == 20_000
        assert opts[:connect_options] == [timeout: 20_000]

        failed(404, @rejection_body)
      end)

      Mimic.expect(Req, :post, 1, fn _url, opts ->
        assert opts[:headers] == [{"anthropic-version", "2023-06-01"}]
        failed(404, @rejection_body)
      end)

      unconfigured = provider(api_key: nil, timeout_seconds: nil)

      assert MultimodalProbe.probe(unconfigured, "m") == :negative

      anthropic =
        provider(api_key: nil, protocol: "anthropic", base_url: "https://api.anthropic.com")

      assert MultimodalProbe.probe(anthropic, "m") == :negative
    end

    test "an API key that cannot be resolved -> no auth header, and its 401 stays :unknown" do
      # `DotConfig.resolve_api_key/1` raises on an unset `${ENV_VAR}` and on an
      # unreadable `file:` reference; both raise shapes are pinned in
      # `test/nest_web/channels/lobby_channel/providers_test.exs`, and both land
      # in the same `rescue` here, so one representative pins the probe's own
      # rescue. `probe/2` documents that it never raises, and the scan that
      # calls it rescues per provider -- so a raise escaping here would drop
      # that provider's entire model list over one bad key. An unresolvable key
      # is "no key": the request goes out unauthenticated and its 401 is
      # `:unknown`, which claims nothing.
      Mimic.expect(Req, :post, 1, fn _url, opts ->
        assert opts[:headers] == []
        failed(401, %{"error" => %{"message" => "Invalid API key provided"}})
      end)

      assert MultimodalProbe.probe(provider(api_key: "${MM_PROBE_UNSET_KEY_9f3a}"), "m") ==
               :unknown
    end
  end
end
