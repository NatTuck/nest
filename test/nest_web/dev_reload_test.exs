defmodule NestWeb.DevReloadTest do
  @moduledoc """
  Two guards on how development reloading is wired, both learned from a dev
  server that answered `GET /login` with `UndefinedFunctionError` on
  `Plug.Exception.status/1` — the *error renderer* failing, not the request.

  ## Why `Mix.Task` is banned from runtime code

  `Mix.Task.run/2` runs a task **once per VM**: a second call for the same task
  returns `:noop` unless the task was reenabled. A reloader that drives
  `Mix.Task.run("compile.elixir", …)` from inside the app is therefore
  silently dead after boot — and the one call it does make runs a compiler
  outside `Phoenix.CodeReloader.Server`, the GenServer whose entire job is to
  serialize reloads so that two of them cannot interleave.

  That interleaving is what took the dev server down. Mix's compiler deletes
  and purges the whole protocol-consolidation directory when it recompiles
  (`Mix.Compilers.Elixir --purge-consolidation-path-if-stale`), so with a
  second compiler in the VM a request could arrive in the window where the
  purged `Plug.Exception` beams had not been reconsolidated yet. Phoenix's own
  reloader does that purge and the reconsolidation inside one serialized
  `GenServer` call, so no request can observe the gap; a compiler nobody
  serialized has no such window to close.

  So no `lib/` file may *reference* `Mix.Task`, not merely call it:
  `alias Mix.Task` and `import Mix.Task` reach the same function, and a
  call-site matcher would see neither. `lib/mix/tasks/` is exempt, named
  explicitly rather than allowlisting files: those modules *are* Mix CLI entry
  points (`mix nest.repair_messages`), they run inside a `mix` invocation and
  not inside the app's BEAM, and `Mix.Task.run("app.start")` there is the
  intended use.

  ## Why the endpoint installs exactly one reloader

  Stock Phoenix splits the job: `Phoenix.LiveReloader` broadcasts the change to
  the browser and `Phoenix.CodeReloader` compiles it, through the serializing
  server above. A second reloader in the plug pipeline is a second compiler,
  which is the bug. This is asserted on the endpoint's *source* — read and
  matched line by line — rather than on the compiled endpoint, so that the
  assertion is the same one a reviewer makes by hand and does not depend on
  which environment compiled the endpoint.
  """
  use ExUnit.Case, async: true

  alias Nest.Test.SourceScan

  @root Path.expand("../..", __DIR__)
  @lib_glob "lib/**/*.ex"
  # Mix CLI entry points, not runtime code — see the moduledoc.
  @mix_task_dir "lib/mix/tasks/"
  @endpoint "lib/nest_web/endpoint.ex"

  describe "no runtime code drives Mix" do
    test "no file under lib/ outside lib/mix/tasks/ references Mix.Task" do
      files =
        @root
        |> Path.join(@lib_glob)
        |> Path.wildcard()
        |> Enum.reject(&String.starts_with?(Path.relative_to(&1, @root), @mix_task_dir))

      # A broken glob must not pass vacuously: `assert offenders == []` over an
      # empty list is green.
      assert length(files) > 100

      offenders =
        SourceScan.flat_map(files, fn file ->
          file
          |> File.read!()
          |> Code.string_to_quoted!(file: file)
          |> mix_task_lines()
          |> Enum.map(&{Path.relative_to(file, @root), &1})
        end)

      assert offenders == [],
             "lib/ runtime code references Mix.Task, which runs a task once per VM and " <>
               "compiles outside Phoenix.CodeReloader.Server (see the moduledoc): " <>
               inspect(offenders)
    end
  end

  describe "the endpoint" do
    test "installs stock Phoenix reloading, and exactly one reloader" do
      lines =
        @root
        |> Path.join(@endpoint)
        |> File.read!()
        |> String.split("\n")
        |> Enum.map(&String.trim/1)

      # One compiler, and it is Phoenix's.
      assert Enum.count(lines, &String.contains?(&1, "plug Phoenix.CodeReloader")) == 1

      # No reloader plug of ours: a second one is a second compiler.
      refute Enum.any?(lines, &String.contains?(&1, "ReloaderPlug"))

      # Stock order: the LiveReloader that broadcasts a change is installed
      # before the compiler that acts on it, and the repo-status check — which
      # can raise — comes after both.
      live = Enum.find_index(lines, &(&1 == "plug Phoenix.LiveReloader"))
      compile = Enum.find_index(lines, &(&1 == "plug Phoenix.CodeReloader"))
      repo = Enum.find_index(lines, &String.starts_with?(&1, "plug Phoenix.Ecto.CheckRepoStatus"))

      assert Enum.all?([live, compile, repo], &is_integer/1)
      assert live < compile and compile < repo
    end
  end

  # Any reference, not just a call — see the moduledoc. `Macro.prewalk/3` sees
  # comments and strings as nothing at all, so prose about `Mix.Task.run` is
  # not an offender; only code is.
  defp mix_task_lines(ast) do
    {_, lines} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, meta, [:Mix, :Task]} = node, acc -> {node, [meta[:line] | acc]}
        node, acc -> {node, acc}
      end)

    lines |> Enum.reverse() |> Enum.uniq()
  end
end
