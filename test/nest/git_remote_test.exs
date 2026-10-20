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

    test "returns nil for unsupported formats" do
      assert GitRemote.to_https_url("file:///path/to/repo") == nil
    end

    test "handles nil input" do
      assert GitRemote.to_https_url(nil) == nil
    end
  end
end
