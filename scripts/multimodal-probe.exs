#!/usr/bin/env elixir
# One-off diagnostic probe (NOT part of the test suite, NOT committed):
# does each target model actually ACCEPT and PERCEIVE image input?
#
# Run with:
#
#     cd /home/nat/Code/nest && elixir scripts/multimodal-probe.exs
#
# Why this exists: the provider metadata the app relies on carries no modality
# information for some of these endpoints (raven.ferrus.net/v1/models returns
# one model whose keys are id/created/context_length/max_input_tokens/pricing/
# owned_by only), so `file-read` fails closed and refuses to attach an image.
# Metadata is not evidence. This script sends real images and reads what comes
# back.
#
# Design (see the report it prints):
#   * two 128x128 PNGs whose contents are verified from the rendered pixels via
#     ImageMagick connected-component analysis (so the ground truth is measured,
#     not asserted);
#   * a question with a verifiable two-part answer (shape count + largest colour);
#   * a mandatory differential: the same question about two DIFFERENT images.
#     Identical answers for different images means the model is guessing;
#   * a text-only control per target, so a failure can be attributed to images
#     rather than to a broken endpoint/model id;
#   * the verbatim HTTP status and response body for every request;
#   * for raven-ferrus, `key_statuses` from /v1/models (and from any response
#     that carries it) so a backend `connection refused` is never reported as a
#     capability verdict.
#
# Secrets: read at runtime from
#   * /home/nat/Documents/work/info.txt   (`... key = sk-or-...`)
#   * ~/.config/nest/config.toml          ([providers.X] api-key; commented lines ignored)
# and never printed or written. Everything goes through redact/1 at the point of
# writing, so no key can reach stdout or the log. No environment dumps, no key
# tables, no key values in the output at all (labels and lengths only).

