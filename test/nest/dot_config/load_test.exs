defmodule Nest.DotConfig.LoadTest do
  @moduledoc """
  `DotConfig.load/1`'s file-reading behaviour, and the per-value validation it
  performs on a provider's `tags` and a model's `multi-modal`.

  Split out of `Nest.DotConfigTest`, which was at 757 of its 700-line cap once
  the `tags` and `multi-modal` validation landed. `load/0`'s merging, the
  top-level scalars and the remaining provider values stay there.
  """

  use ExUnit.Case, async: true

  import Nest.Test.TmpCleanup

  alias Nest.DotConfig
  alias Nest.DotConfig.Provider
  alias Nest.DotConfig.Writer

  describe "the parse cache behind load/1" do
    # `load/1` reads the file on every call and caches only the parse, keyed on
    # the bytes it read — never on the file's *identity*. `ParseCacheTest` pins
    # that key directly; this test pins what it buys where a caller can see it,
    # and it makes the identity as unhelpful as it can be: each replacement is
    # forced back onto the mtime the previous parse was cached under, with the
    # length held equal. A cache keyed on the identity would serve the stale
    # parse here; one keyed on the content cannot.
    test "a replacement is re-read even when the file's mtime and length are unchanged" do
      path = tmp_toml_file("cache_replaced")

      assert :ok = Writer.save_providers([provider("acme")], path)
      assert {:ok, first} = DotConfig.load(path)
      assert Map.keys(first.providers) == ["acme"]

      identity = identity_of(path)

      # `acmb` serializes to exactly as many bytes as `acme`, and the touch puts
      # the file back on the mtime the `acme` parse was cached under. The
      # premise is asserted below: without it the test could pass because the
      # identity moved, which would test nothing.
      assert :ok = Writer.save_providers([provider("acmb")], path)
      File.touch!(path, identity.mtime)
      assert identity_of(path) == identity

      assert {:ok, second} = DotConfig.load(path)
      assert Map.keys(second.providers) == ["acmb"]

      # The same question for a file the application never wrote. No writer was
      # ever in a position to tell the cache anything, and it makes no
      # difference: the key is the bytes, whoever put them there.
      File.write!(path, provider_toml("https://one.example/v1"))
      assert {:ok, hand_written} = DotConfig.load(path)
      assert hand_written.providers["acme"].base_url == "https://one.example/v1"

      hand_identity = identity_of(path)

      File.write!(path, provider_toml("https://two.example/v1"))
      File.touch!(path, hand_identity.mtime)
      assert identity_of(path) == hand_identity

      assert {:ok, edited} = DotConfig.load(path)
      assert edited.providers["acme"].base_url == "https://two.example/v1"
    end
  end

  describe "provider tags" do
    test "is an empty list when the key is absent, and the configured list otherwise" do
      toml = """
      [providers.foo]
      base-url = "http://example.com/v1"
      api-key = "x"
      tags = ["local", "quota"]

      [providers.bar]
      base-url = "http://example.com/v1"
      api-key = "x"
      """

      path = tmp_toml_file("tags_shapes")
      File.write!(path, toml)

      assert {:ok, config} = DotConfig.load(path)
      assert config.providers["foo"].tags == ["local", "quota"]
      assert config.providers["bar"].tags == []
    end

    test "raises on a tags value that is not a list of strings" do
      # A string is the reachable crash: `Enum.member?(provider.tags || [], tag)`
      # in `get_providers_by_tag/2` raises `Protocol.UndefinedError` on a binary,
      # and the `|| []` cannot rescue a value that is truthy but not a list. A
      # non-string element reaches `Enum.join/2` in the `models-list` formatter
      # instead. Both are config typos, and both are rejected when the config is
      # read rather than at whichever call first trips over them.
      for {label, value} <- [
            {"string", ~s("abc")},
            {"element", "[1]"},
            {"table", "{ a = 1 }"}
          ] do
        toml = """
        [providers.foo]
        base-url = "http://example.com/v1"
        api-key = "x"
        tags = #{value}
        """

        path = tmp_toml_file("tags_#{label}")
        File.write!(path, toml)

        assert_raise RuntimeError, ~r/invalid tags/, fn -> DotConfig.load(path) end
      end
    end
  end

  describe "model multi-modal" do
    test "is nil when the model makes no claim, and keeps the shapes it can read" do
      toml = """
      [[providers.foo.models]]
      name = "silent"

      [[providers.foo.models]]
      name = "sees"
      multi-modal = { input = ["image"] }

      [[providers.foo.models]]
      name = "blind"
      multi-modal = { input = [] }
      """

      path = tmp_toml_file("mm_shapes")
      File.write!(path, toml)

      assert {:ok, config} = DotConfig.load(path)
      by_name = Map.new(config.providers["foo"].models, &{&1.name, &1.multi_modal})

      # Three-valued, per `Nest.Models.MultiModal`: silence is not a negative.
      assert by_name["silent"] == nil
      assert by_name["sees"] == %{"input" => ["image"]}
      assert by_name["blind"] == %{"input" => []}
    end

    test "raises on a value that is not a table, instead of dropping it to no-claim" do
      # `multi-modal = false` is the natural way to write "this model does not
      # accept images", and it used to be discarded into "no claim made" — a
      # different fact, and one no reader can tell apart from silence.
      for {label, value} <- [
            {"false", "false"},
            {"true", "true"},
            {"string", ~s("image")},
            {"int", "7"},
            {"list", ~s(["image"])}
          ] do
        toml = """
        [[providers.foo.models]]
        name = "m"
        multi-modal = #{value}
        """

        path = tmp_toml_file("mm_#{label}")
        File.write!(path, toml)

        assert_raise RuntimeError, ~r/invalid multi-modal .*must be a table/, fn ->
          DotConfig.load(path)
        end
      end
    end

    test "raises on an input that is not a list of strings" do
      for {label, value} <- [
            {"string", ~s("image")},
            {"element", "[1]"},
            {"table", "[{ a = 1 }]"}
          ] do
        toml = """
        [[providers.foo.models]]
        name = "m"
        multi-modal = { input = #{value} }
        """

        path = tmp_toml_file("mm_input_#{label}")
        File.write!(path, toml)

        assert_raise RuntimeError,
                     ~r/invalid multi-modal input .*must be a list of strings/,
                     fn ->
                       DotConfig.load(path)
                     end
      end
    end
  end

  describe "model name" do
    # The name is the model's id. `[[providers.x.models]] name = { a = 1 }` used
    # to reach the `models-list` formatter's `"#{provider}/#{name}"` and raise
    # `String.Chars` inside a tool call; a missing name was silently accepted and
    # rendered as a bare `/`.
    test "raises on a name that is not a non-empty string, or is absent" do
      for {label, name_line} <- [
            {"table", ~s(name = { a = 1 })},
            {"number", "name = 3"},
            {"empty", ~s(name = "")},
            {"absent", ""}
          ] do
        toml = """
        [[providers.foo.models]]
        #{name_line}
        context-limit = 1000
        """

        path = tmp_toml_file("model_name_#{label}")
        File.write!(path, toml)

        assert_raise RuntimeError, ~r/Provider foo: .*name/, fn ->
          DotConfig.load(path)
        end
      end
    end
  end

  describe "provider probe-base-url" do
    # The reader raised on this before the write side guarded it, which is how a
    # `probe-base-url = ""` from a channel client became a config the app wrote
    # for itself and then refused to read.
    test "keeps a non-empty binary, is nil when absent, and raises otherwise" do
      kept = """
      [providers.acme]
      probe-base-url = "https://probe.example/v1"
      """

      absent = """
      [providers.acme]
      base-url = "https://acme.example/v1"
      """

      assert load_probe_base_url(kept) == "https://probe.example/v1"
      assert load_probe_base_url(absent) == nil

      for {label, line} <- [
            {"empty", ~s(probe-base-url = "")},
            {"number", "probe-base-url = 7"},
            {"table", "probe-base-url = { a = 1 }"}
          ] do
        path = tmp_toml_file("probe_url_#{label}")
        File.write!(path, "[providers.acme]\n" <> line <> "\n")

        assert_raise RuntimeError, ~r/Provider acme: invalid probe-base-url/, fn ->
          DotConfig.load(path)
        end
      end
    end
  end

  describe "model context-limit" do
    # The reader passed this through unvalidated, so it never raised — which is
    # why the earlier sweep missed it. It is refused now because the value is not
    # "no limit": `Init.context_limit_layer/3` keeps any integer and
    # `Reserve.compaction_reserve/1` guards `limit > 0`, so `0` raises on every
    # agent start.
    test "keeps a positive integer, is nil when absent, and raises otherwise" do
      assert load_model_context_limit("") == nil
      assert load_model_context_limit("context-limit = 1000") == 1000

      for {label, line} <- [
            {"zero", "context-limit = 0"},
            {"negative", "context-limit = -1"},
            {"fractional", "context-limit = 0.5"}
          ] do
        path = tmp_toml_file("model_limit_#{label}")

        File.write!(path, """
        [[providers.foo.models]]
        name = "m"
        #{line}
        """)

        assert_raise RuntimeError, ~r/Provider foo: invalid context-limit/, fn ->
          DotConfig.load(path)
        end
      end
    end
  end

  describe "provider base-url" do
    # The last field of this class, and the same shape as `probe-base-url`
    # above: neither side validated it, so the two *agreed* and no drift
    # existed — but the value is dereferenced on every chat, and a non-binary
    # raises `FunctionClauseError` in `String.trim_trailing/2`
    # (`OpenAIClient.normalize_endpoint/2`) and in `EndpointProbe.probe/1`.
    test "keeps a non-empty binary, is nil when absent, and raises otherwise" do
      assert load_base_url(~s(base-url = "https://acme.example/v1")) ==
               "https://acme.example/v1"

      # Absent means absent: with no `base-url` key the value is `nil`, not an
      # error.
      assert load_base_url(~s(api-key = "none")) == nil

      for {label, line} <- [
            {"empty", ~s(base-url = "")},
            {"number", "base-url = 7"},
            {"table", "base-url = { a = 1 }"}
          ] do
        path = tmp_toml_file("base_url_#{label}")
        File.write!(path, "[providers.acme]\n" <> line <> "\n")

        assert_raise RuntimeError, ~r/Provider acme: invalid base-url/, fn ->
          DotConfig.load(path)
        end
      end
    end
  end

  describe "provider api-key" do
    # The read side passed a non-binary through — `KeyValidation` only acts
    # `when is_binary(key)` — so a hand-written `api-key = 7` booted and then
    # raised `FunctionClauseError` in `String.starts_with?/2` inside
    # `resolve_api_key/1` at chat time. Both sides call the rule now, so it is a
    # startup error instead.
    test "keeps text, is nil when absent, and raises on a non-binary" do
      # The premise: every legitimate shape of a key is text. An empty string and
      # the documented `api-key = "none"` opt-out are both real, and refusing
      # them would break working configs.
      assert load_api_key(~s(api-key = "sk-literal")) == "sk-literal"
      assert load_api_key(~s(api-key = "")) == ""
      assert load_api_key(~s(api-key = "none")) == "none"
      assert load_api_key(~s(base-url = "https://acme.example/v1")) == nil

      for {label, line} <- [
            {"number", "api-key = 7"},
            {"table", "api-key = { a = 1 }"}
          ] do
        path = tmp_toml_file("api_key_#{label}")
        File.write!(path, "[providers.acme]\n" <> line <> "\n")

        assert_raise RuntimeError, ~r/Provider acme: invalid api-key/, fn ->
          DotConfig.load(path)
        end
      end
    end
  end

  describe "provider models" do
    # A malformed `models` used to fall through to `[]`, silently dropping the
    # whole model list — the opposite of this module's "a bad value is a startup
    # error" convention. The write side already raised on it, so the two agree
    # now.
    test "is empty when absent, and raises on a value that is not an array of tables" do
      assert load_models(~s(base-url = "https://acme.example/v1")) == []
      assert length(load_models(~s(models = [{ name = "m" }]))) == 1

      for {label, line} <- [
            {"string", ~s(models = "abc")},
            {"number", "models = 7"},
            {"table", ~s(models = { name = "m" })}
          ] do
        path = tmp_toml_file("models_#{label}")
        File.write!(path, "[providers.acme]\n" <> line <> "\n")

        assert_raise RuntimeError, ~r/Provider acme: invalid models/, fn ->
          DotConfig.load(path)
        end
      end
    end
  end

  # --- fixtures ---

  defp load_probe_base_url(toml) do
    path = tmp_toml_file("probe_url_ok")
    File.write!(path, toml)
    {:ok, config} = DotConfig.load(path)
    config.providers["acme"].probe_base_url
  end

  # Both of these take a bare `key = value` line and wrap it in a provider
  # table, so a premise case and a refusal case share one shape.
  defp load_base_url(line) do
    path = tmp_toml_file("base_url_ok")
    File.write!(path, "[providers.acme]\n" <> line <> "\n")
    {:ok, config} = DotConfig.load(path)
    config.providers["acme"].base_url
  end

  defp load_api_key(line) do
    path = tmp_toml_file("api_key_ok")
    File.write!(path, "[providers.acme]\n" <> line <> "\n")
    {:ok, config} = DotConfig.load(path)
    config.providers["acme"].api_key
  end

  defp load_models(line) do
    path = tmp_toml_file("models_ok")
    File.write!(path, "[providers.acme]\n" <> line <> "\n")
    {:ok, config} = DotConfig.load(path)
    config.providers["acme"].models
  end

  defp load_model_context_limit(line) do
    path = tmp_toml_file("model_limit_ok")

    File.write!(path, """
    [[providers.foo.models]]
    name = "m"
    #{line}
    """)

    {:ok, config} = DotConfig.load(path)
    hd(config.providers["foo"].models).context_limit
  end

  defp provider(name) do
    %Provider{name: name, base_url: "https://cache.example/v1", models: []}
  end

  defp provider_toml(base_url) do
    """
    [providers.acme]
    base-url = "#{base_url}"
    """
  end

  # A unique temp `.toml` path, cleaned up on exit by the project's guarded
  # helper. Generic: the parse-cache fixtures and the value-validation fixtures
  # both write one and then load it.
  defp tmp_toml_file(label) do
    path =
      Path.join(System.tmp_dir!(), "#{label}_#{System.unique_integer([:positive])}.toml")

    on_exit(fn -> rm_tmp!(path, label) end)
    path
  end

  # The two terms of the identity a stat-based key would have used. Reading them
  # the way `File.stat/2` reports them, and forcing a replacement back onto the
  # previous value of both, is what leaves the bytes as the only thing that can
  # tell two revisions apart. `File.touch!/2` takes a posix second directly
  # (`posix_time()` is in its spec), so this needs no timezone conversion.
  defp identity_of(path), do: %{mtime: mtime_of(path), size: size_of(path)}

  defp mtime_of(path), do: File.stat!(path, time: :posix).mtime
  defp size_of(path), do: File.stat!(path).size
end
