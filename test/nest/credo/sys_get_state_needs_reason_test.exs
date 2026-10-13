defmodule Nest.Credo.Check.SysGetStateNeedsReasonTest do
  use ExUnit.Case, async: true

  # The check lives in `test/support/credo/`, which is excluded from the normal
  # test compilation (Credo loads it via `requires`). Load it here so we can
  # exercise its pure `findings/2`.
  Code.require_file("../../support/credo/sys_get_state_needs_reason.ex", __DIR__)

  alias Nest.Credo.Check.SysGetStateNeedsReason

  defp findings(source), do: SysGetStateNeedsReason.findings(source)

  describe "fires on a `:sys.get_state` call with no reason" do
    test "a read" do
      source = """
      defmodule A do
        def f(pid) do
          state = :sys.get_state(pid, 1_000)
          state.live.mode
        end
      end
      """

      assert findings(source) == [{:unmarked, 3}]
    end

    test "a discarded read (the barrier shape)" do
      source = """
      defmodule A do
        def f(pid) do
          _ = :sys.get_state(pid, 1_000)
        end
      end
      """

      assert findings(source) == [{:unmarked, 3}]
    end

    test "an empty reason is not a reason" do
      source = """
      defmodule A do
        def f(pid), do: :sys.get_state(pid, 1_000) # allowlist:
      end
      """

      assert findings(source) == [{:unmarked, 2}]
    end

    test "a mention is not a call" do
      source = """
      defmodule A do
        @moduledoc "They use :sys.get_state/1 to inspect the state directly"

        # :sys.get_state/1, and a `:sys.get_state(` in prose, are not calls.
        def f, do: &(:sys.get_state/1)
      end
      """

      assert findings(source) == []
    end
  end

  describe "does not fire on an allowlisted call" do
    test "a marker on the call's line" do
      source = """
      defmodule A do
        def f(pid) do
          state = :sys.get_state(pid, 1_000) # allowlist: snapshot — messages + status
          state.live.mode
        end
      end
      """

      assert findings(source) == []
    end

    test "a marker on the line above" do
      source = """
      defmodule A do
        def f(pid) do
          # allowlist: harness — Turn.build_ctx/1's argument
          state = :sys.get_state(pid, 1_000)
          state.live.mode
        end
      end
      """

      assert findings(source) == []
    end

    test "one marker excuses its statement; the next statement needs its own" do
      source = """
      defmodule A do
        def f(pid) do
          # allowlist: snapshot — messages + status
          a = :sys.get_state(pid, 1_000)
          b = :sys.get_state(pid, 1_000)
          {a, b}
        end
      end
      """

      assert findings(source) == [{:unmarked, 5}]
    end

    test "one marker excuses every call in its statement" do
      source = """
      defmodule A do
        def f(pid, other) do
          # allowlist: snapshot — messages + status
          {:sys.get_state(pid, 1_000), :sys.get_state(other, 1_000)}
        end
      end
      """

      assert findings(source) == []
    end

    test "a marker above a multi-line statement reaches the call inside it" do
      source = """
      defmodule A do
        def f(pid) do
          # allowlist: harness — Turn.build_ctx/1's argument
          ctx =
            Turn.build_ctx(:sys.get_state(pid, 1_000))
            |> Map.put(:agent_pid, pid)

          ctx
        end
      end
      """

      assert findings(source) == []
    end
  end

  describe "fires on a marker that excuses nothing" do
    test "a marker with no call at all" do
      source = """
      defmodule A do
        # allowlist: harness — the call this was written for is gone
        def f(pid), do: pid
      end
      """

      assert findings(source) == [{:stale_marker, 2}]
    end

    test "a marker above another statement does not reach the call below it" do
      source = """
      defmodule A do
        def f(pid) do
          # allowlist: snapshot — messages + status
          other = 1
          :sys.get_state(pid, 1_000)
          other
        end
      end
      """

      assert findings(source) == [{:stale_marker, 3}, {:unmarked, 5}]
    end

    test "a `# allowlist:` inside a string is not a marker" do
      source = """
      defmodule A do
        def f, do: "see # allowlist: this is a string, not a marker"
      end
      """

      assert findings(source) == []
    end
  end

  describe "fires on a read inside a polling predicate" do
    test "a local `eventually/2` whose predicate reads state" do
      source = """
      defmodule A do
        def f(pid) do
          eventually(fn -> :sys.get_state(pid, 1_000).live.mode == "plan" end, timeout: 500)
        end
      end
      """

      assert findings(source) == [{:poll_predicate, 3}]
    end

    test "`Eventually.eventually/2`, and a marker cannot excuse it" do
      source = """
      defmodule A do
        def f(pid) do
          Eventually.eventually(fn -> :sys.get_state(pid) end, timeout: 500) # allowlist: snapshot
        end
      end
      """

      assert findings(source) == [{:stale_marker, 3}, {:poll_predicate, 3}]
    end

    test "a predicate that cannot block is fine" do
      source = """
      defmodule A do
        def f(id) do
          assert eventually(fn -> Agents.get_agent(id) == {:error, :not_found} end, timeout: 500)
        end
      end
      """

      assert findings(source) == []
    end

    test "a read after the poll is not inside the predicate" do
      source = """
      defmodule A do
        def f(pid) do
          assert eventually(fn -> ready?(pid) end, timeout: 500)
          state = :sys.get_state(pid, 1_000) # allowlist: snapshot — messages + status
          state.live.mode
        end
      end
      """

      assert findings(source) == []
    end
  end

  describe "scope" do
    test "`test/` is in scope, `test/support/` included" do
      assert SysGetStateNeedsReason.in_scope?("test/nest/agents/agent_test.exs")
      assert SysGetStateNeedsReason.in_scope?("test/support/agent_turn_test_helpers.ex")
    end

    test "`lib/` is not, and the check never reads its source" do
      refute SysGetStateNeedsReason.in_scope?("lib/nest/agents/agent.ex")
      refute SysGetStateNeedsReason.in_scope?("config/config.exs")

      # No source is registered in Credo's ETS for this file: if the check read
      # it, this would raise instead of returning `[]`.
      assert SysGetStateNeedsReason.run(
               %Credo.SourceFile{filename: "lib/nest/agents/agent.ex"},
               []
             ) == []
    end
  end

  describe "fail-loud" do
    test "raises on source it cannot parse" do
      assert_raise RuntimeError, ~r/could not parse test\/broken_test\.exs/, fn ->
        SysGetStateNeedsReason.findings("defmodule A do\n", "test/broken_test.exs")
      end
    end
  end

  describe "project-wide" do
    test "every `:sys.get_state` under test/ carries a reason, and no marker is stale" do
      root = Path.expand("../../..", __DIR__)

      files = Path.wildcard(Path.join(root, "test/**/*.{ex,exs}"))

      # A broken glob must not pass vacuously: `assert offenders == []` over an
      # empty list is green.
      assert length(files) > 100

      offenders =
        Enum.flat_map(files, fn file ->
          path = Path.relative_to(file, root)

          file
          |> File.read!()
          |> SysGetStateNeedsReason.findings(path)
          |> Enum.map(fn {kind, line} -> {path, kind, line} end)
        end)

      assert offenders == [], "unexplained :sys.get_state sites: #{inspect(offenders)}"
    end
  end
end
