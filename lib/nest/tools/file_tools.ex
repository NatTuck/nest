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
  alias Nest.Messages.Part
  alias Nest.Messages.Sanitize
  alias Nest.Sandbox
  alias Nest.Sandbox.Mounts
  alias Nest.Tokens.RequestSize
  alias Nest.Tools.MediaKind

  # Stat-then-cap mirrors `InspectFile`'s cap so the BatchSizer's
  # preflight can refuse before doing the read work.
  #
  # 10 MB is a sanity bound on how much a single tool result may pull
  # into memory, NOT the real limit on a read: the real limit is the
  # caller's token budget, enforced per call by the BatchSizer's
  # `max_result_tokens` cap. The old 100 MB was never reachable for a
  # text read (it is far past any context window) and it is a
  # pathological amount of memory to hold for a media read.
  @max_read_file_bytes 10 * 1_000_000

  # A broken sandbox is a Nest configuration problem, not a missing file, so
  # the caller is told that plainly rather than "file not found".
  @sandbox_setup_failed "The sandbox failed to start; this is a Nest configuration problem, not a missing file."

  @doc """
  Build the `file-read` `Nest.LLM.Tool` struct.
  """
  @spec read_file_function(Mounts.t()) :: Tool.t()
  def read_file_function(mounts) do
    %Tool{
      name: "file-read",
      description:
        "Read the contents of a file from the workspace. The read resolves " <>
          "inside the sandbox, so only files the sandbox exposes are visible. " <>
          "Images (png, jpeg, gif, webp) are attached for a model that accepts " <>
          "image input, and refused with the reason when it does not; a binary " <>
          "file that is not one of those is refused as non-text.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to the file: absolute, or relative to the workspace root."
          },
          "max_result_tokens" => Nest.Tools.max_result_tokens_schema()
        },
        "required" => ["path"]
      },
      function: fn %{"path" => path}, context ->
        read_file(path, mounts, context)
      end
    }
  end

  @doc """
  Build the `file-write` `Nest.LLM.Tool` struct.
  """
  @spec write_file_function(Mounts.t()) :: Tool.t()
  def write_file_function(mounts) do
    %Tool{
      name: "file-write",
      description: "Write content to a file in the workspace.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to the file: absolute, or relative to the workspace root."
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
        write_file(path, content, mounts, context)
      end
    }
  end

  @doc """
  Build the `file-edit` `Nest.LLM.Tool` struct. The closure captures
  the agent's `Nest.Sandbox.Mounts` and routes through `edit/4`
  for the actual exact-string-replace logic.
  """
  @spec edit_function(Mounts.t()) :: Tool.t()
  def edit_function(mounts) do
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
            "description" => "Path to the file: absolute, or relative to the workspace root."
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
        edit(args, mounts, context)
      end
    }
  end

  # Read the file through the sandbox. The path is in the sandbox domain, and
  # `mounts` is the value `Nest.Sandbox` reads the bind layout out of.
  # Failed reads return bounded error strings whose sizes are
  # tracked accurately via `Estimator`.
  defp read_file(path, mounts, context) do
    caps = caps_from_context(context)

    case Mounts.resolve(path, mounts) do
      {:ok, full_path} ->
        read_after_stat(full_path, path, caps, mounts, context)

      {:error, _} = err ->
        err
    end
  end

  defp read_after_stat(full_path, original_path, caps, mounts, context) do
    case Sandbox.stat(full_path, caps, mounts) do
      {:ok, %{size: size}} when size > @max_read_file_bytes ->
        too_large_error(size)

      {:ok, %{size: size}} ->
        read_classified(full_path, original_path, caps, mounts, context, size)

      {:error, reason} ->
        read_error(reason, original_path)
    end
  end

  # Media or text? The extension is only a filter, so a path that does not
  # look like media never pays the extra `file --mime-type` spawn, and a path
  # that does look like media is still confirmed by `MediaKind.detect/3`
  # before anything is attached.
  defp read_classified(full_path, original_path, caps, mounts, context, size) do
    case MediaKind.from_path(full_path) do
      :text ->
        read_file_content(full_path, caps, mounts)

      {:ok, modality} ->
        read_media_file(full_path, original_path, caps, mounts, modality, context, size)
    end
  end

  # The media path.
  #
  # Both gates run FIRST — before the `file` check, before the read, and before
  # any part is built. A media part is re-sent on every subsequent request, so
  # attaching one the caller's model cannot accept, or one that puts the request
  # over the provider's body limit, breaks every later turn. Refusing here, with
  # a message the model can act on, is the only fail-fast point there is.
  #
  # The modality gate is first because it is both the cheaper check (a catalog
  # lookup against a walk over every message) and the more fundamental one: a
  # model that cannot accept images will still refuse them after a compaction,
  # so telling the model to compact first would be advice that does not work.
  # Images can outlive a model swap — `Agents.change_model/3` does not touch the
  # transcript — so that case is reachable.
  defp read_media_file(full_path, original_path, caps, mounts, modality, context, size) do
    with :ok <- check_media_input(modality, context),
         :ok <- check_request_bytes(size, context),
         {:ok, modality, mime} <- MediaKind.detect(full_path, caps, mounts),
         {:ok, bytes} <- read_media_bytes(full_path, caps, mounts),
         {:ok, part} <- build_media_part(original_path, modality, mime, bytes, context) do
      {:ok, {:media, part}}
    else
      # The extension said media and `file` disagreed, so this is not media
      # after all. Fall back to the ordinary text read, which returns its own
      # "non-text" error for a binary file. A failed `file` check is NOT this
      # case: it comes back as an error and is surfaced, because treating
      # "could not tell" as "not media" would read an image as text.
      :text -> read_file_content(full_path, caps, mounts)
      {:error, _} = error -> error
    end
  end

  # Refuse a new image when attaching it would put the request over the byte
  # ceiling. Projected, not measured: one more image must not sail through a
  # conversation that is already just under the line.
  defp check_request_bytes(size, context) do
    # A tool invoked with no context — a direct call, or a test — has no message
    # list to measure, and nothing to project against.
    messages = if is_map(context), do: Map.get(context, :messages) || [], else: []
    already = RequestSize.bytes(messages)
    wire = RequestSize.media_wire_bytes(size)

    if RequestSize.within?(messages, wire) do
      :ok
    else
      {:error, request_bytes_error(already, wire, already + wire)}
    end
  end

  # States the arithmetic rather than a diagnosis: a text-full conversation can
  # reach the ceiling with no images in it at all, so "too many images are
  # already in context" would sometimes be false.
  defp request_bytes_error(already, wire, projected) do
    "file-read refused: attaching this image would put the request at " <>
      "~#{mb(projected)} — this conversation already carries ~#{mb(already)} and " <>
      "the image adds ~#{mb(wire)} — over the #{mb(RequestSize.max_bytes())} limit. " <>
      "No more images until you run context-compact, which replaces the " <>
      "conversation with a summary and drops any images in it. Text files can " <>
      "still be read."
  end

  defp mb(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  defp read_media_bytes(full_path, caps, mounts) do
    case Sandbox.read(full_path, caps, mounts) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> read_error(reason, full_path)
    end
  end

  # `data` carries no `data:` prefix; each provider encoder adds its own
  # framing. `new_media/1` re-validates every field, so a malformed read
  # becomes a tool error rather than a bad part on the wire.
  defp build_media_part(original_path, modality, mime, bytes, context) do
    Part.new_media(%{
      tool_call_id: Map.get(context, :tool_call_id),
      modality: modality,
      media_type: mime,
      data: Base.encode64(bytes),
      bytes: byte_size(bytes),
      path: original_path
    })
  end

  # Fail closed on the caller's model. The catalog gives three answers and
  # each gets its own refusal: a model that declares the modality is accepted,
  # one that declares input modalities *without* it is text-only, and one that
  # declares nothing at all is unknown — "declares nothing" is not a claim of
  # support, and the caller is told which of the two it is because the remedies
  # differ.
  defp check_media_input(modality, context) do
    case media_model(context) do
      nil ->
        {:error,
         "file-read cannot attach #{modality} data: this agent's model is not known, " <>
           "so Nest cannot tell whether it accepts #{modality} input."}

      model ->
        case declared_input(model, modality) do
          :supported -> :ok
          :unsupported -> {:error, media_unsupported_error(model, modality)}
          :unknown -> {:error, media_unknown_error(model, modality)}
        end
    end
  end

  defp media_model(context) do
    case Map.get(context, :client_config) do
      %{model: model} when is_binary(model) and model != "" -> model
      _ -> nil
    end
  end

  # What the merged catalog declares about `modality` for `model`:
  # `:supported` when some entry lists it, `:unsupported` when entries list
  # input modalities and none is this one, and `:unknown` when no entry lists
  # any (`multi_modal` is `nil` there — the provider published no modality
  # metadata we recognize, which is not the same as declaring text-only).
  #
  # Matched on name alone: `client_config` carries the model name but no
  # provider, and the catalog merges models from every provider by name. A
  # positive claim from any provider serving that model is the best evidence
  # available, so it wins over a negative one.
  defp declared_input(model, modality) do
    name = Atom.to_string(modality)

    declarations =
      Nest.Models.list()
      |> Enum.filter(&(&1["name"] == model))
      |> Enum.map(&declared_inputs/1)
      |> Enum.reject(&is_nil/1)

    cond do
      declarations == [] -> :unknown
      Enum.any?(declarations, &(name in &1)) -> :supported
      true -> :unsupported
    end
  end

  # The input modalities one catalog entry declares, or `nil` when it declares
  # none. `%{"input" => []}` is a declaration of no input modalities at all,
  # so it is `[]` here rather than `nil`.
  defp declared_inputs(%{"multi_modal" => %{"input" => inputs}}) when is_list(inputs), do: inputs
  defp declared_inputs(_entry), do: nil

  defp media_unsupported_error(model, modality) do
    "file-read refused: the model #{inspect(model)} declares text-only input — its " <>
      "models-list entry lists input modalities and #{modality} is not among them — and a " <>
      "#{modality} part is re-sent on every subsequent request, so attaching one would " <>
      "break every later turn until the conversation is compacted. " <>
      "Use a model whose models-list entry shows input: #{modality}, or inspect the file " <>
      "with shell-cmd instead (e.g. `file --mime-type <path>`)."
  end

  # Nothing anywhere declares this model's input modalities, so we refuse
  # without claiming it is text-only, and name both ways to settle it.
  defp media_unknown_error(model, modality) do
    "file-read refused: nothing declares whether the model #{inspect(model)} accepts " <>
      "#{modality} input — its provider publishes no modality metadata we can read — and " <>
      "a #{modality} part is re-sent on every subsequent request, so attaching one could " <>
      "break every later turn until the conversation is compacted. " <>
      "Settle it either by declaring the model's input statically " <>
      "(multi-modal = { input = [\"#{modality}\"] } in config.toml) or by setting " <>
      "probe-multimodal = true on that provider so Nest probes the model. " <>
      "In the meantime, inspect the file with shell-cmd instead " <>
      "(e.g. `file --mime-type <path>`)."
  end

  defp read_file_content(full_path, caps, mounts) do
    case Sandbox.read(full_path, caps, mounts) do
      {:ok, content} -> validate_utf8(content)
      {:error, reason} -> read_error(reason, full_path)
    end
  end

  defp too_large_error(size) do
    mb = div(size, 1_000_000)
    cap_mb = div(@max_read_file_bytes, 1_000_000)

    {:error,
     "File is #{mb} MB; file-read is capped at #{cap_mb} MB. " <>
       "Use file-inspect, or run shell-cmd directly on the file (e.g. " <>
       "`head -1 <path>`) for a partial read — never piped into head/tail."}
  end

  defp read_error(:read_permission_denied, path),
    do: {:error, "Not permitted to read file by sandbox caps: #{path}"}

  defp read_error(:enoent, path), do: {:error, "File not found: #{path}"}
  defp read_error(:eisdir, path), do: {:error, "Not a file: #{path}"}
  defp read_error(:sandbox_setup_failed, _path), do: {:error, @sandbox_setup_failed}
  defp read_error(:read_timeout, path), do: {:error, "Timed out reading file: #{path}"}
  defp read_error(:read_cancelled, path), do: {:error, "Read cancelled: #{path}"}
  defp read_error(reason, _path), do: {:error, "Cannot read file: #{inspect(reason)}"}

  defp validate_utf8(content) do
    if Sanitize.text?(content) do
      {:ok, content}
    else
      {:error,
       "File is non-text (invalid UTF-8 or binary data); file-read only returns text. " <>
         "Use file-inspect for metadata, or shell-cmd with hexdump/xxd for binary inspection."}
    end
  end

  defp write_file(path, content, mounts, context) do
    caps = caps_from_context(context)
    Logger.info("Tool file-write: #{path} (workspace: #{Mounts.workspace(mounts) || "none"})")

    with {:ok, full_path} <- Mounts.resolve(path, mounts) do
      case Sandbox.write(full_path, content, caps, mounts) do
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
  defp edit(args, mounts, context) do
    path = args["path"]
    old_text = args["old_text"]
    new_text = args["new_text"]
    replace_all = Map.get(args, "replace_all", false)

    caps = caps_from_context(context)
    Logger.info("Tool file-edit: #{path} (replace_all: #{replace_all})")

    with {:ok, full_path} <- Mounts.resolve(path, mounts),
         {:ok, current} <- read_file_via_shell(full_path, caps, mounts),
         {:ok, replacement_count, updated} <-
           compute_replacement(current, old_text, new_text, replace_all) do
      case Sandbox.write(full_path, updated, caps, mounts) do
        {:ok, _} -> {:ok, "Replaced #{replacement_count} occurrence(s) in #{path}"}
        {:error, reason} -> {:error, "Failed to write file: #{reason}"}
      end
    end
  end

  defp read_file_via_shell(full_path, caps, mounts) do
    case Sandbox.read(full_path, caps, mounts) do
      {:ok, content} -> {:ok, content}
      {:error, :read_permission_denied} -> {:error, "Not permitted to read file by sandbox caps"}
      {:error, :enoent} -> {:error, "File not found: #{full_path}"}
      {:error, reason} -> {:error, "Read failed: #{inspect(reason)}"}
    end
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

  # Every file tool addresses the same scratch spelling the agent is given
  # (`/tmp/<agent>/...`); `Sandbox.read/3` resolves it inside bwrap. Where that
  # spelling is stated (the agent's system prompt, not these descriptions)
  # lives in `Nest.Agents.Agent.SystemPrompt`.
  defp caps_from_context(%{caps: caps}) when is_map(caps), do: caps
  defp caps_from_context(_), do: Nest.Sandbox.default_caps()
end
