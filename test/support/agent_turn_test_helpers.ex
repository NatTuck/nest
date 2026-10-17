defmodule Nest.Agents.AgentTurnTestHelpers do
  @moduledoc """
  Helpers for turn-level integration tests that drive a real agent and
  inspect its `chat:status` stream and the LLM requests its turn made
  (`Nest.Agents.Agent.TurnAcceptanceTest`'s split files,
  `Nest.Agents.Agent.CloneAgentFlowTest`, `TimelineEmittersTest`,
  `ReplyDebtTest`).

  `statuses_until_idle/2` is an *ordered* collector, not a drain: it stops
  at the first `idle` (for the agent it is named), so a test can assert the
  whole sequence and an `idle` anywhere before the end fails. `assert_request/0`
  reads the request lists the caller's `MockClient` spy sent.

  `park_llm_requests/1` + `next_request/0` + `release_llm/1` are the
  *parked* variant of the same observation: each request is held until the
  test releases it, so a test that has to read the agent's state (or the
  transcript) at a specific point of a turn is not racing the HTTP worker
  for the agent's mailbox.

  `await_delivery/1` is the fence for a *delivery* rather than for a turn: it
  consumes this test pid's frames up to the `{:chat_message, {:user, …}}` frame
  that carries a given text, so a test can then fence on the `idle` frame that
  ends the turn that delivery started — even when an earlier turn's `idle` is
  still queued.

  The frame waits (`statuses_until_idle/2` and `await_delivery/1`, both 1000 ms —
  the suite's fence bound, since both wait on an `idle` frame) bound a frame the
  turn is already producing; `assert_request/0` and `next_request/0` are 500 ms
  and 1000 ms. A turn here is two mock HTTP calls plus one in-memory tool batch.
  """

  import ExUnit.Assertions

  alias Nest.Agents.AgentTestAssertions
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part

  # Collect the `chat:status` sequence *for one agent* up to (and including)
  # the first `idle`, bounded at 1000 ms — the suite's fence bound, because this
  # wait's own frame is an `idle` frame. `start_agent/1` subscribes the test pid
  # to the agent's topic, and a test may also be subscribed to a peer's or a
  # specialist's, so the sequence is filtered by the payload's own `name`:
  # without it, a second agent's frames would interleave with this agent's and
  # the asserted sequence would be a fiction.
  @spec statuses_until_idle(String.t(), [String.t()]) :: [String.t()]
  def statuses_until_idle(name, acc \\ []) do
    receive do
      {:chat_status, %{name: ^name, status: "idle"}} ->
        Enum.reverse(["idle" | acc])

      {:chat_status, %{name: ^name, status: status}} ->
        statuses_until_idle(name, [status | acc])
    after
      1_000 ->
        flunk(
          "no idle status for #{name} within 1000ms; statuses so far: #{inspect(Enum.reverse(acc))}"
        )
    end
  end

  @doc "The next recorded LLM request's message list."
  @spec assert_request() :: [term()]
  def assert_request do
    receive do
      {:llm_request, messages} -> messages
    after
      500 -> flunk("expected another LLM request")
    end
  end

  @doc "The text of every `{:user, _}` message in a message list."
  @spec user_texts([term()]) :: [String.t()]
  def user_texts(messages) do
    for {:user, %{parts: parts}} <- messages, do: AgentTestAssertions.text_from_parts(parts)
  end

  @doc """
  Park every LLM request until the test releases it.

  A turn is otherwise a race between the tool worker and the HTTP worker for
  the agent's mailbox, so the transcript and the status sequence at each step
  are not reproducible. `next_request/0` reads each parked request (the agent
  is blocked in it until `release_llm/1`), so the test decides exactly when the
  turn advances. `pid` is the agent whose `MockClient` queue is stubbed.
  """
  @spec park_llm_requests(pid()) :: :ok
  def park_llm_requests(pid) do
    test_pid = self()

    Mimic.stub(MockClient, :run, fn request, opts ->
      send(test_pid, {:llm_request, request.messages, self()})

      # This closure runs in the agent's HTTP worker, so `self()` here is that
      # worker; `test_pid` is the process that called `park_llm_requests/1`
      # (the test). We monitor the *test*, because the test going away is the
      # only reason to give up the park.
      #
      # No `after` clause: release is the test's `release_llm/1` or the test
      # process's own `:DOWN`, both events. See `park/3` for why the timer this
      # replaced was a hazard rather than a safety net.
      ref = Process.monitor(test_pid)

      receive do
        :release_llm -> :ok
        {:DOWN, ^ref, :process, ^test_pid, _reason} -> :ok
      end

      Process.demonitor(ref, [:flush])

      Mimic.call_original(MockClient, :run, [request, opts])
    end)

    Mimic.allow(MockClient, self(), pid)
  end

  @doc """
  Park the **next** LLM request only, then let every later request run.

  `park_llm_requests/1`'s one-shot sibling, for a test that has to read the
  agent's state at one point of a turn but must not control how many turns the
  rest of the test starts — that count is a scheduling outcome, and a test that
  had to release every request would be asserting it.

  The first request after installation parks and reports
  `{:llm_request, messages, worker}` exactly as `park_llm_requests/1` does, so
  `next_request/0` and `release_llm/1` work unchanged; every request after it
  goes straight through to the original. The claim is taken with `:counters`
  because the stub runs in whichever process makes the call, and successive
  requests need not be the same one.

  **Mutually exclusive with `park_llm_requests/1`.** Both replace
  `MockClient.run/2` with `Mimic.stub/3`, so installing the second silently
  replaces the first and drops its park with no error — use one or the other,
  never both.
  """
  @spec park_next_llm_request(pid()) :: :ok
  def park_next_llm_request(pid) do
    test_pid = self()
    taken = :counters.new(1, [])

    Mimic.stub(MockClient, :run, fn request, opts ->
      :counters.add(taken, 1, 1)

      if :counters.get(taken, 1) == 1 do
        send(test_pid, {:llm_request, request.messages, self()})

        # As in `park_llm_requests/1`: the only reason to give up the park is
        # the test going away, which is an event, not a clock.
        ref = Process.monitor(test_pid)

        receive do
          :release_llm -> :ok
          {:DOWN, ^ref, :process, ^test_pid, _reason} -> :ok
        end

        Process.demonitor(ref, [:flush])
      end

      Mimic.call_original(MockClient, :run, [request, opts])
    end)

    Mimic.allow(MockClient, self(), pid)
  end

  @doc """
  The next parked request, as `{messages, worker}`. Nothing runs until the
  caller releases `worker`, so it can assert on the state the request was made
  from.
  """
  @spec next_request() :: {[term()], pid()}
  def next_request do
    assert_receive {:llm_request, messages, worker}, 1_000
    {messages, worker}
  end

  @doc "Release the parked request `worker`."
  @spec release_llm(pid()) :: :ok
  def release_llm(worker), do: send(worker, :release_llm)

  # The parks each installed harness has armed, keyed by the `kind` the send
  # carries (`:agent` for `agents-send`, `:query` for `agents-query`).
  #
  # The two harnesses install one stub over the one function both tools reach —
  # `Nest.Agents.send_message/6` (the mode rides the message, so there is no
  # longer a four-arity and a five-arity clause to keep them apart) — and each
  # arms the park for its own `kind`. A test that parks both an `agents-send`
  # and an `agents-query` therefore gets both parks, instead of the second
  # install silently replacing the first. The map is read and re-written in the
  # test process at install time and captured by the closure, so the stub a
  # worker calls already holds the merged set.
  @park_config_key :nest_agent_send_park_config

  @doc """
  Park the tool worker inside `Nest.Agents.send_message/6` — the `agents-send`
  entry point — so the test decides when the batch's call reaches its target.

  The worker always parks *before* the real delivery: it sends
  `{:send_blocked, worker}` and waits for `:release_send`. With
  `hold_result: true` it parks a second time *after* it, sending
  `{:send_delivered, worker}` and waiting for `:release_result` — so the batch is
  still in flight while the delivered message's turn runs, which is the shape
  where the batch's own result arrives only once that turn has ended. Each park
  ends on the test's release or on the test process's own `:DOWN`, so a failing
  test cannot leave the worker parked (see `park/3`).
  """
  @spec park_agent_sends(pid(), keyword()) :: :ok
  def park_agent_sends(pid, opts \\ []) do
    install_park(
      pid,
      :agent,
      %{blocked: :send_blocked, release: :release_send, delivered: :send_delivered},
      opts
    )
  end

  @doc """
  Park the tool worker inside `Nest.Agents.send_message/6` — the `agents-query`
  entry point — so the test decides when the batch's query reaches its target
  and when the batch returns.

  `park_agent_sends/2`'s sibling for the querying tool, kept apart by the `kind`
  the call carries: only `kind: :query` calls park here, so a runtime notice or a
  peer's own send is never held. The worker parks *before* the real delivery
  (sending `{:query_blocked, worker}` and waiting for `:release_query`); with
  `hold_result: true` it parks a second time *after* it
  (`{:query_delivered, worker}`, released by `:release_result`), which is the
  shape where the peer's answer can land while the caller's batch is still in
  flight — the batch is backgrounded, not the answer queued behind it.

  Both harnesses install one stub, so a test may arm both; see
  `@park_config_key`. Both parks end on the test's release or on the test
  process's own `:DOWN` — see `park/3`; there is no timer on either path.
  """
  @spec park_agent_queries(pid(), keyword()) :: :ok
  def park_agent_queries(pid, opts \\ []) do
    install_park(
      pid,
      :query,
      %{blocked: :query_blocked, release: :release_query, delivered: :query_delivered},
      opts
    )
  end

  # Arm one kind's park and (re)install the stub both kinds share, merged with
  # whatever an earlier harness already armed. `frames` is the kind's three
  # frame names (`:blocked`, `:release`, `:delivered`).
  defp install_park(pid, kind, frames, opts) do
    test_pid = self()

    config =
      Process.get(@park_config_key, %{})
      |> Map.put(kind, Map.put(frames, :hold, Keyword.get(opts, :hold_result, false)))

    Process.put(@park_config_key, config)

    Mimic.stub(Nest.Agents, :send_message, fn space_id, from, target, content, call_kind, mode ->
      deliver_parked(test_pid, config, call_kind, [
        space_id,
        from,
        target,
        content,
        call_kind,
        mode
      ])
    end)

    Mimic.allow(Nest.Agents, self(), pid)
  end

  # Deliver one send, parking around it when this test armed a park for the
  # call's kind. `args` is the call's own argument list, replayed through
  # `Mimic.call_original/3`.
  defp deliver_parked(test_pid, config, call_kind, args) do
    case Map.get(config, call_kind) do
      nil -> Mimic.call_original(Nest.Agents, :send_message, args)
      park -> park_around(test_pid, park, args)
    end
  end

  # Park before the real delivery, and — when the harness asked to hold the
  # result — again after it, so the batch is still in flight while the delivered
  # message's turn runs.
  defp park_around(test_pid, park, args) do
    park(test_pid, park.blocked, park.release)
    result = Mimic.call_original(Nest.Agents, :send_message, args)

    if park.hold do
      park(test_pid, park.delivered, :release_result)
    end

    result
  end

  # Both exits are events, and there is deliberately **no timer**. The `after`
  # clause this used to carry was a valve whose only job was "the owner went
  # away"; the owner going away is directly observable, so a timer there was
  # never a safety net — it was a race. It could fire while the owner was still
  # running and let the worker proceed, silently flipping the outcome a decisive
  # park pins instead of letting the test's own fence report the failure. A
  # monitor cannot do that: `:DOWN` arrives only once the owner is gone.
  #
  # HISTORY (kept because the reason it was fragile still explains the shape of
  # a parked test, but it is no longer a live constraint on any number): the
  # valve was 3 s and had to stay *strictly longer* than a whole-turn fence
  # (`Nest.Agents.SubAgentToolsHelpers.await_idle/1`, 2 s at the time), so that a
  # slow host failed the fence rather than silently flipping a pinned outcome.
  # `#21` caps every test-side timeout at 2 s, which made "valve > fence"
  # impossible to satisfy. Removing the timer removes the constraint instead of
  # trading one number against another.
  #
  # What still matters when editing a parked test: a *decisive* park — one whose
  # release decides which outcome the test observes — must be released by the
  # test itself. An extra wait (an `eventually`, another `assert_receive`)
  # between a decisive park and its release is fine; a park whose release the
  # test never reaches is now a loud ExUnit timeout rather than a quiet flip.
  @doc """
  Park the calling process until `test_pid` sends `release`, or until it dies.

  The `park_agent_*` harnesses' primitive, and usable on its own by a stub that
  needs the test to decide when a worker may proceed: `blocked` is the frame the
  test fences on. There is deliberately no timer — see the comment above.
  """
  @spec park(pid(), atom(), atom()) :: :ok
  def park(test_pid, blocked, release) do
    send(test_pid, {blocked, self()})

    ref = Process.monitor(test_pid)

    receive do
      ^release -> :ok
      {:DOWN, ^ref, :process, ^test_pid, _reason} -> :ok
    end

    Process.demonitor(ref, [:flush])
  end

  @doc """
  Consume this test pid's frames up to the `{:chat_message, {:user, …}}` frame
  whose text carries `needle`, and return that text.

  The frames broadcast *before* a delivery — the turn that caused it, and the
  `{:broadcast, :status, nil}` every child event emits while the agent is idle —
  are already in this mailbox, and `assert_receive/2` scans it from the front. So
  a test that fences on the `idle` frame that ends the delivery's turn has to get
  past them first, or it matches the earlier `idle` and reads the transcript a
  turn too soon.

  Consumed on the way: earlier `{:user, …}` frames (the test's own chat, or an
  earlier delivery) and **every `idle` `chat:status` frame, whichever agent
  broadcast it** — a frame carries its own agent's name, but the collector has no
  name to filter on, so it is for a test that waits on one agent's deliveries.
  Every other frame is left where it is.
  """
  @spec await_delivery(String.t()) :: String.t()
  def await_delivery(needle) do
    receive do
      {:chat_message, {:user, %{parts: parts}}} ->
        case for %Part.Text{text: text} <- parts || [], is_binary(text), text =~ needle, do: text do
          [] -> await_delivery(needle)
          [text | _] -> text
        end

      {:chat_status, %{status: "idle"}} ->
        await_delivery(needle)
    after
      1_000 -> flunk("no delivered message containing #{inspect(needle)} within 1000ms")
    end
  end

  @doc "The text of a message's parts (\"\" for a message without parts)."
  @spec text_of(term()) :: String.t()
  def text_of({_tag, %{parts: parts}}), do: AgentTestAssertions.text_from_parts(parts)
  def text_of(_message), do: ""

  @doc "The `content` of every tool result in a `{:tool, _}` message."
  @spec tool_texts(term()) :: [String.t()]
  def tool_texts({:tool, %{parts: parts}}) do
    for %Part.ToolResult{content: content} <- parts || [], do: content || ""
  end

  def tool_texts(_message), do: []
end
