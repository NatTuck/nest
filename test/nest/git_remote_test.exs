defmodule Config.GitRemoteTest do
  use ExUnit.Case, async: true

  alias Config.GitRemote

  describe "to_https_url/1" do
    test "converts SSH GitHub URL to HTTPS" do
      assert GitRemote.to_https_url("git@github.com:user/repo.git") ==
               "https://github.com/user/repo"

      assert GitRemote.to_https_url("git@github.com:user/repo") ==
               "https://github.com/user/repo"
    end

    test "converts SSH GitLab URL to HTTPS" do
      assert GitRemote.to_https_url("git@gitlab.com:user/repo.git") ==
               "https://gitlab.com/user/repo"
    end

    test "keeps HTTPS URLs as-is" do
      assert GitRemote.to_https_url("https://github.com/user/repo.git") ==
               "https://github.com/user/repo"

      assert GitRemote.to_https_url("https://github.com/user/repo") ==
               "https://github.com/user/repo"
    end

    test "keeps HTTP URLs as-is" do
      assert GitRemote.to_https_url("http://example.com/repo.git") ==
               "http://example.com/repo"
    end

    test "handles URLs with subgroups" do
      assert GitRemote.to_https_url("git@gitlab.com:group/subgroup/repo.git") ==
               "https://gitlab.com/group/subgroup/repo"
    end

    test "returns nil for unsupported formats" do
      assert GitRemote.to_https_url("file:///path/to/repo") == nil
      assert GitRemote.to_https_url("ftp://example.com/repo") == nil
      assert GitRemote.to_https_url("not-a-url") == nil
    end

    test "handles nil input" do
      assert GitRemote.to_https_url(nil) == nil
    end
  end
end

defmodule Nest.GitRemoteTest do
  use ExUnit.Case, async: true

  alias Nest.GitRemote

  describe "source_url/0" do
    test "returns the configured source URL" do
      # This is set at build time in config.exs
      url = GitRemote.source_url()

      # Should be nil or a valid URL
      if url do
        assert String.starts_with?(url, "http")
      end
    end
  end
end
