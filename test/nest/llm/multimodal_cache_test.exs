defmodule Nest.LLM.MultimodalCacheTest do
  @moduledoc """
  Tests for `Nest.LLM.MultimodalCache`, the persistent multi-modal probe
  cache.

  Every test injects its own file by stubbing `path/0` -- the seam the
  module is built around -- so no test can reach the user's real
  `~/.config/nest/probe-cache.json`; one test pins that default path
  directly.

  Most of what is here is the failure matrix. The cache file is a document
  the user may delete, hand-edit, truncate, or leave unwritable, and none
  of that may raise or hand out a verdict the cache would not stand behind.
  """
  use ExUnit.Case, async: true

  import Mimic
  import Nest.Test.TmpCleanup

  alias Nest.DotConfig.Provider
  alias Nest.LLM.MultimodalCache

  setup :verify_on_exit!

  # The cache's own default lifetime.
  @ttl_s 604_800

  # The identifying fragment of every temp path this file builds; it is part
  # of each path by construction, and `rm_tmp!/2` requires it.
  @marker "nest_probe_cache_test_"

  setup do
    dir = Path.join(System.tmp_dir!(), "#{@marker}#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "probe-cache.json")

    Mimic.stub(MultimodalCache, :path, fn -> path end)

    on_exit(fn ->
      # A test may have made the directory unwritable on purpose, and the
      # cleanup has to be able to empty it either way.
      _ = File.chmod(dir, 0o700)
      rm_tmp!(dir, @marker)
    end)

    {:ok, path: path}
  end

  defp provider(overrides \\ []) do
    struct!(
      %Provider{
        name: "p",
        base_url: "http://provider.test/v1",
        api_key: "sk-secret-value",
        protocol: "openai",
        timeout_seconds: 30,
        probe_multimodal: true
      },
      overrides
    )
  end

  defp read_doc!(path), do: path |> File.read!() |> Jason.decode!()

  # Age one stored entry (and optionally give it a hand-edited `ttl_s`), so a
  # test can reach the far side of a week-long TTL without waiting.
  defp age_entry!(path, name, model_id, opts) do
    probed_at =
      DateTime.utc_now()
      |> DateTime.add(-Keyword.fetch!(opts, :seconds_ago), :second)
      |> DateTime.to_iso8601()

    doc = read_doc!(path)
    keys = ["providers", name, "multimodal", model_id]

    entry =
      doc
      |> get_in(keys)
      |> Map.put("probed_at", probed_at)
      |> maybe_put_ttl(opts[:ttl_s])

    File.write!(path, Jason.encode!(put_in(doc, keys, entry)))
  end

  defp maybe_put_ttl(entry, nil), do: entry
  defp maybe_put_ttl(entry, ttl_s), do: Map.put(entry, "ttl_s", ttl_s)

  describe "get/2 and put/3" do
    test "round-trips both definite verdicts through the file" do
      p = provider()

      assert :ok = MultimodalCache.put(p, "image-model", :positive)
      assert :ok = MultimodalCache.put(p, "text-model", :negative)

      assert MultimodalCache.get(p, "image-model") == :positive
      assert MultimodalCache.get(p, "text-model") == :negative
    end

    test "misses on a cache that was never written", %{path: path} do
      refute File.exists?(path)

      assert MultimodalCache.get(provider(), "m") == nil
      assert MultimodalCache.stats() == %{entries: 0, oldest_age_s: nil, path: path}
    end

    test "an unknown verdict is not a finding and is never stored", %{path: path} do
      assert :ok = MultimodalCache.put(provider(), "m", :unknown)

      refute File.exists?(path)
    end

    test "keys entries by provider name, not by endpoint alone" do
      assert :ok = MultimodalCache.put(provider(name: "a"), "m", :positive)

      assert MultimodalCache.get(provider(name: "a"), "m") == :positive
      assert MultimodalCache.get(provider(name: "b"), "m") == nil
      assert MultimodalCache.get(provider(name: "a"), "other") == nil
    end

    test "a changed base_url, protocol, or key stops the stored verdict matching" do
      assert :ok = MultimodalCache.put(provider(), "m", :positive)
      assert MultimodalCache.get(provider(), "m") == :positive

      assert MultimodalCache.get(provider(base_url: "http://elsewhere.test/v1"), "m") == nil
      assert MultimodalCache.get(provider(protocol: "anthropic"), "m") == nil
      assert MultimodalCache.get(provider(api_key: "sk-rotated"), "m") == nil

      # ... and the original endpoint's verdict is still there, untouched.
      assert MultimodalCache.get(provider(), "m") == :positive
    end

    test "a new endpoint's first write drops the previous endpoint's entries", %{path: path} do
      moved = provider(base_url: "http://elsewhere.test/v1")

      assert :ok = MultimodalCache.put(provider(), "old-model", :positive)
      assert :ok = MultimodalCache.put(moved, "new-model", :negative)

      assert MultimodalCache.get(provider(), "old-model") == nil
      assert MultimodalCache.get(moved, "new-model") == :negative
      assert Map.keys(get_in(read_doc!(path), ["providers", "p", "multimodal"])) == ["new-model"]
    end

    test "a key that cannot be resolved is never written, and never matches a real one", %{
      path: path
    } do
      unresolvable = provider(api_key: "${NEST_PROBE_CACHE_UNSET_KEY}")

      assert :ok = MultimodalCache.put(unresolvable, "m", :positive)
      assert MultimodalCache.get(unresolvable, "m") == :positive

      # A key that *does* resolve is a different endpoint.
      assert MultimodalCache.get(provider(api_key: "sk-literal"), "m") == nil

      # Another unresolvable one fingerprints the same way -- both are "no
      # usable key", and both would go out unauthenticated, so the stored
      # verdict describes the same endpoint either way.
      assert MultimodalCache.get(provider(api_key: "${NEST_PROBE_CACHE_OTHER_KEY}"), "m") ==
               :positive

      # A provider with no key at all (a local server) fingerprints as nil
      # too, but is a different provider name, so it is its own entry.
      local = provider(name: "local", api_key: nil)

      assert :ok = MultimodalCache.put(local, "m", :positive)
      assert MultimodalCache.get(local, "m") == :positive

      # The unresolvable reference itself is never written.
      refute File.read!(path) =~ "NEST_PROBE_CACHE_UNSET_KEY"
    end
  end

  describe "malformed documents" do
    test "a corrupt, wrong-version, or non-map document is an empty cache", %{path: path} do
      documents = [
        "",
        "[1, 2, 3]",
        Jason.encode!(%{"version" => 2, "providers" => %{}}),
        Jason.encode!(%{"version" => 1, "providers" => []}),
        Jason.encode!(%{"version" => 1, "providers" => %{"p" => "not a block"}}),
        Jason.encode!(%{"version" => 1, "providers" => %{"p" => %{"multimodal" => "not a map"}}})
      ]

      for document <- documents do
        File.write!(path, document)

        assert MultimodalCache.get(provider(), "m") == nil,
               "expected a miss for #{inspect(document)}"
      end

      assert MultimodalCache.stats().entries == 0
    end

    test "a malformed entry is dropped on its own, not with its siblings", %{path: path} do
      assert :ok = MultimodalCache.put(provider(), "good", :positive)

      stored = read_doc!(path)
      now = DateTime.to_iso8601(DateTime.utc_now())

      models =
        stored
        |> get_in(["providers", "p", "multimodal"])
        |> Map.put("string-entry", "positive")
        |> Map.put("bad-verdict", %{"verdict" => "maybe", "probed_at" => now})
        |> Map.put("bad-time", %{"verdict" => "positive", "probed_at" => "yesterday"})
        |> Map.put("no-time", %{"verdict" => "positive"})

      block = %{
        "endpoint" => get_in(stored, ["providers", "p", "endpoint"]),
        "multimodal" => models
      }

      File.write!(path, Jason.encode!(%{"version" => 1, "providers" => %{"p" => block}}))

      assert MultimodalCache.get(provider(), "good") == :positive

      for model_id <- ["string-entry", "bad-verdict", "bad-time", "no-time"] do
        assert MultimodalCache.get(provider(), model_id) == nil,
               "expected a miss for the malformed entry #{model_id}"
      end

      assert MultimodalCache.stats().entries == 1
    end
  end

  describe "expiry" do
    test "an entry expires after its TTL, and stops being counted", %{path: path} do
      assert :ok = MultimodalCache.put(provider(), "m", :positive)

      age_entry!(path, "p", "m", seconds_ago: 6 * 24 * 3_600)
      assert MultimodalCache.get(provider(), "m") == :positive
      assert MultimodalCache.stats().oldest_age_s >= 6 * 24 * 3_600

      age_entry!(path, "p", "m", seconds_ago: @ttl_s + 1)
      assert MultimodalCache.get(provider(), "m") == nil
      assert MultimodalCache.stats().entries == 0
    end

    test "a hand-edited ttl_s is honoured, and a nonsense one falls back to the default", %{
      path: path
    } do
      assert :ok = MultimodalCache.put(provider(), "m", :positive)

      age_entry!(path, "p", "m", seconds_ago: 3_600, ttl_s: 60)
      assert MultimodalCache.get(provider(), "m") == nil

      age_entry!(path, "p", "m", seconds_ago: 3_600, ttl_s: "soon")
      assert MultimodalCache.get(provider(), "m") == :positive

      age_entry!(path, "p", "m", seconds_ago: 3_600, ttl_s: 0)
      assert MultimodalCache.get(provider(), "m") == :positive
    end

    test "an entry dated in the future is fresh, not negative-aged", %{path: path} do
      assert :ok = MultimodalCache.put(provider(), "m", :positive)

      age_entry!(path, "p", "m", seconds_ago: -3_600)
      assert MultimodalCache.get(provider(), "m") == :positive
      assert MultimodalCache.stats().oldest_age_s == 0
    end
  end

  describe "a file the cache cannot use" do
    test "an unreadable file is a miss, not an error", %{path: path} do
      assert :ok = MultimodalCache.put(provider(), "m", :positive)
      File.chmod!(path, 0o000)

      assert MultimodalCache.get(provider(), "m") == nil
      assert MultimodalCache.stats().entries == 0

      File.chmod!(path, 0o600)
    end

    test "a write that cannot land is logged and still reported as :ok", %{path: path} do
      dir = Path.dirname(path)
      File.chmod!(dir, 0o500)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = MultimodalCache.put(provider(), "m", :positive)
          assert :ok = MultimodalCache.clear()
        end)

      File.chmod!(dir, 0o700)

      assert log =~ "MultimodalCache: cannot write #{path}"
      refute File.exists?(path)
      assert Path.wildcard(path <> ".tmp.*") == []
    end

    test "creates the parent directory it is pointed at", %{path: path} do
      nested = Path.join([Path.dirname(path), "nested", "deeper", "probe-cache.json"])

      Mimic.stub(MultimodalCache, :path, fn -> nested end)

      assert :ok = MultimodalCache.put(provider(), "m", :positive)
      assert MultimodalCache.get(provider(), "m") == :positive
    end
  end

  describe "clear/0" do
    test "empties the cache, leaves a valid document, and is idempotent", %{path: path} do
      assert :ok = MultimodalCache.put(provider(), "m1", :positive)
      assert :ok = MultimodalCache.put(provider(), "m2", :negative)

      assert :ok = MultimodalCache.clear()
      assert MultimodalCache.get(provider(), "m1") == nil

      stored = read_doc!(path)
      assert stored["version"] == 1
      assert stored["providers"] == %{}

      assert :ok = MultimodalCache.clear()
      assert MultimodalCache.get(provider(), "m1") == nil

      # A verdict a scan settles *after* the clear is written normally: a
      # clear means "forget what we knew", never "lose what we find".
      assert :ok = MultimodalCache.put(provider(), "m3", :positive)
      assert MultimodalCache.get(provider(), "m3") == :positive
    end
  end

  describe "stats/0" do
    test "counts the live entries and reports the oldest age", %{path: path} do
      assert :ok = MultimodalCache.put(provider(), "m1", :positive)
      age_entry!(path, "p", "m1", seconds_ago: 120)
      assert :ok = MultimodalCache.put(provider(), "m2", :negative)

      stats = MultimodalCache.stats()
      assert stats.entries == 2
      assert stats.oldest_age_s >= 120
      assert stats.oldest_age_s < 3_600
    end
  end

  describe "the default path" do
    test "is a temp path carrying this OS process's pid, never the user's real config" do
      default = Mimic.call_original(MultimodalCache, :path, [])

      assert String.starts_with?(default, System.tmp_dir!() <> "/")
      assert Path.basename(default) == "nest-probe-cache-#{System.pid()}.json"
    end
  end

  describe "the file itself" do
    test "is written atomically, replaced on the next write, and never holds the key", %{
      path: path
    } do
      assert :ok = MultimodalCache.put(provider(), "m", :positive)
      first = File.read!(path)

      assert Path.wildcard(path <> ".tmp.*") == []
      refute first =~ "sk-secret-value"
      assert first =~ "sha256:"
      assert first =~ ~s("verdict": "positive")

      assert :ok = MultimodalCache.put(provider(), "m", :negative)
      second = File.read!(path)

      assert second =~ ~s("verdict": "negative")
      refute second =~ ~s("verdict": "positive")
    end
  end
end
