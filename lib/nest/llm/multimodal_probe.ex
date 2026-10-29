defmodule Nest.LLM.MultimodalProbe do
  @moduledoc """
  Decides whether a model genuinely accepts *and perceives* image input.

  Provider metadata is not evidence: an endpoint may publish no modality
  information at all, and a text-only model will happily answer a question
  about an image it never saw. So the probe sends a real image and asks a
  question whose answer cannot be guessed from the prompt alone -- how many
  shapes the image contains, and the colour of the largest shape -- and only
  reports `:positive` when the answer is exactly right.

  ## Verdicts

    * `:positive` -- both images got a 2xx and both answers were exactly
      right (count *and* colour), and the two answers differ. A model that
      cannot see the image cannot satisfy all three of those. An answer that
      *says* it cannot see the image is never exactly right, however exactly
      it names the facts -- see `@blindness_patterns`.
    * `:negative` -- the provider rejected the image with an explicit
      unsupported-input error (the measured one is
      `{"error":{"message":"No endpoints found that support image input","code":404}}`),
      or it accepted the request and got both answers demonstrably wrong
      (which includes two answers that both state an inability to see).
    * `:unknown` -- everything else: a transport error, a timeout, a non-2xx
      that is not an explicit modality rejection, a 2xx with no usable text
      (a reasoning model that spends its whole budget returns
      `content: null` with `finish_reason: "length"`), one answer right and
      one wrong -- including one blind hedge against one right answer -- or an
      answer that does not discriminate. `:unknown` is never softened into a
      verdict.

  ## Why two images

  One image plus one answer can be passed by a model that guesses the common
  case, and an identical answer to two different images is itself evidence of
  no perception. The differential costs one extra request per model, and only
  for models on providers that opted into probing: the second image is not
  sent when the first response has already settled the verdict (a rejection,
  or anything that is not a usable 2xx answer).

  ## Request shape

  The wire format follows `provider.protocol`: `"openai"` posts an
  `image_url` data-URL part to `<base_url>/chat/completions` with
  `Authorization: Bearer`; `"anthropic"` posts a base64 `image` source block
  to `<base_url>/v1/messages` with `x-api-key` and `anthropic-version`.
  Endpoint URLs are built with the same `normalize_endpoint/2` the chat
  clients use, so the probe hits exactly the endpoint a chat call would.

  The API key is resolved with `Nest.DotConfig.resolve_api_key/1`, sent only
  as an auth header, and never logged or returned. `provider.probe_base_url`
  is deliberately unused: that is the *discovery* base (`GET <base>/models`),
  not a chat base.

  ## Cost and latency

  Every request carries a short receive/connect timeout (20 s, or the
  provider's own `first_byte_timeout_seconds` when smaller) and Req's retries
  are disabled, because a scan runs this and must never hang startup. A
  timeout is `:unknown`, never `:negative`.

  A scan does not, however, wait for a probe. `Nest.Models` runs each
  provider's query under its own Task and caps the *first* broadcast at its
  5 s deadline, so two 20 s requests per unknown model can easily outlive it:
  a probed model stays `multi_modal: nil` in the payload until the provider's
  query finishes and its late `models_updated` lands, and
  `{:models_scan_complete, _}` -- which re-enables the GUI's rescan button --
  fires before the probes have answered. That is a known defect, not a design
  choice: the deadline bounds the whole scan and there is no per-scan probe
  budget to keep probing inside it. See the note at
  `Nest.Models.query_provider/1`.
  """

  alias Nest.DotConfig
  alias Nest.LLM.AnthropicClient
  alias Nest.LLM.OpenAIClient

  # Wording calibrated against the reference probe (scripts/multimodal-probe.exs):
  # it asks for both facts in one sentence so the answer stays cheap to check.
  @question """
  Look at the attached image. How many shapes does it contain, and what \
  colour is the largest shape? Answer in one short sentence.\
  """

  # The reference probe measured that a small budget is eaten by a reasoning
  # model's thinking, leaving `content: null` and `finish_reason: "length"` --
  # which is `:unknown`, never `:negative`.
  @max_tokens 4_000

  @probe_timeout_ms 20_000
  @media_type "image/png"
  @anthropic_version "2023-06-01"

  # Number words accepted alongside digits. Only the counts we actually use.
  @number_words %{4 => ["four"], 7 => ["seven"]}

  # A 4xx is only a modality rejection if it says so. These are matched
  # against the raw error body of a failed request, and an arbitrary 4xx
  # (auth, quota, bad model name) must stay `:unknown`. They are deliberately
  # narrow: a false `:negative` loses a capable model, while anything these
  # miss stays `:unknown`, which claims nothing.
  #
  # The last two are the measured OpenAI-shaped ("Invalid content type.
  # image_url is only supported by certain models.") and Anthropic-shaped
  # ("...image.source.base64: unexpected media type") wordings for the same
  # rejection; the earlier `unsupported`/`type` patterns do not cover either.
  @rejection_patterns [
    ~r/image[-_ ]?input/i,
    ~r/image[-_ ]?url/i,
    ~r/\bvision\b/i,
    ~r/multimodal/i,
    ~r/supports? image/i,
    ~r/unsupported.{0,24}(?:image|media|content[-_ ]?type|modality)/i,
    ~r/(?:image|media|content)[-_ ]?type.{0,40}(?:unsupported|not supported)/i,
    ~r/invalid content[-_ ]?type/i,
    ~r/unexpected (?:media|content)[-_ ]?type/i
  ]

  # `~r/\bvision\b/i` is the loosest of those and would also match a *model
  # name* quoted back in an error body (`The model "vision-xl" does not
  # exist`), which would read as a false `:negative`. That is unreachable in
  # production: `Nest.Models.MultiModal.resolve/3` probes only a model the
  # provider's own `/models` listing just returned, so the probe never asks
  # for a name the provider did not offer. It stays because a provider that
  # rejects image input often says nothing but `vision`.

  # ---------------------------------------------------------------------------
  # Probe images
  #
  # Both are 128x128 PNG8 images on white, rendered with ImageMagick 6 with
  # antialiasing disabled, so every shape is a solid connected component with
  # no stray edge pixels:
  #
  #   convert -size 128x128 xc:white +antialias -fill red -stroke none \
  #     -draw "rectangle 6,6 29,29" -draw "rectangle 6,40 29,63" \
  #     -draw "rectangle 6,74 29,97" -fill lime -draw "circle 88,64 88,32" \
  #     -strip PNG8:image-a.png
  #
  #   convert -size 128x128 xc:white +antialias -fill yellow -stroke none \
  #     -draw "polygon 24,4 6,40 42,40" -draw "polygon 72,4 54,40 90,40" \
  #     -draw "polygon 24,42 6,78 42,78" -draw "polygon 72,42 54,78 90,78" \
  #     -draw "polygon 24,80 6,116 42,116" -fill blue \
  #     -draw "circle 110,20 110,12" -draw "circle 110,102 110,110" \
  #     -strip PNG8:image-b.png
  #
  # The ground truth below is MEASURED from the rendered pixels rather than
  # assumed from the draw commands, with:
  #
  #   convert image-a.png -define connected-components:verbose=true \
  #     -connected-components 8 null:
  #
  # Image A -- 4 objects (white background excluded):
  #   24x24+6+6    area 576   srgb(255,0,0)   red square
  #   24x24+6+40   area 576   srgb(255,0,0)   red square
  #   24x24+6+74   area 576   srgb(255,0,0)   red square
  #   65x65+56+32  area 3305  srgb(0,255,0)   green circle  <- largest
  # Image B -- 7 objects:
  #   five 37x37 yellow triangles, area 685 each       <- largest
  #   two  17x17 blue circles,     area 221 each
  #
  # sha256 of the PNG bytes, so the embedded base64 can be re-derived:
  #   A 33fe06145c3fe220eaffa5ab526fbc7559dd9e1f4167388ac68206dac647f7f1
  #   B 7ea8e4293860703618f5a6c1377b2fae385395a86ab53fdab131c57f7399a169
  #
  # The bytes are embedded rather than rendered at runtime: the app has no
  # ImageMagick dependency and a scan must not shell out.
  # ---------------------------------------------------------------------------

  @image_a_base64 """
                  iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAMAAAD04JH5AAAACVBMVEX/////AAAA/wAJsf/jAAAA90lE
                  QVR42u3ZQY7CMBBEUeP7HxqJDVLiDnZXJyWL//ejeqsB3K0R0adXEAAAAAAAAAAAAAAAAP4HQKX1b9Zx
                  A6JHmeefIfRfuffvFUzM30qY3L8SSP+Kp/cvBApgYT8WCICl/VCQByzuR4I0YHk/EGQBif2xYFdAan8o
                  yAGS+yPBnoD0/kCwJUDYPwsAJADS/kkAYEOAuH8UAACwHgAAAIo/CwDYATt+JwTg/2XkB9h/HfsB9hcS
                  /xuRH2B/J/S/lPrfiv2v5f57gf9iUnEzEgH61UwGqHdDHSBeTisA0u24BtDy1/MywAEx/TelACIiIiIi
                  IiJa6g3x8yCT2Pjn2gAAAABJRU5ErkJggg==
                  """
                  |> String.replace(~r/\s+/, "")

  @image_b_base64 """
                  iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAMAAAD04JH5AAAACVBMVEX//////wAAAP998yqQAAABrklE
                  QVR42u3aS27DMBAE0RTvf+ggiywcwOGUTKrHBmfdaD8k4geCvr7OnHkybM63B4BrtPn2AHCNNt8eAK7R
                  5tsDwDVW8+NncoDxO/W+oqCWH6Ms2AIYoywAJyjlx6gL0gBwglJ+jLogDQAnqOXfCABOUMzHAeVVAE5Q
                  zscBxZ0QnMDkry2BhYDKaQhOYPN2F14OmA24RptvDwDXaPPtAeAabb49gNm8mG8PmPb9abT59oBC30Oj
                  zb/jpF9SxQEXHqLPAtinePlTnwbYhbx84acBdi9bvvelAXY7X779pwH2RFt+AqYB9lBffglIA+y9Zvk9
                  KA0A12jz7QHgGm2+PQBco823B4BrtPn2AHCNNt8eAK7R5tsDwDXafHsAs3kx3x4w7TtvyR4bbf4dJ+5P
                  A+L/wjQg/hSnAfGFnAbE97I0IL6dpwHxEy0N2Hio688Z1wKufE24UnDpa8KFgIsf8y0TXP+Y7mbArttt
                  +Wu6NGDbBf9dALBLEAfUVgHc9ie4H1DZCeEuwZPEZsD0NITdgsl94AbAv8NsPh0w/f3dgjSg8PvpVyZn
                  zpw5c2bXfANSUhDWQn2SGQAAAABJRU5ErkJggg==
                  """
                  |> String.replace(~r/\s+/, "")

  @image_a %{
    name: "A",
    count: 4,
    colour: "green",
    summary: "3 red squares + 1 larger green circle",
    base64: @image_a_base64
  }

  @image_b %{
    name: "B",
    count: 7,
    colour: "yellow",
    summary: "5 yellow triangles + 2 smaller blue circles",
    base64: @image_b_base64
  }

  # Differing count *and* colour, so no single answer can be right for both.
  @images [@image_a, @image_b]

  @typedoc "What the probe learned about one model's image handling."
  @type verdict :: :positive | :negative | :unknown

  @doc """
  Probes one `model` on `provider` with a real image.

  Returns `:positive`, `:negative`, or `:unknown` as described in the module
  doc. Never raises on a bad provider, a bad model name, or a broken network:
  anything that is not an unambiguous verdict is `:unknown`.
  """
  @spec probe(DotConfig.Provider.t(), String.t()) :: verdict()
  def probe(%DotConfig.Provider{} = provider, model) when is_binary(model) do
    with {:ok, wire} <- wire_format(provider.protocol),
         {:ok, url} <- probe_url(provider, wire) do
      provider
      |> request_images(wire, url, model)
      |> verdict()
    else
      :error -> :unknown
    end
  end

  defp wire_format("anthropic"), do: {:ok, :anthropic}
  defp wire_format("openai"), do: {:ok, :openai}
  defp wire_format(_protocol), do: :error

  defp probe_url(provider, wire) do
    case provider.base_url do
      base_url when is_binary(base_url) and base_url != "" ->
        {:ok, endpoint_url(base_url, wire)}

      _missing ->
        :error
    end
  end

  # Reuses the chat clients' own URL builder so the probe hits exactly the
  # endpoint a chat call would: `/chat/completions` for OpenAI-shaped bases,
  # `/v1/messages` for Anthropic-shaped ones, with a `/v1` already present in
  # the base collapsed rather than doubled.
  defp endpoint_url(base_url, :openai) do
    OpenAIClient.normalize_endpoint(base_url, "/chat/completions")
  end

  defp endpoint_url(base_url, :anthropic) do
    AnthropicClient.normalize_endpoint(base_url, "/v1/messages")
  end

  # Each image gets its own request: one body cannot carry a differential.
  # Image A goes first and the scan stops as soon as a response has already
  # settled the verdict, so a rejecting or unreachable provider costs one
  # request, not two.
  defp request_images(provider, wire, url, model) do
    headers = headers(provider, wire)
    timeout = probe_timeout_ms(provider)

    @images
    |> Enum.reduce_while([], fn image, acc ->
      response =
        url
        |> send_request(wire, request_body(wire, model, image), headers, timeout)
        |> Map.put(:image, image)

      if response.outcome == :ok do
        {:cont, [response | acc]}
      else
        {:halt, [response | acc]}
      end
    end)
    |> Enum.reverse()
  end

  defp send_request(url, wire, body, headers, timeout) do
    opts = [
      headers: headers,
      json: body,
      receive_timeout: timeout,
      connect_options: [timeout: timeout],
      # A scan must not multiply its cost or its worst-case latency by Req's
      # default retry of transient failures.
      retry: false
    ]

    case Req.post(url, opts) do
      {:ok, %{status: status, body: body}} -> classify(status, body, wire)
      {:error, _reason} -> %{outcome: :unknown, text: nil}
    end
  end

  defp classify(status, body, wire)
       when is_integer(status) and status >= 200 and status < 300 do
    case extract_text(body, wire) do
      text when is_binary(text) and text != "" -> %{outcome: :ok, text: text}
      _empty -> %{outcome: :unknown, text: nil}
    end
  end

  defp classify(status, body, _wire) do
    if modality_rejection?(status, body) do
      %{outcome: :rejected, text: nil}
    else
      %{outcome: :unknown, text: nil}
    end
  end

  # ---------------------------------------------------------------------------
  # Wire formats
  # ---------------------------------------------------------------------------

  defp request_body(wire, model, image) do
    %{
      "model" => model,
      "max_tokens" => @max_tokens,
      "temperature" => 0,
      "messages" => [%{"role" => "user", "content" => content(wire, image)}]
    }
  end

  defp content(:openai, image) do
    [
      %{"type" => "text", "text" => @question},
      %{
        "type" => "image_url",
        "image_url" => %{"url" => "data:#{@media_type};base64,#{image.base64}"}
      }
    ]
  end

  defp content(:anthropic, image) do
    [
      %{
        "type" => "image",
        "source" => %{
          "type" => "base64",
          "media_type" => @media_type,
          "data" => image.base64
        }
      },
      %{"type" => "text", "text" => @question}
    ]
  end

  defp headers(provider, :openai) do
    case api_key(provider) do
      key when is_binary(key) and key != "" -> [{"authorization", "Bearer #{key}"}]
      _none -> []
    end
  end

  defp headers(provider, :anthropic) do
    version = {"anthropic-version", @anthropic_version}

    case api_key(provider) do
      key when is_binary(key) and key != "" -> [{"x-api-key", key}, version]
      _none -> [version]
    end
  end

  # `resolve_api_key/1` is how every other call site turns a config value
  # (`${ENV_VAR}`, a file reference, or a literal) into a header value. The
  # result is used here and nowhere else: never logged, inspected, or returned.
  #
  # It *raises* on a value it cannot resolve -- an unset `${ENV_VAR}`, an
  # unreadable `file:` reference -- and `probe/2` must never raise: the scan
  # that calls it rescues per provider, so a raise escaping here would drop
  # that provider's entire model list over one unresolvable key. `nil` means
  # "no key", which every `headers/2` clause already handles: the request goes
  # out unauthenticated, a 401 comes back, and that is `:unknown`.
  defp api_key(provider) do
    DotConfig.resolve_api_key(provider.api_key)
  rescue
    _ -> nil
  end

  defp probe_timeout_ms(provider) do
    case provider.first_byte_timeout_seconds do
      seconds when is_integer(seconds) and seconds > 0 ->
        min(seconds * 1_000, @probe_timeout_ms)

      _unset ->
        @probe_timeout_ms
    end
  end

  # ---------------------------------------------------------------------------
  # Reading the answer
  # ---------------------------------------------------------------------------

  defp extract_text(body, wire) do
    body |> decode_body() |> text_from(wire) |> trim_text()
  end

  defp decode_body(body) when is_map(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _unusable -> %{}
    end
  end

  defp decode_body(_body), do: %{}

  defp text_from(json, :openai) do
    case get_in(json, ["choices", Access.at(0), "message", "content"]) do
      text when is_binary(text) -> text
      parts when is_list(parts) -> Enum.map_join(parts, "", &openai_part_text/1)
      _missing -> nil
    end
  end

  # A 2xx Anthropic body may lead with a `thinking` block; only `text` blocks
  # are the model's answer.
  defp text_from(json, :anthropic) do
    case json["content"] do
      blocks when is_list(blocks) ->
        blocks
        |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
        |> Enum.map_join("", &(&1["text"] || ""))

      _missing ->
        nil
    end
  end

  defp openai_part_text(%{"text" => text}) when is_binary(text), do: text
  defp openai_part_text(_part), do: ""

  defp trim_text(text) when is_binary(text), do: String.trim(text)
  defp trim_text(_text), do: nil

  defp modality_rejection?(status, body)
       when is_integer(status) and status >= 400 and status < 500 do
    text = body_text(body)
    Enum.any?(@rejection_patterns, &Regex.match?(&1, text))
  end

  defp modality_rejection?(_status, _body), do: false

  defp body_text(body) when is_binary(body), do: body
  defp body_text(body), do: inspect(body)

  # ---------------------------------------------------------------------------
  # Verdict
  # ---------------------------------------------------------------------------

  # `request_images/4` sends image A first and stops at the first response
  # that is not a usable answer, so exactly these shapes reach us.
  defp verdict([%{outcome: :rejected} | _rest]), do: :negative
  defp verdict([%{outcome: :unknown} | _rest]), do: :unknown
  defp verdict([first, second]), do: pair_verdict(first, second)

  # The pair is the unit of evidence, so grade both answers and read the
  # verdict off the two grades: two exactly-right answers that told the images
  # apart are perception, two wrong answers are a model that answered without
  # seeing anything, and one of each is not a verdict either way.
  defp pair_verdict(first, second) do
    case {grade(first), grade(second)} do
      {_, :rejected} ->
        :negative

      {_, :unusable} ->
        :unknown

      {:correct, :correct} ->
        if differ?(first, second) do
          :positive
        else
          # Both answers right but word-for-word identical for two different
          # images: a canned answer, not perception.
          :unknown
        end

      {:wrong, :wrong} ->
        :negative

      _one_correct_one_wrong ->
        :unknown
    end
  end

  # An answer is only `:correct` when it is exactly right about the image it
  # was sent, so anything that is not a usable answer grades as `:unusable`
  # rather than reaching the checker.
  defp grade(%{outcome: :rejected}), do: :rejected

  defp grade(%{image: image, text: text}) when is_binary(text) and text != "" do
    if correct?(image, text), do: :correct, else: :wrong
  end

  defp grade(_response), do: :unusable

  # Called only with a usable answer (see `grade/1`), so the count and the
  # colour can be read straight off the image the answer was sent with. An
  # answer that *states* an inability to see is never exactly right, however
  # well it recites the image's facts: a blind model can still be right about
  # the count and the colour (it can hedge, or guess, or read them off the
  # prompt), and grading that as `:wrong` is what keeps a pair of hedges from
  # reading as perception.
  defp correct?(image, text) do
    not blind?(text) and count_stated?(text, image.count) and colour_stated?(text, image.colour)
  end

  # The negation has to name the *medium* as well as the inability, so an
  # ordinary "I cannot be certain, but there are 4 shapes" stays an answer
  # and only a statement about the image itself ("I cannot see the image",
  # "the attached picture is not visible to me") is caught. Narrow on
  # purpose: a false `:wrong` can turn a capable model's pair into
  # `:negative`, so the phrasing has to be unambiguous.
  @blindness_patterns [
    ~r/\b(?:can'?t|cannot|could ?n'?t|could not|unable|not able)\b[^.!?]{0,40}\b(?:see|view|look at|access|read|perceive|process|analy[sz]e|interpret)\b[^.!?]{0,40}\b(?:image|picture|photo|attachment|visual)/i,
    ~r/\b(?:image|picture|photo|attachment|visual)\b[^.!?]{0,40}\b(?:not (?:visible|shown|provided|attached|available)|missing|unavailable)/i
  ]

  defp blind?(text), do: Enum.any?(@blindness_patterns, &Regex.match?(&1, text))

  defp differ?(first, second), do: normalize(first.text) != normalize(second.text)

  defp normalize(text) do
    text |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp count_stated?(text, count) do
    Regex.match?(~r/(?<!\d)#{count}(?!\d)/, text) or
      Enum.any?(number_words(count), &Regex.match?(~r/\b#{&1}\b/i, text))
  end

  defp number_words(count), do: Map.get(@number_words, count, [])

  defp colour_stated?(text, colour), do: Regex.match?(~r/\b#{colour}\b/i, text)
end
