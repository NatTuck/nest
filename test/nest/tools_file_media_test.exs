defmodule Nest.ToolsFileMediaTest do
  use ExUnit.Case, async: true

  import Nest.Test.TmpCleanup

  alias Nest.LLM.ClientConfig
  alias Nest.Messages.Part
  alias Nest.Sandbox.Mounts
  alias Nest.Tools
  alias Nest.Tools.MediaKind

  # A real 1x1 PNG. `file --mime-type` reports image/png for these bytes, which
  # is what the authoritative check reads.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
       )

  setup do
    workspace =
      Path.join([
        File.cwd!(),
        "_build",
        "tmp",
        "nest_file_media_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(workspace)
    on_exit(fn -> rm_tmp!(workspace, "nest_file_media_") end)

    {:ok, workspace: workspace}
  end

  defp ctx(model) do
    %{client_config: %ClientConfig{model: model}, tool_call_id: "call_1"}
  end

  defp stub_catalog(models), do: Mimic.stub(Nest.Models, :list, fn -> models end)

  defp image_model do
    %{
      "name" => "vision-model",
      "provider" => "local",
      "multi_modal" => %{"input" => ["image"]}
    }
  end

  defp text_model do
    %{"name" => "text-model", "provider" => "local", "multi_modal" => %{"input" => []}}
  end

  defp unknown_model do
    %{"name" => "unknown-model", "provider" => "local", "multi_modal" => nil}
  end

  describe "MediaKind.from_path/1" do
    test "recognises the image extensions it can encode, and nothing else" do
      for name <- ["a.png", "a.PNG", "a.jpg", "a.jpeg", "a.gif", "a.webp"] do
        assert {:ok, :image} = MediaKind.from_path(name)
      end

      for name <- ["a.txt", "a.ex", "a.pdf", "noext", "", "a.png.bak", "a.bmp"] do
        assert MediaKind.from_path(name) == :text
      end

      assert MediaKind.from_path(nil) == :text
    end

    test "accepts only media types it can actually send" do
      # The extension is a hint; this map is the authority `detect/4` checks
      # against. A type missing here can never be attached.
      assert MediaKind.media_types() == %{
               "image/png" => :image,
               "image/jpeg" => :image,
               "image/gif" => :image,
               "image/webp" => :image
             }
    end
  end

  describe "the file-read media gate" do
    test "refuses a media read for a model that declares text-only input", %{
      workspace: workspace
    } do
      File.write!(Path.join(workspace, "shot.png"), @png)
      stub_catalog([text_model()])

      function = Tools.get_function("file-read", Mounts.new(workspace, nil))

      assert {:error, msg} = function.function.(%{"path" => "shot.png"}, ctx("text-model"))

      # The model is named, the detected type is named, and the model is told
      # what to do instead — this error is the whole remedy, since a media part
      # would be re-sent on every later request.
      assert msg =~ "file-read refused"
      assert msg =~ ~s("text-model")
      assert msg =~ "declares text-only input"
      assert msg =~ "image"
      assert msg =~ "shell-cmd"

      # No probe remedy: the provider answered, it just answered "no".
      refute msg =~ "probe-multimodal"

      # Fail closed before the read: no part was built, so no payload leaks in.
      refute msg =~ "base64"
    end

    test "refuses a media read for a model whose input nothing declares", %{workspace: workspace} do
      File.write!(Path.join(workspace, "shot.png"), @png)
      stub_catalog([unknown_model()])

      function = Tools.get_function("file-read", Mounts.new(workspace, nil))

      assert {:error, msg} = function.function.(%{"path" => "shot.png"}, ctx("unknown-model"))

      assert msg =~ "file-read refused"
      assert msg =~ ~s("unknown-model")
      assert msg =~ "no modality metadata"

      # Both remedies are named, because this is the case they exist for.
      assert msg =~ "multi-modal"
      assert msg =~ "probe-multimodal"
      assert msg =~ "shell-cmd"

      # Silence is not a claim that the model is text-only.
      refute msg =~ "text-only"
      refute msg =~ "base64"
    end

    test "refuses when the context carries no model at all", %{workspace: workspace} do
      File.write!(Path.join(workspace, "shot.png"), @png)
      stub_catalog([image_model()])

      function = Tools.get_function("file-read", Mounts.new(workspace, nil))

      assert {:error, msg} =
               function.function.(%{"path" => "shot.png"}, %{tool_call_id: "call_1"})

      assert msg =~ "model is not known"
    end

    test "does not consult the gate for a path that is not media", %{workspace: workspace} do
      File.write!(Path.join(workspace, "notes.txt"), "hello")
      stub_catalog([text_model()])

      function = Tools.get_function("file-read", Mounts.new(workspace, nil))

      # A text-only model must be able to read text with no catalog entry at
      # all; the gate is about media, not about knowing the model.
      assert {:ok, "hello"} = function.function.(%{"path" => "notes.txt"}, ctx("text-model"))
    end
  end

  describe "the file-read media path" do
    test "attaches the image for a model that declares image input", %{workspace: workspace} do
      File.write!(Path.join(workspace, "shot.png"), @png)
      stub_catalog([image_model(), text_model()])

      function = Tools.get_function("file-read", Mounts.new(workspace, nil))

      assert {:ok, {:media, %Part.Media{} = part}} =
               function.function.(%{"path" => "shot.png"}, ctx("vision-model"))

      assert part.tool_call_id == "call_1"
      assert part.modality == :image
      assert part.media_type == "image/png"
      assert part.bytes == byte_size(@png)
      # The sandbox spelling the agent used, not a host path.
      assert part.path == "shot.png"
      assert Base.decode64!(part.data) == @png
    end

    test "reads a nested path the same way", %{workspace: workspace} do
      File.mkdir_p!(Path.join(workspace, "shots"))
      File.write!(Path.join(workspace, "shots/inner.png"), @png)
      stub_catalog([image_model()])

      function = Tools.get_function("file-read", Mounts.new(workspace, nil))

      assert {:ok, {:media, %Part.Media{path: "shots/inner.png"}}} =
               function.function.(%{"path" => "shots/inner.png"}, ctx("vision-model"))
    end

    test "falls back to the text read when a media extension is lying", %{workspace: workspace} do
      # `file --mime-type` is the authority. A `.png` holding text is text, and
      # the extension must not force an attachment.
      File.write!(Path.join(workspace, "fake.png"), "just text")
      stub_catalog([image_model()])

      function = Tools.get_function("file-read", Mounts.new(workspace, nil))

      assert {:ok, "just text"} =
               function.function.(%{"path" => "fake.png"}, ctx("vision-model"))
    end

    test "returns the non-text error for a binary file that is not media", %{workspace: workspace} do
      File.write!(Path.join(workspace, "blob.png"), <<0xFF, 0xFE, 0x00, 0x01>>)
      stub_catalog([image_model()])

      function = Tools.get_function("file-read", Mounts.new(workspace, nil))

      assert {:error, msg} = function.function.(%{"path" => "blob.png"}, ctx("vision-model"))
      assert msg =~ "non-text"
      assert msg =~ "file-inspect"
    end

    test "attaches a media file whose path contains a colon", %{workspace: workspace} do
      # `file --mime-type` runs with `--brief` precisely so this cannot be
      # misparsed: splitting on the first colon would read `a:b.png: image/png`
      # and match nothing, silently demoting the read to text.
      File.write!(Path.join(workspace, "a:b.png"), @png)
      stub_catalog([image_model()])

      function = Tools.get_function("file-read", Mounts.new(workspace, nil))

      assert {:ok, {:media, %Part.Media{media_type: "image/png", path: "a:b.png"}}} =
               function.function.(%{"path" => "a:b.png"}, ctx("vision-model"))
    end

    test "leaves the size cap and missing-file errors alone", %{workspace: workspace} do
      stub_catalog([image_model()])
      function = Tools.get_function("file-read", Mounts.new(workspace, nil))

      assert {:error, msg} = function.function.(%{"path" => "gone.png"}, ctx("vision-model"))
      assert msg =~ "File not found"
    end
  end
end
