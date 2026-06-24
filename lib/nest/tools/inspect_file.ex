defmodule Nest.Tools.InspectFile do
  @moduledoc """
  The `inspect_file` tool — read-only file metadata for the LLM
  to plan its context usage.

  Returns file type, size, line count, char count, max line
  length, and an estimated token count. Never returns file
  content, never modifies the file. The LLM should use this
  before `read_file` to decide whether a full read fits in
  its context budget, or whether to use `shell_cmd` with
  `head`, `tail`, or `sed -n` for a partial read.

  Text vs. binary classification:
    * ASCII or UTF-8 (per `file` output) AND bytes validate as
      UTF-8 (ASCII is a strict subset) -> text stats
    * Anything else (UTF-16, ISO-8859, PNG, ELF, ...) -> binary
      report with a clear "do not use read_file" hint
    * Empty files -> text with zero stats (no read needed)

  Files larger than 100 MB are rejected; the LLM is told to
  use `shell_cmd` with `wc -l` or `head` for those.

  Extracted from `Nest.Tools` to keep that module under the
  500-line Credo cap. Shares the path-resolution policy and
  the read-via-shell pattern with `edit`; both are duplicated
  here rather than exposed publicly because they're small
  (~12 lines total) and the duplication keeps `Nest.Tools`'s
  public surface minimal.
  """

  require Logger

  alias Nest.LLM.Tool
  alias Nest.Tokens.Estimator
  alias Nest.Tools.ShellCmd

  @max_result_tokens 256
  @max_bytes 100 * 1_000_000

  @doc """
  Build the `inspect_file` `Nest.LLM.Tool` struct.
  """
  @spec build(String.t() | nil, String.t() | nil) :: Tool.t()
  def build(workspace_path, tmp_path) do
    %Tool{
      name: "inspect_file",
      description:
        "Inspect a file's metadata (type, encoding, size, line count, " <>
          "char count, max line length, estimated tokens) without reading " <>
          "its contents. Use this before `read_file` to decide whether a " <>
          "full read fits in your context budget, or whether to use " <>
          "`shell_cmd` with `head`, `tail`, or `sed -n` for a partial read. " <>
          "Files larger than 100 MB are rejected; use `shell_cmd` with " <>
          "`wc -l` or `head` for those.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Relative path to the file from the workspace root"
          },
          "max_result_tokens" => max_result_tokens_schema()
        },
        "required" => ["path"]
      },
      max_result_tokens: @max_result_tokens,
      function: fn args, context ->
        execute(args, workspace_path, tmp_path, context)
      end
    }
  end

  # Main implementation. Read-only. Never returns file content.
  def execute(args, workspace_path, tmp_path, context) do
    path = args["path"]
    caps = caps_from_context(context)
    Logger.info("Tool inspect_file: #{path} (workspace: #{workspace_path || "none"})")

    with {:ok, full_path} <- resolve_full_path(path, workspace_path),
         {:ok, byte_size} <- safe_byte_size(full_path),
         :ok <- check_size_cap(byte_size, path),
         {:ok, type_description} <- run_file_type(full_path, workspace_path, tmp_path, caps) do
      if text_type?(type_description) do
        text_output(path, full_path, byte_size, type_description, workspace_path, tmp_path, caps)
      else
        {:ok, format_binary_output(path, type_description, byte_size, nil)}
      end
    end
  end

  defp safe_byte_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, :enoent} -> {:error, "File not found: #{path}"}
      {:error, reason} -> {:error, "Cannot stat file: #{inspect(reason)}"}
    end
  end

  defp check_size_cap(byte_size, path) when byte_size > @max_bytes do
    mb = div(byte_size, 1_000_000)
    cap_mb = div(@max_bytes, 1_000_000)

    {:error,
     "File is #{mb} MB; inspect_file is capped at #{cap_mb} MB. " <>
       "Use shell_cmd with 'wc -l <path>' or 'head -1 <path>' for partial inspection of #{path}."}
  end

  defp check_size_cap(_, _), do: :ok

  # Runs `file -- <path>` and returns the type description (the
  # part after "path:"). `file` is in every standard Linux/macOS
  # install; if it's missing in some sandbox, ShellCmd surfaces
  # the error and we propagate.
  defp run_file_type(full_path, workspace_path, tmp_path, caps) do
    case ShellCmd.execute("file -- #{shell_escape(full_path)}", workspace_path, tmp_path, caps) do
      {:ok, output} -> {:ok, parse_file_type(output)}
      {:error, reason} -> {:error, "Failed to detect file type: #{reason}"}
    end
  end

  defp parse_file_type(output) do
    output
    |> String.split(":", parts: 2)
    |> List.last()
    |> String.trim()
  end

  # The `file` command's text classification is anything that
  # contains "ASCII" (e.g. "ASCII text", "ASCII text, with very
  # long lines") or "UTF-8" without "UTF-16"/"UTF-32" (e.g.
  # "Unicode text, UTF-8 text", "UTF-8 Unicode (with BOM) text").
  # UTF-16, UTF-32, ISO-8859, and other encodings fall through
  # to the binary path. Empty files are classified by `file` as
  # "empty" and are treated as text (no content to read, but
  # still "text-readable"). The actual byte validation
  # (String.valid? below) is the canonical check; this is just a
  # fast pre-filter to avoid reading a multi-MB binary into
  # memory just to reject it.
  defp text_type?("ASCII" <> _), do: true
  defp text_type?("empty"), do: true

  defp text_type?(type) do
    String.contains?(type, "UTF-8") and
      not String.contains?(type, "UTF-16") and
      not String.contains?(type, "UTF-32")
  end

  # Read the file and produce the text-format output. The
  # `String.valid?/1` check is the second line of defense: if
  # `file` says "ASCII text" or "UTF-8" but the bytes don't
  # actually form valid UTF-8 (e.g. a Latin-1 file that snuck
  # past `file`'s heuristics), we fall back to the binary
  # output with a note. Empty files (size 0) skip the read
  # entirely — `ShellCmd.execute` would otherwise substitute
  # the "[Command executed successfully with no output]"
  # placeholder, which would pollute our char/line counts.
  defp text_output(path, _full_path, byte_size, type, _workspace_path, _tmp_path, _caps)
       when byte_size == 0 do
    {:ok, format_text_output(path, type, byte_size, "")}
  end

  defp text_output(path, full_path, byte_size, type, workspace_path, tmp_path, caps) do
    case read_file_via_shell(full_path, workspace_path, tmp_path, caps) do
      {:ok, content} ->
        if String.valid?(content) do
          {:ok, format_text_output(path, type, byte_size, content)}
        else
          {:ok,
           format_binary_output(
             path,
             type,
             byte_size,
             "claimed text but bytes are not valid UTF-8"
           )}
        end

      {:error, reason} ->
        {:error, "Failed to read file for stats: #{reason}"}
    end
  end

  defp format_text_output(path, type, size, content) do
    stats = compute_text_stats(content, size)

    """
    File: #{path}
    Type: #{type}
    Size: #{stats.size} bytes
    Lines: #{stats.lines}
    Non-blank lines: #{stats.non_blank_lines}
    Characters: #{stats.characters}
    Max line length: #{stats.max_line_length}
    Estimated tokens: ~#{stats.estimated_tokens}
    """
  end

  defp format_binary_output(path, type, size, nil) do
    """
    File: #{path}
    Type: #{type}
    Size: #{size} bytes
    Encoding: binary (not text-readable; do not use read_file)
    """
  end

  defp format_binary_output(path, type, size, note) do
    """
    File: #{path}
    Type: #{type}
    Size: #{size} bytes
    Encoding: binary (not text-readable; do not use read_file)
    Note: #{note}
    """
  end

  defp compute_text_stats(content, size) do
    lines = String.split(content, "\n")

    %{
      size: size,
      lines: length(lines),
      non_blank_lines: Enum.count(lines, fn line -> String.trim(line) != "" end),
      characters: String.length(content),
      max_line_length: max_line_length(lines),
      estimated_tokens: Estimator.estimate(content)
    }
  end

  defp max_line_length([]), do: 0
  defp max_line_length(lines), do: lines |> Enum.map(&String.length/1) |> Enum.max()

  # JSON schema fragment for the `max_result_tokens` call arg.
  # The LLM sees this on every tool and learns it can request a
  # specific cap; the agent's tool schema layer enforces the 50%
  # context-window ceiling.
  defp max_result_tokens_schema do
    %{
      "type" => "integer",
      "description" =>
        "Maximum tokens to return. Defaults to the tool's configured max; " <>
          "capped at 50% of the model's context window. Increase for files " <>
          "you know are large."
    }
  end

  # ---- Shared helpers (duplicated from Nest.Tools to keep that
  # module's public surface minimal) ----

  defp resolve_full_path(path, workspace_path) do
    if Path.type(path) == :absolute do
      {:ok, path}
    else
      if is_nil(workspace_path) do
        {:error, "No workspace configured for this agent"}
      else
        {:ok, Path.join(workspace_path, path)}
      end
    end
  end

  defp read_file_via_shell(full_path, workspace_path, tmp_path, caps) do
    ShellCmd.execute("cat -- #{shell_escape(full_path)}", workspace_path, tmp_path, caps)
  end

  defp caps_from_context(%{caps: caps}) when is_map(caps), do: caps
  defp caps_from_context(_), do: nil

  defp shell_escape(path) do
    "'" <> String.replace(path, "'", "'\\''") <> "'"
  end
end
