defmodule Nest.Agents.Agent.BackgroundedTest do
  @moduledoc """
  `Nest.Agents.Agent.Turn.Backgrounded`'s notice, as segments and as text.

  A notice is not one string but a sequence of segments (issue #139): the prose
  the model reads, and the backgrounded command's own output, which the client
  renders verbatim rather than as markdown. `notice/1` is *defined* as the join
  of those segments, so every case here asserts both halves — the exact
  segments, and the exact notice string, spelled out rather than derived — and
  the two together are what make the split a display change and nothing more.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Turn.Backgrounded

  @finished "Your backgrounded command (shell-cmd) finished. Its result:\n\n"
  @timed_out "Your backgrounded command (shell-cmd) timed out. Its output so far:\n\n"

  # The `ShellCmd.handle_timeout/3` marker the wording keys off.
  @timeout_marker "[Command timed out after 1000ms]"

  describe "parts/1" do
    test "one result is its prose then its output, and the notice is their join" do
      # The prose is byte-identical to what the notice has always said, spelled
      # out here rather than rebuilt from the code under test — so a change to
      # the wording, or to how the segments are joined, fails visibly. The
      # timeout wording is keyed off the command's own marker (decision D4),
      # whatever the tool is called.
      cases = [
        {"finished", "shell-cmd", "total 0\n# not a heading\n*not emphasis*\n", @finished},
        {"timed out", "shell-cmd", "partial line\n" <> @timeout_marker, @timed_out},
        {"timed out, another tool's name", "other", @timeout_marker,
         "Your backgrounded command (other) timed out. Its output so far:\n\n"}
      ]

      for {label, name, output, prose} <- cases do
        outcome = {:results, [%{name: name, content: output}]}

        assert Backgrounded.parts(outcome) == [{:text, prose}, {:output, output}], label

        assert Backgrounded.notice(outcome) == prose <> output, label
        assert joined(outcome) == Backgrounded.notice(outcome), label
      end
    end

    test "several results keep their order, separated by a blank line on the last segment" do
      # The separator rides each non-final result's *last* segment, which is its
      # output: the next result's prose still starts a paragraph of its own, and
      # the final result carries none — exactly what the old
      # `Enum.map_join(results, "\n\n", …)` did.
      outcome =
        {:results, [%{name: "first", content: "one"}, %{name: "second", content: "two"}]}

      assert Backgrounded.parts(outcome) == [
               {:text, "Your backgrounded command (first) finished. Its result:\n\n"},
               {:output, "one\n\n"},
               {:text, "Your backgrounded command (second) finished. Its result:\n\n"},
               {:output, "two"}
             ]

      assert Backgrounded.notice(outcome) ==
               "Your backgrounded command (first) finished. Its result:\n\none\n\n" <>
                 "Your backgrounded command (second) finished. Its result:\n\ntwo"

      assert joined(outcome) == Backgrounded.notice(outcome)
    end

    test "a worker's death is one prose segment: there is no output to show" do
      outcome = {:worker_down, :killed}

      assert Backgrounded.parts(outcome) == [
               {:text,
                "A backgrounded tool call stopped before it finished (:killed), " <>
                  "so its result will not arrive. Call it again if you still need it."}
             ]

      assert Backgrounded.notice(outcome) ==
               "A backgrounded tool call stopped before it finished (:killed), " <>
                 "so its result will not arrive. Call it again if you still need it."

      assert joined(outcome) == Backgrounded.notice(outcome)
    end

    test "an empty result list renders nothing at all" do
      # Total on an empty batch: no segments and no text, rather than a stray
      # separator or a crash inside the agent process.
      assert Backgrounded.parts({:results, []}) == []
      assert Backgrounded.notice({:results, []}) == ""
    end
  end

  # The invariant the moduledoc states: the notice is the join of the segments'
  # texts, in order, with no separator of its own.
  defp joined(outcome), do: Enum.map_join(Backgrounded.parts(outcome), "", &elem(&1, 1))
end
