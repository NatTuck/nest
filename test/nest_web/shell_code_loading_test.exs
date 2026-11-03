defmodule NestWeb.ShellCodeLoadingTest do
  @moduledoc """
  Rendering the shell must not load code.

  `interactive` code loading sends every module's *first* call through the one
  global code server, so a module that is still cold when a test renders the
  shell is charged to that test's 3000 ms deadline. Under `max_cases`
  concurrent tests, the queue on that single process is what turns it into
  `ExUnit.TimeoutError` with `:code_server.call/1` as the innermost frame, which
  is how `page_controller_test.exs` has failed. `test_helper.exs` pays the first
  render — and the first read and insert — before any deadline; this is the
  invariant behind that warm-up: once warm, a render makes no code-server call
  from the request process at all. The trace sees the calling process only,
  which is where every one of these loads is made; a load made by some other
  process would not show up here, so that is the claim this file can make.

  The trace is the assertion rather than a module list on purpose. A list keeps
  passing while the request path grows another lazy load, which is exactly the
  failure being pinned here; a trace fails on the load itself. The
  `PageController.home/2` control is what makes an empty list mean "nothing
  loaded" rather than "the tracer saw nothing".
  """

  use NestWeb.ConnCase, async: true

  @render {NestWeb.PageController, :home, 2}
  @load {:code_server, :call, 1}
  @watched [@render, @load]

  test "rendering the shell makes no code-server call", %{conn: conn} do
    # Resolved outside the traced function: `~p` goes through
    # `Phoenix.VerifiedRoutes`, which is not part of the render.
    path = ~p"/register"

    {conn, calls} = traced(fn -> get(conn, path) end)

    # The request really reached the controller, so an empty load list below is
    # not a request that never rendered.
    assert html_response(conn, 200)

    assert Enum.any?(calls, &match?({@render, _args, _caller}, &1)),
           "the tracer did not see #{inspect(@render)}, so the load list below proves nothing"

    case Enum.filter(calls, &match?({@load, _args, _caller}, &1)) do
      [] ->
        :ok

      loads ->
        flunk("""
        rendering the shell made #{length(loads)} code-server call(s). The \
        module(s) below were loaded inside this test's deadline instead of by \
        the warm-up in test_helper.exs.

        #{Enum.map_join(loads, "\n", &describe/1)}
        """)
    end
  end

  # Collects `{mfa, args, call_site}` for every watched call `fun` makes, then
  # stops. The tracer is a separate process because a process that traces
  # itself receives nothing.
  defp traced(fun) do
    traced_pid = self()
    tracer = spawn_link(fn -> collect([], traced_pid) end)

    for mfa <- @watched do
      :erlang.trace_pattern(mfa, [{:_, [], []}], [:local])
    end

    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    result =
      try do
        fun.()
      after
        :erlang.trace(self(), false, [:call])

        for mfa <- @watched do
          :erlang.trace_pattern(mfa, false, [:local])
        end

        send(tracer, {:stop, self()})
      end

    {result, await_calls()}
  end

  # Selective, with no catch-all clause, so nothing is drained out of the
  # mailbox: a `:call` trace message has exactly this shape when the
  # `return_trace` flag is off.
  defp collect(acc, traced_pid) do
    receive do
      {:trace, _pid, :call, {m, f, args}} ->
        collect([{{m, f, length(args)}, args, call_site(traced_pid)} | acc], traced_pid)

      {:stop, from} ->
        send(from, {:calls, Enum.reverse(acc)})
    end
  end

  defp await_calls do
    receive do
      {:calls, calls} -> calls
    after
      # A fence, not a wait: the tracer answers as soon as it reaches the
      # `{:stop, …}` that `traced/1` sent after switching tracing off, and that
      # message is ordered behind every trace message this process sent it.
      500 -> flunk("the code-load tracer did not answer")
    end
  end

  # The call site, read while the traced process is (usually) still blocked in
  # the call. Best effort by nature, and only ever read on the failure path.
  defp call_site(traced_pid) do
    case :erlang.process_info(traced_pid, :current_stacktrace) do
      {:current_stacktrace, [_innermost | rest]} ->
        rest
        |> Enum.reject(fn {m, _f, _a, _loc} -> m in [:gen_server, :gen, :proc_lib] end)
        |> Enum.take(3)
        |> Enum.map_join(" <- ", fn {m, f, a, loc} ->
          "#{inspect(m)}.#{f}/#{a}#{location(loc)}"
        end)

      _ ->
        "unknown"
    end
  end

  defp location([{file, line} | _]), do: " (#{Path.basename(to_string(file))}:#{line})"
  defp location(_), do: ""

  defp describe({@load, [request], call_site}), do: "  #{module_name(request)} — #{call_site}"

  defp describe({mfa, _args, call_site}), do: "  #{inspect(mfa)} — #{call_site}"

  # Both loading requests `:code_server.call/1` takes name the module.
  defp module_name({:get_object_code_for_loading, module}), do: inspect(module)
  defp module_name({:load_ok, _ref, module, _path, _ref2}), do: inspect(module)
  defp module_name(other), do: inspect(other, limit: :infinity)
end
