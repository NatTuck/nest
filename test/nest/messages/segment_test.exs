defmodule Nest.Messages.SegmentTest do
  @moduledoc """
  Tests for `Nest.Messages.Segment` — a rendered body's segments and the one
  rule two renderers share: bodies are separated by a blank line, carried by the
  last segment of every body but the last.

  The callers' own tests cover the same rule through
  `Nest.Agents.Agent.Turn.Backgrounded.parts/1` and
  `Nest.Agents.Agent.Inbox.Render.parts/2`; what is pinned here is the property
  neither of those can state — that the separator keeps the segment's **kind**,
  which is what stops a body ending in command output from having its last line
  rendered as markdown.
  """

  use ExUnit.Case, async: true

  alias Nest.Messages.Segment

  test "no bodies render no segments" do
    assert Segment.separate([]) == []
  end

  test "a single body carries no separator" do
    assert Segment.separate([[{:text, "prose"}, {:output, "out"}]]) ==
             [{:text, "prose"}, {:output, "out"}]
  end

  test "bodies are separated on the preceding body's last segment, keeping its kind" do
    # The separator rides the *last* segment of every body but the last, and
    # appends without retagging: the first body here ends in command output, so
    # the blank line belongs to that output segment and it stays `:output`. The
    # join is the property every string consumer depends on — separating
    # segments never changes the text.
    groups = [[{:text, "one:\n\n"}, {:output, "1"}], [{:text, "two:\n\n"}, {:output, "2"}]]

    assert Segment.separate(groups) == [
             {:text, "one:\n\n"},
             {:output, "1\n\n"},
             {:text, "two:\n\n"},
             {:output, "2"}
           ]

    assert groups |> Segment.separate() |> Enum.map_join("", &elem(&1, 1)) ==
             "one:\n\n1\n\ntwo:\n\n2"
  end
end
