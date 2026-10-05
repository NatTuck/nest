defmodule MachineStructureTest do
  @moduledoc false
  # Structural "no reintroduction" tests for the Agent machine. These assert
  # properties of the source that unit/integration tests cannot catch.

  use ExUnit.Case, async: true

  @machine_sources Path.wildcard("lib/nest/agents/agent/machine.ex") ++
                     Path.wildcard("lib/nest/agents/agent/machine/*.ex")

  describe "intent-comment placement" do
    test "intent notes are inline # comments, never in @doc/@moduledoc" do
      # INTENT-RULE: intentional behavior is recorded as an inline # comment
      # adjacent to the code it governs. A @doc/@moduledoc attribute lives in
      # a different region than the function body, so a line-range read of the
      # body can miss it; an inline comment cannot be separated from its code.
      # This test fails if a machine module puts intent notes in
      # @doc/@moduledoc. Put the note inline next to the behavior instead.
      forbidden = ~r/\b(intentional|do not|must not|don't|shouldn't)\b/i

      for path <- @machine_sources do
        for {doc, _} <- doc_blocks(File.read!(path)) do
          refute Regex.match?(forbidden, doc),
                 "#{path}: intent must be an inline # comment, not @doc/@moduledoc:\n#{doc}"
        end
      end
    end
  end

  # Extract the string bodies of @doc / @moduledoc attributes only (never
  # inline comments). Only triple-quoted attributes carry bodies; bare
  # `@moduledoc false` has none.
  defp doc_blocks(source) do
    Regex.scan(~r/@(?:moduledoc|doc)\s+"""(.*?)"""/s, source)
    |> Enum.map(fn [_, body] -> {body, :doc} end)
  end
end
