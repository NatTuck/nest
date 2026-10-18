defmodule Nest.AddressTest do
  @moduledoc """
  The address rule (`Nest.Address`): `@<username>` is a human, a bare name is an
  agent, and the sigil is the only thing that tells them apart.

  Pure — no database, no registry: what an address *means* is decided here, and
  whether it names anybody is the callers' (`Nest.Notes`,
  `Nest.Agents.target_error/2`).
  """

  use ExUnit.Case, async: true

  alias Nest.Address

  describe "parse/1" do
    test "a sigil names a human and a bare name names an agent" do
      assert Address.parse("@nat") == {:user, "nat"}
      assert Address.parse("crazy-dolphin") == {:agent, "crazy-dolphin"}
    end

    test "an address folds through Nest.Name, so @Nat and @nat are one human" do
      # The sigil is what makes the fold safe: the text is an *address*, written
      # to be read back, and a username is stored folded — so a capital cannot
      # be a second account, and must not be a second address either.
      assert Address.parse("@Nat") == {:user, "nat"}
      assert Address.parse("@Jane Doe") == {:user, "jane-doe"}
      assert Address.parse("@NAT") |> Address.format() == "@nat"
    end

    test "a bare name is not folded: it is an identifier, not an address" do
      # The one asymmetry, and it is deliberate. `Nat` names no agent — names are
      # lowercase — and picking `nat` for it would be a guess about which row the
      # caller meant. The send tools' refusal names the human `@nat` it could
      # have meant instead, which is the spelling a model that dropped the sigil
      # needs.
      assert Address.parse("Nat") == {:agent, "Nat"}
    end

    test "`@` alone is an address that names nobody" do
      assert Address.parse("@") == {:user, ""}
      assert Address.parse("@...") |> Address.format() == "@"
    end

    test "a missing sender is an unnamed agent, never a human" do
      # The inbox stores `nil` for a sender it does not have; it must not read as
      # a human's words.
      assert Address.parse(nil) == {:agent, nil}
      assert Address.parse(nil) |> Address.format() == nil
    end
  end

  describe "format/1" do
    test "round-trips both kinds" do
      for target <- ["@nat", "crazy-dolphin"] do
        assert target |> Address.parse() |> Address.format() == target
      end
    end
  end

  describe "user?/1" do
    test "classifies by the sigil alone, whether or not anybody is named" do
      assert Address.user?("@nat")
      assert Address.user?("@nobody")
      refute Address.user?("nat")
      refute Address.user?(nil)
    end
  end
end
