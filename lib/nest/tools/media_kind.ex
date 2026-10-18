defmodule Nest.Tools.MediaKind do
  @moduledoc """
  Which media modality a file is, and whether a path merely *looks* like media.

  Two entry points, deliberately different in strength:

    * `from_path/1` — the **extension only**. Pure, no I/O, so the
      `BatchSizer`'s preflight can call it per tool call without paying a
      bwrap spawn. It can be wrong, and that is acceptable: the preflight
      only needs an upper bound, and the execution path re-checks.
    * `detect/3` — the **authoritative** check. Runs `file --mime-type`
      inside the sandbox and returns a modality only when the reported type
      is one of `media_types/0` *and* its modality agrees with the
      extension. The `file-read` media path calls this, so a file that is
      not really an image is never attached as one.

  Keeping both here means the extension list and the accepted MIME list live
  in one place instead of being duplicated between `FileTools` and
  `ProjectedSize`. The asymmetry is the point: the preflight must not pay a
  sandbox spawn per call, and the execution path must not guess.
  """

  alias Nest.Messages.Part
  alias Nest.Sandbox
  alias Nest.Tools.ShellEscape

  # The media types this build can attach, and the modality each belongs to.
  # This is the authority: `detect/3` accepts a file only when `file` reports
  # one of these, and `Part.new_media/1` re-checks that the type prefix agrees
  # with the modality. The four are the union of what the supported providers
  # accept as an image input.
  @media_types %{
    "image/png" => :image,
    "image/jpeg" => :image,
    "image/gif" => :image,
    "image/webp" => :image
  }

  # Extension -> modality. A hint for the preflight only; `detect/3` decides.
  # Matched case-insensitively.
  @extensions %{
    ".png" => :image,
    ".jpg" => :image,
    ".jpeg" => :image,
    ".gif" => :image,
    ".webp" => :image
  }

  @doc """
  The media MIME types this build can attach, mapped to their modality.
  """
  @spec media_types() :: %{String.t() => Part.Media.modality()}
  def media_types, do: @media_types

  @doc """
  The modality a path's *extension* suggests, or `:text` when it suggests
  nothing. No I/O: safe to call from the preflight.
  """
  @spec from_path(String.t() | term()) :: {:ok, Part.Media.modality()} | :text
  def from_path(path) when is_binary(path) do
    case Map.get(@extensions, String.downcase(Path.extname(path))) do
      nil -> :text
      modality -> {:ok, modality}
    end
  end

  def from_path(_path), do: :text

  @doc """
  Authoritatively classify a file inside the sandbox.

  Returns `{:ok, modality, mime_type}` when `file` reports one of
  `media_types/0` whose modality agrees with the extension, `:text` when the
  file is not media (including when it only *looked* like it), or
  `{:error, reason}` when the check itself could not run — a caller must not
  treat a failed check as "not media", because that would silently read an
  image as text.
  """
  @spec detect(String.t(), map(), Mounts.t()) ::
          {:ok, Part.Media.modality(), String.t()} | :text | {:error, String.t()}
  def detect(full_path, caps, mounts) do
    with {:ok, modality} <- from_path(full_path),
         {:ok, mime} <- mime_type(full_path, caps, mounts) do
      case @media_types do
        %{^mime => ^modality} -> {:ok, modality, mime}
        _ -> :text
      end
    else
      :text -> :text
      {:error, _reason} = error -> error
    end
  end

  # `file --mime-type --brief -- <path>` prints the type alone, with no
  # `<path>: ` prefix. That matters: splitting on the first colon would
  # misparse a path that itself contains one (`/tmp/a:b.png`), which would then
  # match nothing in `@media_types` and make `detect/3` return `:text` — a
  # silent misclassification, in the one function whose contract says a caller
  # must not read a failed check as "not media".
  defp mime_type(full_path, caps, mounts) do
    command = "file --mime-type --brief -- #{ShellEscape.escape(full_path)}"

    case Sandbox.run(command, mounts, caps) do
      {:ok, output} ->
        {:ok, String.trim(output)}

      # `{:cancelled, _}` too: this command is short, and a caller that cancels it
      # has nothing else to be told.
      {tag, reason} when tag in [:error, :cancelled] ->
        {:error, "Failed to detect file type: #{inspect(reason)}"}
    end
  end
end
