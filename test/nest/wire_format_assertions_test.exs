defmodule Nest.WireFormatAssertionsTest do
  @moduledoc """
  Tests for `Nest.WireFormatAssertions.assert_wire_encodable!/1`.

  The helper is the guard that channel tests use to run the real
  socket serializer over a payload. Its failure path must actually
  find the offending value and report its path, otherwise a real
  regression would surface as an opaque failure.
  """

  use ExUnit.Case, async: true

  import Nest.WireFormatAssertions

  test "returns the payload unchanged when it is JSON-serializable" do
    payload = %{"a" => [1, "two", %{"three" => true}], "n" => nil}

    assert assert_wire_encodable!(payload, "ok") == payload
  end

  test "flunks and reports the path to a non-encodable tuple" do
    payload = %{"partial" => %{"currentType" => {:tool_use, "call_1"}}}

    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_wire_encodable!(payload, "bad")
      end

    assert error.message =~ "not JSON-serializable"
    assert error.message =~ "partial.currentType"
    assert error.message =~ "call_1"
  end

  test "reports the index of a non-encodable value inside a list" do
    payload = %{"items" => [%{"ok" => 1}, {:bad, "tuple"}]}

    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_wire_encodable!(payload, "bad")
      end

    assert error.message =~ "items[1]"
  end

  test "flunks for a payload that is not a map" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_wire_encodable!([:not, :a, :map], "bad")
      end

    assert error.message =~ "not JSON-serializable"
  end
end
