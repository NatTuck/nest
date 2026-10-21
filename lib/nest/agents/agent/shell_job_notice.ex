defmodule Nest.Agents.Agent.ShellJobNotice do
  @moduledoc """
  The notice an agent gets when one of its background shell jobs exits
  (issue #163).

  A `shell-cmd` call with `background: true` hands its command to
  `Nest.Sandbox.ShellJobs`, which outlives the tool call. The only thing that
  told the agent the job had ended was `shell-wait`: its watcher registers as a
  waiter on the job (`Nest.Agents.Agent.Watch.await/2`), and the manager sends
  that waiter `{:shell_job_exit, id, code}`. So an agent that started a job and
  did anything else was never told — the exit went to the waiters and to the
  UI's `shell:jobs` broadcast, and to nobody else.

  `Nest.Sandbox.ShellJobs.finish_job/3` now delivers this notice to the owning
  agent instead (`Nest.Sandbox.ShellJobs.ExitNotice`), as a `:runtime` inbox
  entry (`Inbox.enqueue_notice/2`), and an idle agent drains it so it takes a
  turn on the result.

  ## The wording is `shell-wait`'s

  `ShellJobs.result_text/3` is what `shell-wait` answers with, and this notice
  says the same thing: a job's exit is one fact, and an agent that learns it
  from a notice rather than from a wait must not read a different sentence.
  `parts/3` therefore takes its prose from that function rather than restating
  it, and `notice/3` is exactly `parts/3`'s texts joined — the same invariant
  `Nest.Agents.Agent.Turn.Backgrounded` states, so every string consumer of the
  notice (the entry's `content`, the drain's rendering, the model's prompt)
  sees the bytes `shell-wait` would have shown.

  ## Segments

  The job's log is *output*, so it is an `{:output, …}` segment and the client
  renders it verbatim instead of as markdown (issue #139): a log full of `#`,
  `*`, `_` and indented lines is mangled by markdown. The prose around it stays
  prose. See `Nest.Messages.Segment`.
  """

  alias Nest.Messages.Segment
  alias Nest.Sandbox.ShellJobs

  @doc """
  Render a job's exit as ordered segments: the prose, then the log.

  The prose is `ShellJobs.result_text/3` with the log taken off its tail, so
  the sentence has one source and the log rides its own `:output` segment. A
  job with no output is a single `:text` segment, because there is nothing to
  render as output.
  """
  @spec parts(String.t(), integer(), binary()) :: [Segment.t()]
  def parts(job_id, code, output) do
    text = ShellJobs.result_text(job_id, code, output)
    {prose, log} = String.split_at(text, byte_size(text) - byte_size(output))

    case log do
      "" -> [{:text, prose}]
      _output -> [{:text, prose}, {:output, log}]
    end
  end

  @doc """
  The notice text: exactly `parts/3`'s texts joined with no separator.

  `Inbox.enqueue_notice/2` builds the entry's `content` from `parts/3` itself
  rather than calling this (so the two cannot drift); this function is the
  invariant's statement and the oracle the tests hold it to.
  """
  @spec notice(String.t(), integer(), binary()) :: String.t()
  def notice(job_id, code, output) do
    job_id
    |> parts(code, output)
    |> Enum.map_join("", &elem(&1, 1))
  end
end