defmodule MultimodalProbe do
  @info_file "/home/nat/Documents/work/info.txt"
  @nest_config Path.expand("~/.config/nest/config.toml")
  @openrouter_url "https://openrouter.ai/api/v1/chat/completions"
  @openrouter_key_url "https://openrouter.ai/api/v1/key"
  @deepseek_models_url "https://api.deepseek.com/v1/models"
  @deepseek_models_bare_url "https://api.deepseek.com/models"
  @image_dir Path.join(System.tmp_dir!(), "mm-probe2-images")
  @log_dir Path.expand("../notes/test-runs", __DIR__)

  @question """
  Look at the attached image. How many shapes does it contain, and what colour is the largest shape? \
  Answer in one short sentence.
  """
  @text_question "Reply with exactly this token and nothing else: TEXT-CONTROL-OK"

  # Enough headroom that a reasoning model cannot eat the whole budget and
  # return an empty `content` (a 50-token control returned `finish_reason:
  # length`, `content: null` on the previous attempt).
  @max_tokens 4_000

  # Ground truth. `count`/`colour` are re-measured from the rendered PNG before
  # any request is sent; a mismatch aborts the run (a wrong probe is worthless).
  @image_a %{
    key: :a,
    file: "image-a.png",
    count: 4,
    colour: "green",
    desc: "three 24x24 red squares + one 64px-diameter green circle"
  }
  @image_b %{
    key: :b,
    file: "image-b.png",
    count: 7,
    colour: "yellow",
    desc: "five 36x36 yellow triangles + two 16px-diameter blue circles"
  }
  @colours ~w(red green blue yellow)

  # ---------------------------------------------------------------------------
  # entry point
  # ---------------------------------------------------------------------------

  def main do
    :inets.start()
    :ssl.start()

    or_key = read_openrouter_key()
    providers = read_nest_providers()
    raven = provider!(providers, "raven-ferrus")
    deepseek = provider!(providers, "deepseek")

    secrets = [
      {"info.txt `#{or_key.label}`", or_key.value},
      {"nest providers.raven-ferrus api-key", raven.key},
      {"nest providers.deepseek api-key", deepseek.key}
    ]

    {images, image_evidence} = build_and_verify_images()
    self_test = checker_self_test()

    results = Enum.map(targets(or_key.value, raven, deepseek), &run_target(&1, images))
    metadata = metadata_findings(or_key, raven, deepseek)

    body =
      report(results, image_evidence, self_test, metadata, or_key)
      |> List.flatten()
      |> Enum.join("\n")

    body = redact(body <> "\n", secrets)
    IO.write(body)

    File.mkdir_p!(@log_dir)
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    path = Path.join(@log_dir, "multimodal-probe-#{stamp}.log")
    File.write!(path, body)
    IO.puts("[full raw run output written to #{path}]")

    System.halt(control_exit_code(results))
  end

  # ---------------------------------------------------------------------------
  # secrets (read only; never printed)
  # ---------------------------------------------------------------------------

  # info.txt is a scratch notes file: an example request snippet plus one or
  # more `label = sk-...` lines. We take the LAST line whose value looks like a
  # key (the file has carried a stale key ahead of a live one), and we report
  # the label but never the value.
  defp read_openrouter_key do
    candidates =
      @info_file
      |> File.read!()
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^\s*(.+?)\s*=\s*(\S+)\s*$/, line) do
          [_, label, value] -> if String.starts_with?(value, "sk-"), do: [{label, value}], else: []
          _ -> []
        end
      end)

    case List.last(candidates) do
      {label, value} -> %{label: label, value: value}
      nil -> raise "no `<label> = sk-...` line found in #{@info_file}"
    end
  end

  # Section-aware TOML read: `api-key` only from inside a `[providers.X]` block,
  # never from a commented-out line. `[[providers.X.models]]` maps back to `X`.
  defp read_nest_providers do
    @nest_config
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce({nil, %{}}, &scan_line/2)
    |> elem(1)
  end

  defp scan_line(line, {section, acc}) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "#") -> {section, acc}
      Regex.match?(~r/^\[\[?providers\./, trimmed) -> {provider_section(trimmed), acc}
      String.starts_with?(trimmed, "[") -> {nil, acc}
      true -> {section, put_provider_field(acc, section, trimmed)}
    end
  end

  defp provider_section(header) do
    header
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(".")
    |> Enum.at(1)
  end

  defp put_provider_field(acc, section, line) when is_binary(section) do
    case Regex.run(~r/^(api-key|base-url)\s*=\s*"(.*)"\s*$/, line) do
      [_, field, value] ->
        Map.update(acc, section, %{field => value}, &Map.put(&1, field, value))

      _ ->
        acc
    end
  end

  defp put_provider_field(acc, _section, _line), do: acc

  defp provider!(providers, name) do
    case Map.get(providers, name) do
      %{"api-key" => key, "base-url" => base_url} ->
        %{key: key, base_url: base_url}

      other ->
        raise "provider #{name} missing api-key/base-url in #{@nest_config}: #{inspect(other)}"
    end
  end

  # ---------------------------------------------------------------------------
  # images: render, then MEASURE the ground truth from the pixels
  # ---------------------------------------------------------------------------

  defp build_and_verify_images do
    File.mkdir_p!(@image_dir)
    a = Path.join(@image_dir, "image-a.png")
    b = Path.join(@image_dir, "image-b.png")

    run_convert!([
      "-size",
      "128x128",
      "xc:white",
      "-fill",
      "red",
      "-stroke",
      "none",
      "-draw",
      "rectangle 6,6 29,29",
      "-draw",
      "rectangle 6,40 29,63",
      "-draw",
      "rectangle 6,74 29,97",
      "-fill",
      "lime",
      "-draw",
      "circle 88,64 88,32",
      "-strip",
      "PNG24:#{a}"
    ])

    run_convert!([
      "-size",
      "128x128",
      "xc:white",
      "-fill",
      "yellow",
      "-stroke",
      "none",
      "-draw",
      "polygon 24,4 6,40 42,40",
      "-draw",
      "polygon 72,4 54,40 90,40",
      "-draw",
      "polygon 24,42 6,78 42,78",
      "-draw",
      "polygon 72,42 54,78 90,78",
      "-draw",
      "polygon 24,80 6,116 42,116",
      "-fill",
      "blue",
      "-draw",
      "circle 110,20 110,12",
      "-draw",
      "circle 110,102 110,110",
      "-strip",
      "PNG24:#{b}"
    ])

    evidence =
      [@image_a, @image_b]
      |> Enum.map(fn spec -> {spec, Path.join(@image_dir, spec.file)} end)
      |> Enum.map(fn {spec, path} -> verify_image!(spec, path) end)

    images = %{a: File.read!(a) |> Base.encode64(), b: File.read!(b) |> Base.encode64()}
    {images, evidence}
  end

  defp verify_image!(spec, path) do
    shapes = connected_shapes(path)
    largest = Enum.max_by(shapes, & &1.area)
    measured = %{count: length(shapes), colour: colour_name(largest.colour)}

    if measured.count != spec.count or measured.colour != spec.colour do
      raise """
      image ground-truth verification FAILED for #{spec.file}:
        intended : #{spec.count} shapes, largest #{spec.colour} (#{spec.desc})
        measured : #{measured.count} shapes, largest #{measured.colour}
      The probe would be meaningless; refusing to continue.
      """
    end

    %{spec: spec, path: path, measured: measured, shapes: shapes}
  end

  defp connected_shapes(path) do
    {out, 0} =
      System.cmd(
        "convert",
        [path, "-define", "connected-components:verbose=true", "-connected-components", "8", "null:"],
        stderr_to_stdout: true
      )

    out
    |> String.split("\n")
    |> Enum.flat_map(&parse_component/1)
    # Drop the page-filling white background and the 1px antialiasing specks.
    |> Enum.filter(&(&1.area >= 50 and not near_white?(&1.colour)))
  end

  defp parse_component(line) do
    case Regex.run(
           ~r/^\s*(\d+):\s+(\d+)x(\d+)\+(-?\d+)\+(-?\d+)\s+[\d.,]+\s+(\d+)\s+srgb\((\d+),(\d+),(\d+)\)/,
           line
         ) do
      [_, _id, w, h, x, y, area, r, g, b] ->
        [
          %{
            w: String.to_integer(w),
            h: String.to_integer(h),
            x: String.to_integer(x),
            y: String.to_integer(y),
            area: String.to_integer(area),
            colour: {String.to_integer(r), String.to_integer(g), String.to_integer(b)}
          }
        ]

      _ ->
        []
    end
  end

  defp near_white?({r, g, b}), do: r >= 240 and g >= 240 and b >= 240

  defp colour_name({r, g, b}) do
    cond do
      r > 200 and g < 120 and b < 120 -> "red"
      g > 200 and r < 120 and b < 120 -> "green"
      b > 200 and r < 120 and g < 120 -> "blue"
      r > 200 and g > 200 and b < 120 -> "yellow"
      true -> "unclassified(#{r},#{g},#{b})"
    end
  end

  defp run_convert!(args) do
    case System.cmd("convert", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> raise "convert failed (#{code}): #{out}"
    end
  end

  # ---------------------------------------------------------------------------
  # answer checker (self-tested in-script so a bug here cannot masquerade as a
  # model result)
  # ---------------------------------------------------------------------------

  defp check_answer(nil, _spec) do
    %{number_ok: false, colour_ok: false, correct: false, other_colours: [], note: "no text extracted"}
  end

  defp check_answer(text, spec) do
    number_ok =
      Regex.match?(~r/(?<!\d)#{spec.count}(?!\d)/, text) or
        Enum.any?(number_words(spec.count), &Regex.match?(~r/\b#{&1}\b/i, text))

    colour_ok = Regex.match?(~r/\b#{spec.colour}\b/i, text)

    other_colours =
      Enum.filter(@colours, &(&1 != spec.colour and Regex.match?(~r/\b#{&1}\b/i, text)))

    %{
      number_ok: number_ok,
      colour_ok: colour_ok,
      correct: number_ok and colour_ok,
      other_colours: other_colours,
      note: nil
    }
  end

  defp number_words(4), do: ["four"]
  defp number_words(7), do: ["seven"]
  defp number_words(_), do: []

  defp checker_self_test do
    cases = [
      {"There are 4 shapes and the largest is the green circle.", @image_a, true},
      {"There are four shapes; the largest one is green.", @image_a, true},
      {"There are 7 shapes and the largest is a yellow triangle.", @image_b, true},
      {"There are seven shapes and the largest is yellow.", @image_b, true},
      {"I cannot see any image; please attach one.", @image_a, false},
      {"There are 7 shapes and the largest is a yellow triangle.", @image_a, false},
      {"There are 4 shapes and the largest is the green circle.", @image_b, false},
      {"", @image_a, false}
    ]

    Enum.map(cases, fn {text, spec, expected} ->
      got = check_answer(text, spec).correct
      %{text: text, spec: spec.key, expected: expected, got: got, pass: got == expected}
    end)
  end

  # ---------------------------------------------------------------------------
  # targets
  # ---------------------------------------------------------------------------

  defp targets(or_key, raven, deepseek) do
    or_target = fn model, control ->
      %{
        label: model,
        provider: "openrouter.ai",
        wire: :openai,
        kind: :openrouter,
        url: @openrouter_url,
        model: model,
        key: or_key,
        timeout: 240_000,
        control: control
      }
    end

    [
      or_target.("qwen/qwen3.8-flash", :known_positive),
      or_target.("qwen/qwen3-coder-flash", :known_negative),
      or_target.("deepseek/deepseek-v4.1-flash", nil),
      or_target.("deepseek/deepseek-v4-flash-0731", nil),
      %{
        label: "vllm/realderpz/Swift-1.5-Qwen3.8-27B-FP8",
        provider: "raven.ferrus.net",
        wire: :openai,
        kind: :raven,
        url: String.trim_trailing(raven.base_url, "/") <> "/chat/completions",
        models_url: String.trim_trailing(raven.base_url, "/") <> "/models",
        model: "vllm/realderpz/Swift-1.5-Qwen3.8-27B-FP8",
        key: raven.key,
        timeout: 300_000,
        control: nil
      },
      %{
        label: "deepseek-flash",
        provider: "api.deepseek.com/anthropic",
        wire: :anthropic,
        kind: :deepseek,
        # Matches Nest.LLM.AnthropicClient.normalize_endpoint/2: base-url
        # "https://api.deepseek.com/anthropic" has no /v1 to strip, so the
        # messages endpoint is <base>/v1/messages.
        url: String.trim_trailing(deepseek.base_url, "/") <> "/v1/messages",
        model: "deepseek-flash",
        key: deepseek.key,
        timeout: 300_000,
        control: nil
      }
    ]
  end

  defp run_target(target, images) do
    text_control = request(target, @text_question, nil)
    image_a = request(target, @question, images.a)
    image_b = request(target, @question, images.b)
    responses = [text_control, image_a, image_b]

    result = %{
      target: target,
      text_control: text_control,
      image_a: image_a,
      image_b: image_b,
      check_a: check_answer(image_a.text, @image_a),
      check_b: check_answer(image_b.text, @image_b),
      routing: routing_snapshot(target, responses)
    }

    {verdict, reason} = decide(result)

    Map.merge(result, %{
      verdict: verdict,
      reason: reason,
      differ: not same_answer?(image_a.text, image_b.text)
    })
  end

  # ---------------------------------------------------------------------------
  # HTTP
  # ---------------------------------------------------------------------------

  defp request(target, text, image_b64) do
    {headers, body} = build_request(target, text, image_b64)
    started = System.monotonic_time(:millisecond)
    resp = http_post(target.url, headers, body, target.timeout)
    elapsed = System.monotonic_time(:millisecond) - started

    resp
    |> Map.put(:elapsed_ms, elapsed)
    |> Map.put(:logged_body, elide_image(body, image_b64))
    |> Map.put(:header_names, Enum.map(headers, fn {k, _} -> k end))
    |> parse_response(target.wire)
  end

  defp build_request(target, text, image_b64) do
    case target.wire do
      :openai ->
        content =
          case image_b64 do
            nil ->
              text

            b64 ->
              [
                %{"type" => "text", "text" => text},
                %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64," <> b64}}
              ]
          end

        body =
          JSON.encode!(%{
            "model" => target.model,
            "max_tokens" => @max_tokens,
            "temperature" => 0,
            "messages" => [%{"role" => "user", "content" => content}]
          })

        {[{"authorization", "Bearer " <> target.key}, {"content-type", "application/json"}], body}

      :anthropic ->
        content =
          case image_b64 do
            nil ->
              [%{"type" => "text", "text" => text}]

            b64 ->
              [
                %{
                  "type" => "image",
                  "source" => %{"type" => "base64", "media_type" => "image/png", "data" => b64}
                },
                %{"type" => "text", "text" => text}
              ]
          end

        body =
          JSON.encode!(%{
            "model" => target.model,
            "max_tokens" => @max_tokens,
            "temperature" => 0,
            "messages" => [%{"role" => "user", "content" => content}]
          })

        {[
           {"x-api-key", target.key},
           {"anthropic-version", "2023-06-01"},
           {"content-type", "application/json"}
         ], body}
    end
  end

  defp elide_image(body, nil), do: body

  defp elide_image(body, b64) do
    marker = "<base64 PNG elided: #{byte_size(b64)} chars, sha256=#{short_sha(b64)}>"
    String.replace(body, b64, marker)
  end

  defp short_sha(binary) do
    :sha256
    |> :crypto.hash(binary)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp http_post(url, headers, body, timeout) do
    hdrs = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
    request = {String.to_charlist(url), hdrs, ~c"application/json", body}

    case :httpc.request(:post, request, http_opts(timeout), body_format: :binary) do
      {:ok, {{_v, status, _r}, _hdrs, resp_body}} ->
        %{status: status, transport_error: nil, body: resp_body}

      {:error, reason} ->
        %{status: nil, transport_error: inspect(reason), body: ""}
    end
  end

  defp http_get(url, headers, timeout) do
    hdrs = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
    request = {String.to_charlist(url), hdrs}

    case :httpc.request(:get, request, http_opts(timeout), body_format: :binary) do
      {:ok, {{_v, status, _r}, _hdrs, resp_body}} -> %{status: status, body: resp_body}
      {:error, reason} -> %{status: nil, body: "transport error: #{inspect(reason)}"}
    end
  end

  defp http_opts(timeout) do
    [
      timeout: timeout,
      connect_timeout: 20_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  defp parse_response(resp, wire) do
    json =
      case JSON.decode(resp.body) do
        {:ok, decoded} -> decoded
        {:error, _} -> nil
      end

    {text, extract_error} = extract_text(json, wire)

    resp
    |> Map.merge(%{json: json, text: text, extract_error: extract_error, meta: response_meta(json, wire)})
  end

  defp extract_text(json, _wire) when not is_map(json) do
    {nil, "response body is not a JSON object"}
  end

  defp extract_text(json, :openai) do
    case get_in(json, ["choices", Access.at(0), "message"]) do
      msg when is_map(msg) ->
        case msg["content"] do
          t when is_binary(t) ->
            {t, nil}

          parts when is_list(parts) ->
            {Enum.map_join(parts, "", fn p -> if is_map(p), do: p["text"] || "", else: "" end), nil}

          _ ->
            {nil, "message.content absent; message keys=#{inspect(Map.keys(msg) |> Enum.sort())}"}
        end

      _ ->
        {nil, "no choices[0].message; top-level keys=#{inspect(Map.keys(json) |> Enum.sort())}"}
    end
  end

  defp extract_text(json, :anthropic) do
    case json["content"] do
      blocks when is_list(blocks) ->
        text =
          blocks
          |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
          |> Enum.map_join("", &(&1["text"] || ""))

        if text == "" do
          {nil,
           "no text blocks; block types=#{inspect(Enum.map(blocks, &if(is_map(&1), do: &1["type"], else: &1)))}"}
        else
          {text, nil}
        end

      _ ->
        {nil, "no content array; top-level keys=#{inspect(Map.keys(json) |> Enum.sort())}"}
    end
  end

  defp response_meta(json, :openai) when is_map(json) do
    choice = get_in(json, ["choices", Access.at(0)]) || %{}
    msg = choice["message"] || %{}

    %{
      finish_reason: choice["finish_reason"],
      reasoning_chars:
        byte_size(to_string(msg["reasoning"] || msg["reasoning_content"] || "")),
      model_returned: json["model"],
      provider: json["provider"]
    }
  end

  defp response_meta(json, :anthropic) when is_map(json) do
    blocks = if is_list(json["content"]), do: json["content"], else: []

    thinking =
      blocks
      |> Enum.filter(&(is_map(&1) and &1["type"] == "thinking"))
      |> Enum.map_join("", &(&1["thinking"] || ""))

    %{
      finish_reason: json["stop_reason"],
      reasoning_chars: byte_size(thinking),
      model_returned: json["model"],
      provider: json["provider"]
    }
  end

  defp response_meta(_json, _wire) do
    %{finish_reason: nil, reasoning_chars: 0, model_returned: nil, provider: nil}
  end

  # ---------------------------------------------------------------------------
  # raven-ferrus routing evidence
  # ---------------------------------------------------------------------------

  # The chat endpoint does NOT return `key_statuses` (measured: absent), so on
  # the happy path we report the routing_info that says which backend key served
  # the request; when a request fails we re-fetch /v1/models to capture the
  # gateway's own `key_statuses` at that moment. A failed request plus failing
  # key_statuses is a ROUTING failure, never a capability verdict.
  defp routing_snapshot(%{kind: :raven} = target, responses) do
    per_request =
      Enum.map(responses, fn r ->
        json = r.json || %{}

        %{
          status: r.status,
          key_statuses: json["key_statuses"],
          routing_info: get_in(json, ["extra_fields", "routing_info"]),
          extra_fields_error: get_in(json, ["extra_fields", "error"])
        }
      end)

    refetch =
      if Enum.any?(responses, &(&1.status != 200)) do
        fetch_models(target)
      else
        nil
      end

    %{per_request: per_request, refetch: refetch}
  end

  defp routing_snapshot(_target, _responses), do: nil

  defp fetch_models(target) do
    resp = http_get(target.models_url, [{"authorization", "Bearer " <> target.key}], 60_000)

    json =
      case JSON.decode(resp.body) do
        {:ok, decoded} -> decoded
        {:error, _} -> nil
      end

    %{status: resp.status, body: resp.body, key_statuses: json && json["key_statuses"]}
  end

  defp key_status_entries(routing) when is_map(routing) do
    from_requests =
      routing.per_request
      |> Enum.map(& &1.key_statuses)
      |> Enum.reject(&is_nil/1)
      |> List.flatten()

    from_refetch = (routing.refetch && routing.refetch.key_statuses) || []

    (from_requests ++ from_refetch)
    |> Enum.filter(&is_map/1)
    |> Enum.uniq_by(& &1["key_id"])
  end

  defp key_status_entries(_), do: []

  defp failing_key_status?(entry) do
    status = entry["status"]

    status not in ["success", "list_models_success"] or
      connection_refused?(entry)
  end

  defp connection_refused?(entry) do
    text = inspect(entry)

    String.contains?(text, "connection refused") or
      String.contains?(text, "provider_connection_failed")
  end

  defp routing_failure?(result) do
    entries = key_status_entries(result.routing)
    entries != [] and Enum.any?(entries, &failing_key_status?/1)
  end

  defp routing_summary(result) do
    result.routing
    |> key_status_entries()
    |> Enum.filter(&failing_key_status?/1)
    |> Enum.map_join("; ", fn e ->
      "#{e["key_id"]} -> #{e["status"]} (#{error_message(e)})"
    end)
  end

  defp error_message(entry) do
    get_in(entry, ["error", "error", "error"]) ||
      get_in(entry, ["error", "error", "message"]) ||
      inspect(entry["error"])
  end

  # ---------------------------------------------------------------------------
  # verdict
  # ---------------------------------------------------------------------------

  defp decide(result) do
    tc = result.text_control
    a = result.image_a
    b = result.image_b

    cond do
      tc.status != 200 ->
        {:inconclusive,
         "text-only control did not return HTTP 200 (#{status_str(tc)}) — the endpoint/model is unusable, " <>
           "so any image outcome cannot be attributed to image support"}

      empty?(tc.text) ->
        {:inconclusive,
         "text-only control returned HTTP 200 but carried no text (#{empty_reason(tc)}) — " <>
           "a reasoning-eaten token budget is not a capability result"}

      a.status != 200 or b.status != 200 ->
        cond do
          explicit_image_rejection?(a) or explicit_image_rejection?(b) ->
            {:not_multimodal,
             "server rejected the image request with an explicit unsupported-input error " <>
               "(#{status_str(a)} / #{status_str(b)}): #{rejection_snippet([a, b])}"}

          routing_failure?(result) ->
            {:inconclusive,
             "image request failed AND raven-ferrus reports backend routing failures " <>
               "(#{routing_summary(result)}) — this is a routing failure, not a capability result"}

          true ->
            {:inconclusive,
             "image request failed without an explicit unsupported-input error (#{status_str(a)} / #{status_str(b)})"}
        end

      empty?(a.text) or empty?(b.text) ->
        resp = if empty?(a.text), do: a, else: b

        {:inconclusive,
         "HTTP 200 but the reply carried no text (#{empty_reason(resp)}) — a token budget consumed by " <>
           "reasoning is not a capability result"}

      same_answer?(a.text, b.text) and result.check_a.correct and result.check_b.correct ->
        {:inconclusive, "identical answers scored correct for both images — the answer checker is ambiguous here"}

      result.check_a.correct and result.check_b.correct ->
        {:multimodal, "accepted both images, answered BOTH correctly, and the two answers differ"}

      same_answer?(a.text, b.text) ->
        {:not_multimodal,
         "identical answer for two different images — no evidence of perception (the model cannot be reading the image)"}

      result.check_a.correct or result.check_b.correct ->
        {:inconclusive, "accepted both images but answered only one of them correctly"}

      true ->
        {:inconclusive, "accepted both images, both answers incorrect (they differ, so this is not a same-answer guess)"}
    end
  end

  defp empty?(text), do: is_nil(text) or String.trim(text) == ""

  defp empty_reason(resp) do
    finish = resp.meta.finish_reason
    reasoning = resp.meta.reasoning_chars

    parts =
      [
        if(finish, do: "finish_reason=#{finish}", else: nil),
        if(reasoning > 0, do: "reasoning_chars=#{reasoning}", else: nil),
        resp.extract_error
      ]

    parts |> Enum.reject(&is_nil/1) |> Enum.join("; ")
  end

  defp explicit_image_rejection?(resp) do
    is_integer(resp.status) and resp.status >= 400 and resp.status < 500 and
      Regex.match?(
        ~r/image|vision|multimodal|unsupported|media[_ ]?type|content[-_ ]?type|image_url|modality/i,
        resp.body
      )
  end

  defp rejection_snippet(responses) do
    responses
    |> Enum.filter(&(is_integer(&1.status) and &1.status >= 400))
    |> Enum.map_join(" | ", fn r ->
      "#{status_str(r)} #{String.slice(String.replace(r.body, ~r/\s+/, " "), 0, 200)}"
    end)
  end

  defp same_answer?(a, b) when is_binary(a) and is_binary(b), do: normalize(a) == normalize(b)
  defp same_answer?(nil, nil), do: true
  defp same_answer?(_, _), do: false

  defp normalize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp status_str(resp) do
    cond do
      is_integer(resp.status) -> "HTTP #{resp.status}"
      resp.transport_error -> "transport error #{resp.transport_error}"
      true -> "no response"
    end
  end

  defp control_exit_code(results) do
    failures =
      results
      |> Enum.filter(&(&1.target.control in [:known_positive, :known_negative]))
      |> Enum.filter(fn r ->
        case {r.target.control, r.verdict} do
          {:known_positive, :multimodal} -> false
          {:known_negative, :not_multimodal} -> false
          {_, :inconclusive} -> false
          _ -> true
        end
      end)

    if failures == [] do
      0
    else
      IO.puts("\n!!! CONTROL FAILURE — THE SCRIPT IS WRONG, NOT THE MODELS !!!")
      Enum.each(failures, fn r -> IO.puts("  #{r.target.label}: control=#{r.target.control} verdict=#{r.verdict}") end)
      2
    end
  end

  # ---------------------------------------------------------------------------
  # metadata appendix (explicitly NOT evidence; context only)
  # ---------------------------------------------------------------------------

  defp metadata_findings(or_key, raven, deepseek) do
    [
      {"deepseek model list — which URL serves modality metadata", deepseek_model_list_probe(deepseek)},
      {"deepseek model list — the path the app's discovery actually calls", deepseek_discovery_path(deepseek)},
      {"raven-ferrus /v1/models — key_statuses is backend routing state", raven_models(raven)},
      {"openrouter key check (label and limits only; value never printed)", openrouter_key_check(or_key)}
    ]
  end

  # The app's `Nest.LLM.Discover.fetch_models/1` calls `GET <base_url>/models`.
  # For deepseek that base_url is https://api.deepseek.com/anthropic, so the app
  # asks the Anthropic-shaped path — which serves no model list at all.
  defp deepseek_model_list_probe(deepseek) do
    bearer = [{"authorization", "Bearer " <> deepseek.key}]

    v1 = http_get(@deepseek_models_url, bearer, 60_000)
    bare = http_get(@deepseek_models_bare_url, bearer, 60_000)

    lines = [
      "    GET #{@deepseek_models_url}",
      "      -> #{get_status(v1)} bytes=#{byte_size(v1.body)} sha256=#{short_sha(v1.body)}",
      "    GET #{@deepseek_models_bare_url}",
      "      -> #{get_status(bare)} bytes=#{byte_size(bare.body)} sha256=#{short_sha(bare.body)}",
      "    byte-identical: #{v1.body == bare.body}"
    ]

    lines ++
      case JSON.decode(v1.body) do
        {:ok, %{"data" => data}} when is_list(data) ->
          ["    body (verbatim): #{v1.body}", "    declared modalities:"] ++
            Enum.map(data, fn m ->
              "      #{m["id"]} (name=#{m["name"]}): input_modalities=#{inspect(m["input_modalities"])} " <>
                "output_modalities=#{inspect(m["output_modalities"])} context_window=#{inspect(m["context_window"])}"
            end) ++
            [
              "    NOTE: Nest.LLM.Discover.extract_multi_modal_from_model/1 already recognizes a",
              "          top-level `input_modalities` list (the atlascloud shape). Pointing the",
              "          deepseek provider's discovery at https://api.deepseek.com/v1 would therefore",
              "          pick up image support for deepseek-flash without any code change."
            ]

        _ ->
          ["    body: #{String.slice(v1.body, 0, 500)}"]
      end
  end

  defp deepseek_discovery_path(deepseek) do
    url = String.trim_trailing(deepseek.base_url, "/") <> "/models"
    resp = http_get(url, [{"x-api-key", deepseek.key}, {"anthropic-version", "2023-06-01"}], 60_000)

    [
      "    GET #{url} (what `GET <base-url>/models` resolves to for the configured provider)",
      "      -> #{get_status(resp)} bytes=#{byte_size(resp.body)} body=#{inspect(resp.body)}"
    ]
  end

  defp raven_models(raven) do
    url = String.trim_trailing(raven.base_url, "/") <> "/models"
    resp = http_get(url, [{"authorization", "Bearer " <> raven.key}], 60_000)

    case JSON.decode(resp.body) do
      {:ok, json} ->
        models =
          json
          |> Map.get("data", [])
          |> Enum.map(fn m -> "      #{m["id"]}: keys=#{inspect(Map.keys(m) |> Enum.sort())}" end)

        statuses =
          json
          |> Map.get("key_statuses", [])
          |> Enum.map(fn e ->
            "      key_id=#{e["key_id"]} status=#{e["status"]} provider=#{e["provider"]} " <>
              "error=#{if e["error"], do: error_message(e), else: "-"}"
          end)

        ["    GET #{url}", "      -> #{get_status(resp)} bytes=#{byte_size(resp.body)}", "    models (no modality keys):"] ++
          models ++ ["    key_statuses:"] ++ statuses

      _ ->
        ["    GET #{url}", "      -> #{get_status(resp)} bytes=#{byte_size(resp.body)}", "    body: #{String.slice(resp.body, 0, 500)}"]
    end
  end

  defp openrouter_key_check(or_key) do
    resp = http_get(@openrouter_key_url, [{"authorization", "Bearer " <> or_key.value}], 30_000)

    ["    GET #{@openrouter_key_url}", "      -> #{get_status(resp)} bytes=#{byte_size(resp.body)}", "    body: #{resp.body}"]
  end

  defp get_status(%{status: nil} = resp), do: "transport error: #{resp.body}"
  defp get_status(resp), do: "HTTP #{resp.status}"

  # ---------------------------------------------------------------------------
  # report
  # ---------------------------------------------------------------------------

  defp report(results, image_evidence, self_test, metadata, or_key) do
    [
      header(or_key),
      image_section(image_evidence),
      self_test_section(self_test),
      results_section(results),
      summary_section(results),
      control_section(results),
      routing_section(results),
      metadata_section(metadata),
      raw_evidence_section(results),
      interpretation_section()
    ]
  end

  defp header(or_key) do
    [
      String.duplicate("=", 100),
      "MULTIMODAL PROBE — does each model ACCEPT and PERCEIVE image input?",
      "run at (UTC): #{DateTime.utc_now() |> DateTime.to_iso8601()}",
      "re-run: cd /home/nat/Code/nest && elixir scripts/multimodal-probe.exs",
      "",
      "OpenRouter key source: #{@info_file}, line labelled `#{or_key.label}` " <>
        "(#{String.length(or_key.value)} chars; value never printed or written).",
      "Target keys: read from [providers.*] blocks of #{@nest_config}; values never printed or written.",
      String.duplicate("=", 100),
      ""
    ]
  end

  defp image_section(evidence) do
    [
      "## 1. Probe images (ground truth MEASURED from the rendered pixels, not asserted)",
      ""
    ] ++
      Enum.flat_map(evidence, fn ev ->
        shape_lines =
          ev.shapes
          |> Enum.sort_by(& &1.area, :desc)
          |> Enum.map(fn s ->
            "      #{s.w}x#{s.h} at +#{s.x}+#{s.y}  area=#{s.area}  colour=#{colour_name(s.colour)}"
          end)

        [
          "  #{ev.spec.file}: #{ev.spec.desc}",
          "    measured: #{ev.measured.count} shapes, largest = #{ev.measured.colour}",
          "    connected components (area >= 50, background excluded):",
          shape_lines,
          ""
        ]
      end) ++
      [
        "  Question asked about each image (identical text for both):",
        "    #{String.trim(@question)}",
        "  Expected: image-a -> #{@image_a.count} shapes, largest #{@image_a.colour}",
        "            image-b -> #{@image_b.count} shapes, largest #{@image_b.colour}",
        ""
      ]
  end

  defp self_test_section(self_test) do
    fails = Enum.reject(self_test, & &1.pass)

    [
      "## 2. Answer-checker self-test (#{length(self_test)} cases, #{length(fails)} failures)"
    ] ++
      Enum.map(self_test, fn c ->
        "    [#{if c.pass, do: "pass", else: "FAIL"}] spec=#{c.spec} expected=#{c.expected} got=#{c.got} :: #{inspect(c.text)}"
      end) ++ [""]
  end

  defp results_section(results) do
    ["## 3. Per-target detail", ""] ++ Enum.flat_map(results, &result_lines/1)
  end

  defp result_lines(r) do
    t = r.target

    [
      "### #{t.label}",
      "  provider    : #{t.provider}",
      "  wire format : #{if t.wire == :openai, do: "OpenAI (image_url data: URL)", else: "Anthropic (base64 source block)"}",
      "  endpoint    : #{t.url}",
      "  auth header : #{Enum.join(r.text_control.header_names, ", ")}",
      "  control     : #{inspect(t.control)}",
      "",
      "  text-only control: #{status_str(r.text_control)} (#{r.text_control.elapsed_ms} ms)",
      "    answer: #{inspect(r.text_control.text)}",
      "    meta  : #{inspect(r.text_control.meta)}",
      "    note  : #{inspect(r.text_control.extract_error)}",
      "",
      "  image-a (#{@image_a.count} shapes, largest #{@image_a.colour}): #{status_str(r.image_a)} (#{r.image_a.elapsed_ms} ms)",
      "    number_ok=#{r.check_a.number_ok} colour_ok=#{r.check_a.colour_ok} correct=#{r.check_a.correct} other_colours=#{inspect(r.check_a.other_colours)}",
      "    answer: #{inspect(r.image_a.text)}",
      "    meta  : #{inspect(r.image_a.meta)}",
      "",
      "  image-b (#{@image_b.count} shapes, largest #{@image_b.colour}): #{status_str(r.image_b)} (#{r.image_b.elapsed_ms} ms)",
      "    number_ok=#{r.check_b.number_ok} colour_ok=#{r.check_b.colour_ok} correct=#{r.check_b.correct} other_colours=#{inspect(r.check_b.other_colours)}",
      "    answer: #{inspect(r.image_b.text)}",
      "    meta  : #{inspect(r.image_b.meta)}",
      "",
      "  answers differ: #{r.differ}",
      "  VERDICT: #{String.upcase(to_string(r.verdict))} — #{r.reason}",
      ""
    ]
  end

  defp summary_section(results) do
    [
      "## 4. Summary table",
      "",
      "  | target | provider | wire | text-ctl | imgA | imgB | A correct | B correct | differ | verdict |",
      "  |---|---|---|---|---|---|---|---|---|---|"
    ] ++
      Enum.map(results, fn r ->
        t = r.target

        "  | #{t.label} | #{t.provider} | #{t.wire} | #{short_status(r.text_control)} | #{short_status(r.image_a)} | " <>
          "#{short_status(r.image_b)} | #{r.check_a.correct} | #{r.check_b.correct} | #{r.differ} | #{String.upcase(to_string(r.verdict))} |"
      end) ++ [""]
  end

  defp short_status(resp), do: if(is_integer(resp.status), do: Integer.to_string(resp.status), else: "ERR")

  defp control_section(results) do
    [
      "## 5. Calibration controls",
      ""
    ] ++ Enum.map(control_results(results), &control_line/1) ++ [""]
  end

  defp control_results(results) do
    Enum.filter(results, &(&1.target.control in [:known_positive, :known_negative]))
  end

  defp control_line(r) do
    evaluated? = r.text_control.status == 200 and not empty?(r.text_control.text)

    got =
      if evaluated? do
        String.upcase(to_string(r.verdict))
      else
        "NOT EVALUATED (#{status_str(r.text_control)}: the control request never reached the model)"
      end

    required =
      case r.target.control do
        :known_positive -> "REQUIRED=MULTIMODAL"
        :known_negative -> "REQUIRED=NOT MULTIMODAL"
      end

    "  #{String.pad_trailing(r.target.label, 24)}: #{required}  GOT=#{got}  (#{r.reason})"
  end

  defp routing_section(results) do
    raven = Enum.filter(results, &(&1.target.kind == :raven))

    case raven do
      [] ->
        ["## 6. raven-ferrus key_statuses", "", "  (no raven-ferrus target in this run)", ""]

      targets ->
        ["## 6. raven-ferrus key_statuses (backend routing state; a `connection refused` here is NOT a capability verdict)", ""] ++
          Enum.flat_map(targets, &routing_lines/1)
    end
  end

  defp routing_lines(r) do
    [
      "  target: #{r.target.label}",
      "  key_statuses present in each chat response: #{inspect(Enum.map(r.routing.per_request, & &1.key_statuses))}",
      "  routing_info per chat response (which backend key served it):"
    ] ++
      Enum.map(r.routing.per_request, fn p ->
        "    status=#{inspect(p.status)} routing_info=#{inspect(p.routing_info)} extra_fields.error=#{inspect(p.extra_fields_error)}"
      end) ++
      case r.routing.refetch do
        nil ->
          ["  (no failed request, so /v1/models was not re-fetched for this target)", ""]

        refetch ->
          ["  /v1/models re-fetched because a request failed: #{inspect(refetch.status)}"] ++
            Enum.map(refetch.key_statuses || [], fn e ->
              "    key_id=#{e["key_id"]} status=#{e["status"]} error=#{if e["error"], do: error_message(e), else: "-"}"
            end) ++ [""]
      end
  end

  defp metadata_section(metadata) do
    ["## 7. Metadata appendix (context only — NOT evidence)", ""] ++
      Enum.flat_map(metadata, fn {name, lines} -> ["  #{name}:"] ++ lines ++ [""] end)
  end

  defp raw_evidence_section(results) do
    ["## 8. Raw evidence (verbatim HTTP status and response bodies)", ""] ++
      Enum.flat_map(results, fn r ->
        [
          "### #{r.target.label} — #{r.target.url}",
          "  auth header names only (values redacted): #{Enum.join(r.text_control.header_names, ", ")}",
          Enum.flat_map(
            [{"text-control", r.text_control}, {"image-a", r.image_a}, {"image-b", r.image_b}],
            fn {label, resp} ->
              [
                "  --- #{label} ---",
                "  request body: #{resp.logged_body}",
                "  status: #{status_str(resp)} (elapsed #{resp.elapsed_ms} ms)",
                "  response body: #{resp.body}",
                ""
              ]
            end
          )
        ]
      end)
  end

  defp interpretation_section do
    [
      "## 9. Verdict key",
      "  MULTIMODAL      = 2xx on both images AND both answered correctly AND the two answers differ",
      "  NOT MULTIMODAL  = image request rejected with an explicit unsupported-input error, OR accepted",
      "                    but the same answer came back for two different images (i.e. guessing)",
      "  INCONCLUSIVE    = anything else, with the reason stated (never softened into a verdict).",
      "                    Includes: text control unusable, empty content (reasoning ate the token",
      "                    budget), a raven-ferrus routing failure, or one-of-two correct.",
      ""
    ]
  end

  # ---------------------------------------------------------------------------
  # redaction (applied at the point of writing, never afterwards)
  # ---------------------------------------------------------------------------

  defp redact(text, secrets) do
    Enum.reduce(secrets, text, fn {name, value}, acc ->
      if is_binary(value) and value != "" do
        String.replace(acc, value, "<REDACTED: #{name}>")
      else
        acc
      end
    end)
    |> redact_key_labels()
    |> redact_any_sk()
  end

  # OpenRouter's /key body echoes an elided form of the key as `label`; redact
  # the whole field rather than leaking a prefix of the secret.
  defp redact_key_labels(text) do
    Regex.replace(~r/"label"\s*:\s*"[^"]*"/, text, ~s("label": "<REDACTED>"))
  end

  # Belt and braces: no `sk-...` token of any kind may survive into the output.
  defp redact_any_sk(text) do
    Regex.replace(~r/sk-[A-Za-z0-9_-]{10,}/, text, "<REDACTED-SK-TOKEN>")
  end
end

MultimodalProbe.main()
