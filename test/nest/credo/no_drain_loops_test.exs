defmodule Nest.Credo.Check.NoDrainLoopsTest do
  use ExUnit.Case, async: true

  # The check lives in `test/support/credo/`, which is excluded from the normal
  # test compilation (Credo loads it via `requires`). Load it here so we can
  # exercise its pure `drain_loops/1`.
  Code.require_file("../../support/credo/no_drain_loops.ex", __DIR__)

  alias Nest.Credo.Check.NoDrainLoops

  defp lines(source), do: source |> Code.string_to_quoted!() |> NoDrainLoops.drain_loops()

  describe "fires on a catch-all whose body leads back into a receive" do
    test "a self-recursive call to the enclosing function" do
      source = """
      defmodule A do
        defp loop(n) do
          receive do
            :stop -> :ok
            _other -> loop(n)
          end
        end
      end
      """

      assert lines(source) == [3]
    end

    test "a nested receive" do
      source = """
      defmodule A do
        defp loop do
          receive do
            :stop -> :ok
            _other ->
              receive do
                :stop -> :ok
              end
          end
        end
      end
      """

      assert lines(source) == [3]
    end

    test "the real shape from WaitForIdle before 72eaa3f" do
      source = """
      defmodule A do
        defp loop(monitors) do
          receive do
            {:DOWN, _ref, :process, _pid, _reason} -> check(monitors)
            _other -> loop(monitors)
          end
        end
      end
      """

      assert lines(source) == [3]
    end
  end

  describe "does not fire on legitimate receives" do
    test "the `after 0` non-blocking idiom (a catch-all that does not re-receive)" do
      source = """
      defmodule A do
        defp poll do
          receive do
            msg -> handle(msg)
          after
            0 -> :none
          end
        end
      end
      """

      assert lines(source) == []
    end

    test "a single-clause receive with an explicit pattern" do
      source = """
      defmodule A do
        defp await do
          receive do
            {:stop_chat, from} -> from
          after
            0 -> :none
          end
        end
      end
      """

      assert lines(source) == []
    end

    test "a selective receive with several explicit clauses" do
      source = """
      defmodule A do
        defp await do
          receive do
            {:chat_status, _payload} -> :ok
            {:DOWN, _ref, :process, _pid, _reason} -> :ok
          after
            500 -> :timeout
          end
        end
      end
      """

      assert lines(source) == []
    end

    test "a catch-all that calls a *different* function" do
      source = """
      defmodule A do
        defp loop(n) do
          receive do
            :stop -> :ok
            _other -> handle(n)
          end
        end

        defp handle(_n), do: :ok
      end
      """

      assert lines(source) == []
    end
  end

  describe "project-wide" do
    # The Credo check sees only what `.credo.exs` includes (`lib/`, `test/`, …).
    # This walks *every* Elixir file in the repo — `scripts/`, `config/`,
    # `priv/`, `mix.exs` included — so the rule holds project-wide, not only
    # where Credo happens to look. A file that does not parse raises here
    # rather than being skipped.
    test "no Elixir file in the project contains a drain loop" do
      root = Path.expand("../../..", __DIR__)

      offenders =
        root
        |> Path.join("**/*.{ex,exs}")
        |> Path.wildcard()
        |> Enum.reject(&String.contains?(&1, ["/deps/", "/_build/", "/node_modules/", "/.git/"]))
        |> Enum.flat_map(fn file ->
          lines = file |> File.read!() |> Code.string_to_quoted!() |> NoDrainLoops.drain_loops()
          Enum.map(lines, &{Path.relative_to(file, root), &1})
        end)

      assert offenders == [],
             "drain loops found (a receive catch-all that re-receives): #{inspect(offenders)}"
    end
  end
end
