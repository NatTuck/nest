# Probe provider endpoints and list discoverable models.
#
#     mix run scripts/probe-provider.exs            # probe every provider
#     mix run scripts/probe-provider.exs gemini     # probe one provider
#
# For each provider this runs the endpoint probe sequence
# (`Nest.EndpointProbe`), caches the result (`Nest.EndpointCache`),
# prints the resolved chat protocol, chat base URL and discovery
# endpoint, then lists the models discoverable at that endpoint.
# This is the manual companion to the automatic startup probing: run
# it to figure out the right `base-url` / `protocol` / `probe-base-url`
# for a provider you're adding, or to verify an existing one.

alias Nest.ChatModel
alias Nest.DotConfig
alias Nest.EndpointCache
alias Nest.EndpointProbe

Application.ensure_all_started(:nest)

config = DotConfig.load!()

providers =
  case System.argv() do
    [name | _] ->
      case DotConfig.get_provider(config, name) do
        nil ->
          IO.puts("Provider not found: #{name}")
          System.halt(1)

        provider ->
          [provider]
      end

    _ ->
      Map.values(config.providers)
  end

defmodule ProbePrinter do
  def annotate(true), do: " (probed)"
  def annotate(_), do: " (assumed)"
end

Enum.each(providers, fn provider ->
  IO.puts("\n=== #{provider.name} ===")
  IO.puts("  base-url:       #{provider.base_url || "(none)"}")
  IO.puts("  probe-base-url: #{provider.probe_base_url || "(unset)"}")

  case EndpointProbe.probe(provider) do
    {:ok, structure} ->
      EndpointCache.probe_and_cache(provider)

      IO.puts("  protocol:       #{structure.protocol}#{ProbePrinter.annotate(structure.protocol_resolved?)}")
      IO.puts("  chat base:      #{structure.chat_base_url || "(none)"}")
      IO.puts(
        "  discovery:      #{structure.discovery_base_url}#{structure.models_path}#{
          ProbePrinter.annotate(structure.discovery_resolved?)
        }"
      )

      models = ChatModel.list_models(provider)
      IO.puts("  models (#{length(models)}):")
      Enum.each(models, fn model -> IO.puts("    - #{model}") end)

    {:error, reason} ->
      IO.puts("  probe failed:   #{inspect(reason)}")
  end
end)
