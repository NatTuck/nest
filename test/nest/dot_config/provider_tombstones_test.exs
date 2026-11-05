defmodule Nest.DotConfig.ProviderTombstonesTest do
  @moduledoc """
  How `config.toml` (base) and `local.toml` (overlay) layer providers: the merge
  is **per name**, and `deleted-providers` records the ones the user deleted.

  The bug this pins: the overlay used to replace the whole providers table when
  it defined any provider, so after the first GUI save a provider added to
  `config.toml` was invisible — "add one, hit Rescan providers, nothing
  appears". The blunt rule existed because the overlay cannot delete a provider
  by omitting it (`config.toml` would supply it again), so deletion is now
  *recorded* instead, which is what lets the merge be per name.

  Both paths are stubbed (`config_file/0`, `local_file/0`) so a test writes the
  two files it is about. `DotConfig.load/0` and the writer reach them through
  Mimic's proxy, which is why both are called remotely there.
  """

  use ExUnit.Case, async: true

  import Mimic
  import Nest.Test.TmpCleanup

  alias Nest.DotConfig
  alias Nest.DotConfig.Provider
  alias Nest.DotConfig.Writer
  alias Nest.Models.Catalog

  @marker "nest_tmp_provider_tombstones_"

  setup :verify_on_exit!

  setup do
    base = tmp_toml("base")
    local = tmp_toml("local")

    stub(DotConfig, :config_file, fn -> base end)
    stub(DotConfig, :local_file, fn -> local end)

    {:ok, base: base, local: local}
  end

  describe "merging providers per name" do
    test "a provider only config.toml defines survives a local.toml that defines others",
         %{base: base, local: local} do
      File.write!(base, block("alpha"))
      File.write!(local, block("beta"))

      {:ok, config} = DotConfig.load()

      assert Map.keys(config.providers) |> Enum.sort() == ["alpha", "beta"]
      # The models come with the provider, because the flat map is derived from
      # the merged list.
      assert config.models["alpha-model"].provider_name == "alpha"
    end

    test "a same-named provider is replaced by local.toml's, per name", %{
      base: base,
      local: local
    } do
      File.write!(base, """
      [providers.shared]
      base-url = "https://base.example/v1"
      """)

      File.write!(local, """
      [providers.shared]
      base-url = "https://local.example/v1"
      """)

      {:ok, config} = DotConfig.load()
      assert config.providers["shared"].base_url == "https://local.example/v1"
    end

    test "a file without the key deletes nothing", %{base: base, local: local} do
      File.write!(base, block("alpha"))
      File.write!(local, block("beta"))

      {:ok, config} = DotConfig.load()

      # Every `local.toml` written before this feature existed has no key, so it
      # has to keep meaning "no deletions" rather than "delete everything".
      assert config.deleted_providers == []
      assert Map.keys(config.providers) |> Enum.sort() == ["alpha", "beta"]
    end
  end

  describe "deleted-providers" do
    test "a deleted provider is gone from the merge and from models", %{base: base, local: local} do
      File.write!(base, block("alpha") <> "\n" <> block("beta"))
      File.write!(local, with_deleted(["alpha"], block("kept")))

      {:ok, config} = DotConfig.load()

      refute Map.has_key?(config.providers, "alpha")
      refute Map.has_key?(config.models, "alpha-model")
      assert Map.keys(config.providers) |> Enum.sort() == ["beta", "kept"]
    end

    # The drop is applied to the *merged* map, so which file supplied the
    # provider does not matter. The base half above is the only reachable one: a
    # provider defined in `local.toml` and deleted there is the contradiction
    # refused below.
    test "a file that defines and deletes the same provider is refused, naming it and the file",
         %{
           base: base,
           local: local
         } do
      File.write!(base, block("alpha"))
      File.write!(local, with_deleted(["alpha"], block("alpha")))

      # The file is named because there are two of them: "Provider alpha" alone
      # does not say which one to open.
      assert_raise RuntimeError,
                   ~r/Provider alpha: is both defined and listed in deleted-providers, in #{local}/,
                   fn -> DotConfig.load() end
    end

    test "the key in config.toml is refused, naming the file", %{base: base, local: local} do
      # A list there could hide nothing — `config.toml` is what the records hide
      # a provider *from* — so it would be a valid no-op that reads as a working
      # deletion. The base file is the one that has to be opened to fix it.
      # The tombstoned name is not defined in that file, so this is the key's
      # *placement* being refused, not the contradiction.
      File.write!(base, with_deleted(["beta"], block("alpha")))
      File.write!(local, block("beta"))

      assert_raise RuntimeError,
                   ~r/deleted-providers belongs in local.toml, not in #{base}/,
                   fn -> DotConfig.load() end
    end

    test "a malformed value is refused, naming the key", %{base: base, local: local} do
      File.write!(base, block("alpha"))

      for {value, message} <- [
            {~s("alpha"),
             ~r/Invalid deleted-providers "alpha": must be a list of provider names/},
            {"7", ~r/Invalid deleted-providers 7: must be a list of provider names/},
            {"[7]", ~r/Invalid deleted-providers entry 7: must be a provider name/},
            {~s([""]), ~r/invalid provider name ""/}
          ] do
        File.write!(local, "deleted-providers = #{value}\n")

        assert_raise RuntimeError, message, fn -> DotConfig.load() end
      end
    end
  end

  describe "the api key across the two files" do
    # The browser never receives a provider's key (#202), so a save cannot echo
    # one back to mean "unchanged": the writer omits the line for a keep, and the
    # merge is what makes that omission mean "the base's still applies".
    test "an overlay that sets no key inherits the base's", %{base: base, local: local} do
      File.write!(base, """
      [providers.shared]
      base-url = "https://base.example/v1"
      api-key = "base-secret"
      """)

      File.write!(local, """
      [providers.shared]
      base-url = "https://local.example/v1"
      """)

      {:ok, config} = DotConfig.load()

      # Wholesale replacement of every other field, and the one exception.
      assert config.providers["shared"].base_url == "https://local.example/v1"
      assert config.providers["shared"].api_key == "base-secret"
    end

    test "an empty key shadows the base's", %{base: base, local: local} do
      File.write!(base, """
      [providers.shared]
      base-url = "https://base.example/v1"
      api-key = "base-secret"
      """)

      # What a clear writes. `""` is not "unset": it is the operator saying this
      # provider has no key.
      File.write!(local, """
      [providers.shared]
      api-key = ""
      """)

      {:ok, config} = DotConfig.load()
      assert config.providers["shared"].api_key == ""
    end
  end

  describe "the writer's record" do
    test "records a provider the payload drops, and clears it when it comes back", %{
      base: base,
      local: local
    } do
      File.write!(base, block("alpha") <> "\n" <> block("beta"))

      # A save that drops nothing writes no record at all, so the file is what
      # it was before this feature existed.
      assert :ok = Writer.save_providers([provider("alpha"), provider("beta")])
      refute File.read!(local) =~ "deleted-providers"

      # The GUI sends the set it manages, so a name missing from the payload is
      # a delete.
      assert :ok = Writer.save_providers([provider("alpha")])
      assert File.read!(local) =~ ~s(deleted-providers = ["beta"])

      assert {:ok, config} = DotConfig.load()
      refute Map.has_key?(config.providers, "beta")

      assert :ok = Writer.save_providers([provider("alpha"), provider("beta")])
      refute File.read!(local) =~ "deleted-providers"

      assert {:ok, config} = DotConfig.load()
      assert Map.has_key?(config.providers, "beta")
    end

    test "re-adding a deleted name clears its record and brings the provider back", %{
      base: base,
      local: local
    } do
      File.write!(base, block("alpha"))
      File.write!(local, with_deleted(["alpha"], ""))

      {:ok, gone} = DotConfig.load()
      refute Map.has_key?(gone.providers, "alpha")

      assert :ok = Writer.save_providers([provider("alpha")])

      {:ok, back} = DotConfig.load()
      assert Map.has_key?(back.providers, "alpha")
      assert back.deleted_providers == []
    end

    test "a provider only local.toml defined is dropped without a record", %{
      base: base,
      local: local
    } do
      File.write!(base, block("alpha"))

      assert :ok = Writer.save_providers([provider("alpha"), provider("gui-only")])
      assert File.read!(local) =~ "gui-only"

      assert :ok = Writer.save_providers([provider("alpha")])

      # `config.toml` never defined it, so the rewritten file already removes
      # it. A record here would hide a `[providers.gui-only]` the operator later
      # adds to `config.toml` by hand, for a reason nothing on screen explains.
      refute File.read!(local) =~ "deleted-providers"

      assert {:ok, config} = DotConfig.load()
      refute Map.has_key?(config.providers, "gui-only")
    end

    test "a fresh install with no config.toml records nothing", %{local: local} do
      # Nothing can come back from a file that does not exist, so a deletion
      # needs no record — and the write must not fail because the base is
      # absent, which is what a first run looks like.
      assert :ok = Writer.save_providers([provider("alpha"), provider("beta")])
      assert :ok = Writer.save_providers([provider("alpha")])

      refute File.read!(local) =~ "deleted-providers"

      assert {:ok, config} = DotConfig.load(local)
      assert Map.keys(config.providers) == ["alpha"]
    end

    test "refuses, and writes nothing, when it cannot use what it records against", %{
      base: base,
      local: local
    } do
      # Either file being unusable makes the record a guess, and a wrong guess
      # either resurrects a deleted provider or hides a live one.
      File.write!(base, block("alpha"))

      # A syntax error comes back from `Toml.decode/1` as a tuple...
      File.write!(local, "= not toml\n")
      assert {:error, reason} = Writer.save_providers([provider("alpha")])
      assert reason =~ "cannot use"
      assert File.read!(local) == "= not toml\n"

      # ... but a *semantic* error raises out of `parse_config/1`, and that is
      # the shape a hand-edit actually takes. The sentence has to survive it: a
      # raise here reaches the channel's `rescue`, which answers
      # `invalid_payload` — a false code, since the payload was fine and the
      # file was not.
      File.write!(local, "[providers.broken]\nbase-url = 5\n")
      assert {:error, reason} = Writer.save_providers([provider("alpha")])
      assert reason =~ "cannot use"
      assert reason =~ "Provider broken: invalid base-url"
      assert File.read!(local) == "[providers.broken]\nbase-url = 5\n"

      # The base file is the other half of the record.
      File.write!(base, "= not toml\n")
      File.write!(local, "")
      assert {:error, reason} = Writer.save_providers([provider("alpha")])
      assert reason =~ "cannot use"
      assert File.read!(local) == ""
    end
  end

  describe "the reported scenario" do
    # "Add a provider to `config.toml` while `local.toml` holds others, hit
    # Rescan providers, and it appears." `Nest.Models.reload_static/0` is
    # `DotConfig.load/0` into `static_config` plus `Catalog.build/1` for the
    # list, so those two are the catalog — asserted without mutating the
    # singleton `Models` server that every concurrently running test shares.
    test "a provider added to config.toml after local.toml exists reaches the catalog", %{
      base: base
    } do
      File.write!(base, block("alpha"))

      # The GUI's own save. `local.toml` holding a provider of its own is what
      # used to hide everything in `config.toml`.
      assert :ok = Writer.save_providers([provider("alpha"), provider("beta")])
      {:ok, before} = DotConfig.load()
      assert Map.keys(before.models) == []

      # The operator adds a provider to `config.toml` by hand, then rescans.
      File.write!(base, block("alpha") <> "\n" <> block("gamma"))

      {:ok, reloaded} = DotConfig.load()

      catalog =
        Catalog.build(%{
          static_config: reloaded,
          auto_models: %{},
          context_limits: %{},
          scan: nil
        })

      assert Enum.find(catalog, &(&1["name"] == "gamma-model"))["provider"] == "gamma"
    end
  end

  # --- fixtures ---

  # A minimal provider block: the reader needs the table key and nothing else,
  # and the model gives the provider a name to look for in `models`.
  defp block(name) do
    """
    [providers.#{name}]
    base-url = "https://#{name}.example/v1"

    [[providers.#{name}.models]]
    name = "#{name}-model"
    """
  end

  # `deleted-providers` has to precede the first table header, or TOML reads it
  # as a key of the last table.
  defp with_deleted(names, providers_toml) do
    "deleted-providers = [" <>
      Enum.map_join(names, ", ", &~s("#{&1}")) <> "]\n\n" <> providers_toml
  end

  defp provider(name) do
    %Provider{name: name, base_url: "https://#{name}.example/v1", models: []}
  end

  defp tmp_toml(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{@marker}#{label}_#{System.unique_integer([:positive])}.toml"
      )

    on_exit(fn -> rm_tmp!(path, @marker) end)
    path
  end
end
