defmodule Nest.Messages.SegmentTest do
  @moduledoc """
  Tests for `Nest.Messages.Segment` — a rendered body's segments and the one
  rule two renderers share: bodies are separated by a blank line, carried by the
  last segment of every body but the last.

  The callers' own tests exercise the same rule through
  `Nest.Agents.Agent.Turn.Backgrounded.parts/1` and
  `Nest.Agents.Agent.Inbox.Render.parts/2`; what is pinned here is `separate/1`
  on its own — the empty clause, and the separator riding the preceding body's
  last segment with that segment's kind intact.
  """

  use ExUnit.Case, async: true

  alias Nest.Messages.Segment

  test "no bodies render no segments" do
    assert Segment.separate([]) == []
  end

  test "bodies are separated on the preceding body's last segment, keeping its kind" do
    # The separator rides the *last* segment of every body but the last, and
    # appends without retagging: the first body here ends in command output, so
    # the blank line belongs to that output segment and it stays `:output`. The
    # last body carries none, which is also the single-body case.
    groups = [[{:text, "one:\n\n"}, {:output, "1"}], [{:text, "two:\n\n"}, {:output, "2"}]]

    assert Segment.separate(groups) == [
             {:text, "one:\n\n"},
             {:output, "1\n\n"},
             {:text, "two:\n\n"},
             {:output, "2"}
           ]
  end
end
