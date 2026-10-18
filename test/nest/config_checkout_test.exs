defmodule Nest.Config.CheckoutTest do
  # `async: false` because these tests mutate process-global environment
  # variables (`System.put_env/2`), which every other test in the same VM would
  # see. There is no per-process equivalent.
  use ExUnit.Case, async: false

  # `config/checkout.exs` is evaluated by `config/*.exs` *before* the app
  # compiles, so it lives in `config/` rather than `lib/` and is not part of the
  # application. It is required here so this table can be pinned: which checkout
  # gets which database is the whole safety property, because a worktree that
  # reaches `nest_dev2` can migrate the schema under a running `nest2` — which
  # happened.
  Code.require_file("../../config/checkout.exs", __DIR__)

  alias Nest.Config.Checkout

  # The overrides beat the table, so a stray variable in the runner's
  # environment would make every assertion below pass for the wrong reason.
  setup do
    vars = ~w(NEST_DEV_DB NEST_TEST_DB NEST_PORT MIX_TEST_PARTITION)
    saved = Enum.map(vars, &{&1, System.get_env(&1)})
    Enum.each(vars, &System.delete_env/1)
    on_exit(fn -> Enum.each(saved, fn {var, value} -> restore(var, value) end) end)
    :ok
  end

  defp restore(var, nil), do: System.delete_env(var)
  defp restore(var, value), do: System.put_env(var, value)

  describe "the named checkouts keep fixed identities" do
    test "the primary checkout is nest_dev on 4040 with nest_test" do
      assert Checkout.dev("nest") == %{port: 4040, database: "nest_dev"}
      assert Checkout.test_database("nest") == "nest_test"
    end

    test "nest2 is nest_dev2 on 4042 with nest_test2" do
      assert Checkout.dev("nest2") == %{port: 4042, database: "nest_dev2"}
      assert Checkout.test_database("nest2") == "nest_test2"
    end
  end

  describe "every other checkout gets the scratch slot" do
    test "an unnamed checkout cannot reach nest_dev2" do
      for checkout <- ["rename-vocab", "nest-edit", "wt", "some.other.checkout"] do
        assert Checkout.dev(checkout) == %{port: 4044, database: "nest_dev_scratch"},
               "#{checkout} must not get a named database"

        assert Checkout.test_database(checkout) == "nest_test1"
      end
    end

    test "the checkout's own directory name does not become part of the database" do
      # The old default was "anything not called `nest` shares `nest_dev2`", and
      # a per-checkout derivation would be the other extreme. Both are wrong for
      # the same reason: the set of databases is chosen, not discovered.
      refute Checkout.dev("rename-vocab").database =~ "rename_vocab"
    end
  end

  describe "the overrides win" do
    test "NEST_DEV_DB and NEST_PORT beat the table" do
      System.put_env("NEST_DEV_DB", "nest_dev_scratch2")
      System.put_env("NEST_PORT", "4050")

      assert Checkout.dev("nest") == %{port: 4050, database: "nest_dev_scratch2"}
      assert Checkout.dev("rename-vocab") == %{port: 4050, database: "nest_dev_scratch2"}
    end

    test "NEST_TEST_DB beats the table" do
      System.put_env("NEST_TEST_DB", "nest_test_scratch2")

      assert Checkout.test_database("nest") == "nest_test_scratch2"
      assert Checkout.test_database("rename-vocab") == "nest_test_scratch2"
    end

    test "MIX_TEST_PARTITION selects another test slot" do
      System.put_env("MIX_TEST_PARTITION", "3")

      assert Checkout.test_database("nest") == "nest_test3"
      assert Checkout.test_database("rename-vocab") == "nest_test3"
    end

    test "a blank override is treated as unset" do
      System.put_env("NEST_DEV_DB", "  ")

      assert Checkout.dev("nest").database == "nest_dev"
    end

    test "a non-numeric NEST_PORT raises rather than silently using a default" do
      System.put_env("NEST_PORT", "not-a-port")

      assert_raise ArgumentError, ~r/NEST_PORT must be a positive integer/, fn ->
        Checkout.dev("nest")
      end
    end
  end
end
