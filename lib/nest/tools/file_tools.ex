defmodule Nest.Tools.FileTools do
  @moduledoc """
  The file-system-shaping tools: `file-read`, `file-write`,
  and `file-edit`.

  Their tool-builder returns a `Nest.LLM.Tool` struct; the
  implementation helpers (`read_file`, `write_file`,
  `edit`, `read_file_via_shell`, etc.) are the runtime
  callbacks the closure captures. Extracted from
  `Nest.Tools` to keep that module small enough for credo's
  `Source file has 500 lines (max: 500)` rule.
  """

  require Logger

  alias Nest.LLM.Tool
  alias Nest.Tools.ShellCmd
  alias Nest.Tools.ShellEscape

  # Stat-then-cap mirrors `InspectFile`'s 100 MB cap so the
  # BatchSizer's preflight can refuse before doing the read work.
  @max_read_file_bytes 100 * 1_000_000

  @doc """
  Build the `file-read` `Nest.LLM.Tool` struct.
  """
  @spec read_file_function(String.t() | nil, String.t() | nil) :: Tool.t()
  def read_file_function(workspace_path, tmp_path) do
    %Tool{
      name: "file-read",
      description: "Read the contents of a file from the workspace",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Relative path to the file from the workspace root"
          },
          "max_result_tokens" => Nest.Tools.max_result_tokens_schema()
        },
        "required" => ["path"]
      },
      function: fn %{"path" => path}, context ->
        read_file(path, workspace_path, tmp_path, context)
      end
    }
  end

  @doc """
  Build the `file-write` `Nest.LLM.Tool` struct.
  """
  @spec write_file_function(String.t() | nil, String.t() | nil) :: Tool.t()
  def write_file_function(workspace_path, tmp_path) do
    %Tool{
      name: "file-write",
      description: "Write content to a file in the workspace",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Relative path to the file from the workspace root"
          },
          "content" => %{
            "type" => "string",
            "description" => "Content to write to the file"
          },
          "max_result_tokens" => Nest.Tools.max_result_tokens_schema()
        },
        "required" => ["path", "content"]
      },
      function: fn %{"path" => path, "content" => content}, context ->
        write_file(path, content, workspace_path, tmp_path, context)
      end
    }
  end

  @doc """
  Build the `file-edit` `Nest.LLM.Tool` struct. The closure captures
  the workspace + tmp paths and routes through `edit/5`
  for the actual exact-string-replace logic.
  """
  @spec edit_function(String.t() | nil, String.t() | nil) :: Tool.t()
  def edit_function(workspace_path, tmp_path) do
    %Tool{
      name: "file-edit",
      description:
        "Perform an exact string replacement in a file. Reads the file, " <>
          "replaces the first (or all) occurrence(s) of `old_text` with " <>
          "`new_text`, and writes it back. With `replace_all: false` " <>
          "(the default), `old_text` must match exactly once or the call fails.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Relative path to the file from the workspace root"
          },
          "old_text" => %{
            "type" => "string",
            "description" =>
              "The exact text to find. Must match the file content exactly, " <>
                "including whitespace and indentation."
          },
          "new_text" => %{
            "type" => "string",
            "description" => "The text to replace `old_text` with."
          },
          "replace_all" => %{
            "type" => "boolean",
            "description" =>
              "Replace every occurrence of `old_text` instead of just the first. " <>
                "Default: false. When false, the call errors if `old_text` matches " <>
                "more than one location.",
            "default" => false
          },
          "max_result_tokens" => Nest.Tools.max_result_tokens_schema()
        },
        "required" => ["path", "old_text", "new_text"]
      },
      function: fn args, context ->
        edit(args, workspace_path, tmp_path, context)
      end
    }
  end

  # Read the file directly via `File.read/1` (not via `ShellCmd`).
  # Stat-then-cap mirrors `InspectFile`'s 100 MB cap so the
  # BatchSizer's preflight can refuse before doing the read work.
  # Failed reads return bounded error strings whose sizes are
  # tracked accurately via `Estimator`.
  defp read_file(path, workspace_path, _tmp_path, _context) do
    case resolve_read_path(path, workspace_path) do
      {:ok, full_path} -> read_after_stat(full_path, path)
      {:error, _} = err -> err
    end
  end

  defp resolve_read_path(path, workspace_path) do
    cond do
      Path.type(path) == :absolute -> {:ok, path}
      is_nil(workspace_path) -> {:error, "No workspace configured for this agent"}
      true -> {:ok, Path.join(workspace_path, path)}
    end
  end

  defp read_after_stat(full_path, original_path) do
    case File.stat(full_path) do
      {:ok, %{size: size}} when size > @max_read_file_bytes ->
        mb = div(size, 1_000_000)

        {:error,
         "File is #{mb} MB; file-read is capped at 100 MB. " <>
           "Use file-inspect or shell-cmd with head/tail/sed for partial reads."}

      {:ok, _} ->
        read_file_content(full_path)

      {:error, :enoent} ->
        {:error, "File not found: #{original_path}"}

      {:error, reason} ->
        {:error, "Cannot stat file: #{inspect(reason)}"}
    end
  end

  defp read_file_content(full_path) do
    case File.read(full_path) do
      {:ok, content} ->
        validate_utf8(content)

      {:error, reason} ->
        {:error, "Read failed: #{inspect(reason)}"}
    end
  end

  defp validate_utf8(content) do
    if String.valid?(content) do
      {:ok, content}
    else
      {:error,
       "File is not valid UTF-8; use shell-cmd with hexdump or xxd for binary inspection."}
    end
  end

  # Common path-resolution helper for write_file / edit.
  # Mirrors the logic used in read_file's resolve_read_path/2.
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

  defp write_file(path, content, workspace_path, tmp_path, context) do
    caps = caps_from_context(context)
    Logger.info("Tool file-write: #{path} (workspace: #{workspace_path || "none"})")

    with {:ok, full_path} <- resolve_full_path(path, workspace_path) do
      case ShellCmd.execute(
             "cat > #{ShellEscape.escape(full_path)}",
             workspace_path,
             tmp_path,
             caps,
             stdin: content
           ) do
        {:ok, _} -> {:ok, "Successfully wrote #{String.length(content)} bytes to #{path}"}
        {:error, reason} -> {:error, "Failed to write file: #{reason}"}
      end
    end
  end

  # Edit implementation: read the file (via the same sandboxed cat
  # path as read_file), apply String.replace in Elixir, then write
  # back via the same sandboxed cat path as write_file. Splitting
  # on `old_text` is how we cheaply detect "not found" (parts == 1)
  # and "ambiguous" (parts > 2 with `replace_all: false`).
  defp edit(args, workspace_path, tmp_path, context) do
    path = args["path"]
    old_text = args["old_text"]
    new_text = args["new_text"]
    replace_all = Map.get(args, "replace_all", false)

    caps = caps_from_context(context)
    Logger.info("Tool file-edit: #{path} (replace_all: #{replace_all})")

    with {:ok, full_path} <- resolve_full_path(path, workspace_path),
         {:ok, current} <- read_file_via_shell(full_path, workspace_path, tmp_path, caps),
         {:ok, replacement_count, updated} <-
           compute_replacement(current, old_text, new_text, replace_all) do
      case ShellCmd.execute(
             "cat > #{ShellEscape.escape(full_path)}",
             workspace_path,
             tmp_path,
             caps,
             stdin: updated
           ) do
        {:ok, _} -> {:ok, "Replaced #{replacement_count} occurrence(s) in #{path}"}
        {:error, reason} -> {:error, "Failed to write file: #{reason}"}
      end
    end
  end

  defp read_file_via_shell(full_path, workspace_path, tmp_path, caps) do
    ShellCmd.execute("cat -- #{ShellEscape.escape(full_path)}", workspace_path, tmp_path, caps)
  end

  # Returns {:ok, count, new_content} on success, {:error, reason}
  # when old_text is missing or ambiguous (and replace_all is false).
  defp compute_replacement(_current, "", _new_text, _replace_all) do
    {:error, "old_text must be a non-empty string"}
  end

  defp compute_replacement(current, old_text, new_text, true) do
    case count_matches(current, old_text) do
      0 -> {:error, "old_text not found in file"}
      count -> {:ok, count, String.replace(current, old_text, new_text)}
    end
  end

  defp compute_replacement(current, old_text, new_text, false) do
    parts = String.split(current, old_text)

    case parts do
      [single] when single == current ->
        {:error, "old_text not found in file"}

      [_before, _after] ->
        {:ok, 1, String.replace(current, old_text, new_text, global: false)}

      parts when length(parts) > 2 ->
        {:error,
         "old_text matches #{length(parts) - 1} locations; " <>
           "pass replace_all: true to replace all, or make old_text more specific"}

      _ ->
        # Unreachable given the non-empty `old_text` guard and the
        # cases above; defensive catch-all in case String.split
        # returns an unexpected shape.
        {:error, "old_text not found in file"}
    end
  end

  defp count_matches(content, pattern) do
    case String.split(content, pattern) do
      parts -> max(0, length(parts) - 1)
    end
  end

  defp caps_from_context(%{caps: caps}) when is_map(caps), do: caps
  defp caps_from_context(_), do: nil
end
