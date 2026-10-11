defmodule NestWeb.AgentChannel.HistoryTest do
  @moduledoc """
  Tests for `NestWeb.AgentChannel.History`, the `chat:history` page read.

  It owns the page bounds, the role whitelist, the request validation (with the
  error strings the channel replies with), and the recall projection's `origin`
  rule. `Nest.Persistence.load_history_slice/3` is stubbed, so every case goes
  through the module's one public entry point, `page/3`, and asserts the options
  it hands the persistence layer — the whole of its output besides the reply
  shape.
  """

  use ExUnit.Case, async: true
  use Mimic

  alias Nest.Persistence
  alias NestWeb.AgentChannel.History

  setup :verify_on_exit!

  test "defaults to the module page size with no role or origin filter" do
    assert_page_opts(%{}, before: nil, limit: 50, roles: nil, origin: nil)
  end

  test "bounds the limit and rejects a non-positive or non-integer one" do
    assert_page_opts(%{"limit" => 200}, before: nil, limit: 200, roles: nil, origin: nil)

    # The ceiling keeps a misbehaving client from asking for the whole archive.
    assert_page_opts(%{"limit" => 10_000}, before: nil, limit: 200, roles: nil, origin: nil)

    for bad <- [0, -5, "10"] do
      assert History.page(1, "agent", %{"limit" => bad}) == {:error, "invalid_limit"}
    end
  end

  test "accepts the archive's roles and rejects anything else" do
    for role <- ~w(system user assistant tool compaction) do
      # Only the `user` projection is origin-filtered (see the rule below).
      origin = if role == "user", do: "human", else: nil

      assert_page_opts(%{"role" => role}, before: nil, limit: 50, roles: [role], origin: origin)
    end

    for bad <- ["bogus", 7] do
      assert History.page(1, "agent", %{"role" => bad}) == {:error, "invalid_role"}
    end
  end

  test "parses before and rejects a negative or non-integer one" do
    assert_page_opts(%{"before" => 0}, before: 0, limit: 50, roles: nil, origin: nil)
    assert_page_opts(%{"before" => 7}, before: 7, limit: 50, roles: nil, origin: nil)

    for bad <- [-1, "7"] do
      assert History.page(1, "agent", %{"before" => bad}) == {:error, "invalid_before"}
    end
  end

  test "origin-filters only the user projection, which is the recall list" do
    # The `role: "user"` projection is the Ctrl/Cmd+Up recall list, so it keeps
    # only human prompts; every other projection stays unfiltered.
    assert_page_opts(%{"role" => "user"},
      before: nil,
      limit: 50,
      roles: ["user"],
      origin: "human"
    )

    for role <- ~w(system assistant tool compaction) do
      assert_page_opts(%{"role" => role}, before: nil, limit: 50, roles: [role], origin: nil)
    end

    assert_page_opts(%{}, before: nil, limit: 50, roles: nil, origin: nil)
  end

  # `page/3` is the module's public entry point, so every case goes through it:
  # the options it hands the persistence layer are where the bounds, the role
  # whitelist and the origin rule live, and the empty page is the reply shape
  # the channel forwards.
  defp assert_page_opts(payload, expected) do
    stub(Persistence, :load_history_slice, fn space_id, name, opts ->
      send(self(), {:opts, space_id, name, opts})
      []
    end)

    assert {:ok, %{"messages" => []}} = History.page(7, "agent", payload)
    assert_received {:opts, 7, "agent", ^expected}
  end
end
