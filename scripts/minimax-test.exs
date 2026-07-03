# scripts/minimax-test.exs
#
# Read-only probe of https://api.minimax.io/v1/models using the
# bearer token from your ~/.config/nest/config.toml. Prints the
# response shape and walks the response through the same logic
# `Nest.Models.query_provider/1` uses on startup, so you can see
# exactly what (if anything) gets into the merged model list
# and the per-provider context-limit cache.
#
# Run with:
#   mix run scripts/minimax-test.exs
#
# The API key is read but never logged; only its prefix and
# length are printed.

alias Nest.LLM.Discover

cfg_path = Path.expand("~/.config/nest/config.toml")

read_section = fn body ->
  case Regex.run(~r/\[providers\.minimax\]([^[]*)/, body, capture: :all_but_first) do
    [section | _] -> {:ok, section}
    nil -> {:error, :no_minimax_section}
  end
end

read_key = fn section ->
  case Regex.run(~r/api-key\s*=\s*"([^"]+)"/, section, capture: :all_but_first) do
    [k] -> {:ok, k}
    _ -> {:error, :no_api_key}
  end
end

read_url = fn section ->
  case Regex.run(~r/base-url\s*=\s*"([^"]+)"/, section, capture: :all_but_first) do
    [u] -> {:ok, u}
    _ -> {:error, :no_base_url}
  end
end

with {:ok, content} <- File.read(cfg_path) |> then(fn
       {:ok, c} -> {:ok, c}
       e -> e
     end),
     {:ok, section} <- read_section.(content),
     {:ok, base_url} <- read_url.(section),
     {:ok, key} <- read_key.(section) do
  mask = String.slice(key, 0, 5) <> "...(#{byte_size(key)} chars)"
  url = base_url <> "/models"
  IO.puts("== Probe ==")
  IO.puts("url  : #{url}")
  IO.puts("auth : #{mask}")

  case Req.get(url, headers: [{"Authorization", "Bearer " <> key}], receive_timeout: 5_000) do
    {:ok, %Req.Response{status: status, body: body}} ->
      IO.puts("status: #{status}")

      entries =
        cond do
          is_map(body) and is_list(body["data"]) ->
            IO.puts("shape : OpenAI {\"data\": [...]} (#{length(body["data"])} entries)")
            body["data"]

          is_map(body) and is_list(body["models"]) ->
            IO.puts("shape : Ollama {\"models\": [...]} (#{length(body["models"])} entries)")
            body["models"]

          is_list(body) ->
            IO.puts("shape : bare list (#{length(body)} entries)")
            body

          true ->
            IO.puts("shape : UNRECOGNIZED #{inspect(body) |> String.slice(0, 200)}")
            []
        end

      if entries != [] do
        first = hd(entries)
        IO.puts("")
        IO.puts("First entry:")
        IO.puts("  keys: #{inspect(Map.keys(first))}")
        IO.puts("  raw : #{inspect(first)}")

        limit_field =
          cond do
            is_integer(first["max_model_len"]) -> {:vllm, first["max_model_len"]}
            is_integer(first["context_length"]) -> {:openrouter, first["context_length"]}
            is_map(first["meta"]) and is_integer(first["meta"]["n_ctx"]) ->
              {:llama_cpp, first["meta"]["n_ctx"]}
            is_map(first["meta"]) and is_integer(first["meta"]["n_ctx_train"]) ->
              {:llama_cpp, first["meta"]["n_ctx_train"]}
            true -> nil
          end

        IO.puts("")
        IO.puts("Recognized limit field on first entry: #{inspect(limit_field)}")
      end

      IO.puts("")
      IO.puts("== Walking through Discover + ChatModel logic ==")

      names = Enum.map(entries, &Discover.model_id/1) |> Enum.reject(&is_nil/1)
      IO.puts("Discover.model_id recognized: #{length(names)} / #{length(entries)} entries")
      ellipsis = if length(names) > 5, do: "...", else: ""
      IO.puts("  names: #{inspect(Enum.take(names, 5))}#{ellipsis}")

      limited =
        Enum.flat_map(entries, fn entry ->
          with name when is_binary(name) <- Discover.model_id(entry),
               {source, limit} <- Discover.extract_limit_from_model(entry) do
            [%{name: name, source: source, limit: limit}]
          else
            _ -> []
          end
        end)

      IO.puts(
        "ChatModel.list_models_with_limits recognized: #{length(limited)} / #{length(entries)} entries"
      )

      cond do
        length(entries) == 0 ->
          IO.puts("")
          IO.puts("Verdict: provider returned 0 entries — startup will see no models.")

        length(limited) == 0 and length(names) > 0 ->
          IO.puts("")
          IO.puts(
            "Verdict: response has #{length(names)} model name(s) but NONE carry a recognized"
          )
          IO.puts("         context-limit field (max_model_len / context_length / meta.n_ctx).")
          IO.puts(
            "         Today (pre-fix), every entry is silently dropped, so the provider"
          )
          IO.puts("         appears as \"0 models\" in Nest.Models.list/0 even though")
          IO.puts("         the network call succeeded.")

        length(limited) > 0 ->
          IO.puts("")
          IO.puts("Verdict: #{length(limited)} entries pass; merged list gets those names with limits cached.")
      end

    {:error, reason} ->
      IO.puts("error : #{inspect(reason)}")
  end
else
  {:error, reason} ->
    IO.puts("Could not read [providers.minimax] from #{cfg_path}: #{inspect(reason)}")
end
