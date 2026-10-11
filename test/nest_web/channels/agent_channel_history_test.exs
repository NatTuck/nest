defmodule NestWeb.AgentChannel.HistoryTest do
  @moduledoc """
  Tests for `NestWeb.AgentChannel.History`, the pure query shaping behind the
  `chat:history` page request.

  It owns the page bounds, the role whitelist, the request validation (with the
  error strings the channel replies with), and the recall projection's `origin`
  rule. None of it needs a socket or the DB.
  """

  use ExUnit.Case, async: true

  alias NestWeb.AgentChannel.History

  test "defaults to the module page size with no role or origin filter" do
    assert History.opts(%{}) == {:ok, [before: nil, limit: 50, roles: nil, origin: nil]}
  end

  test "bounds the limit and rejects a non-positive or non-integer one" do
    assert {:ok, opts} = History.opts(%{"limit" => 200})
    assert opts[:limit] == 200

    # The ceiling keeps a misbehaving client from asking for the whole archive.
    assert {:ok, opts} = History.opts(%{"limit" => 10_000})
    assert opts[:limit] == 200

    assert History.opts(%{"limit" => 0}) == {:error, "invalid_limit"}
    assert History.opts(%{"limit" => -5}) == {:error, "invalid_limit"}
    assert History.opts(%{"limit" => "10"}) == {:error, "invalid_limit"}
  end

  test "accepts the archive's roles and rejects anything else" do
    for role <- ~w(system user assistant tool compaction) do
      assert {:ok, opts} = History.opts(%{"role" => role})
      assert opts[:roles] == [role]
    end

    assert History.opts(%{"role" => "bogus"}) == {:error, "invalid_role"}
    assert History.opts(%{"role" => 7}) == {:error, "invalid_role"}
  end

  test "parses before and rejects a negative or non-integer one" do
    assert {:ok, opts} = History.opts(%{"before" => 0})
    assert opts[:before] == 0

    assert {:ok, opts} = History.opts(%{"before" => 7})
    assert opts[:before] == 7

    assert History.opts(%{"before" => -1}) == {:error, "invalid_before"}
    assert History.opts(%{"before" => "7"}) == {:error, "invalid_before"}
  end

  test "origin-filters only the user projection, which is the recall list" do
    # The `role: "user"` projection is the Ctrl/Cmd+Up recall list, so it keeps
    # only human prompts; every other projection stays unfiltered.
    assert {:ok, opts} = History.opts(%{"role" => "user"})
    assert opts[:origin] == "human"

    for role <- ~w(system assistant tool compaction) do
      assert {:ok, opts} = History.opts(%{"role" => role})
      assert opts[:origin] == nil
    end

    assert {:ok, opts} = History.opts(%{})
    assert opts[:origin] == nil
  end
end
