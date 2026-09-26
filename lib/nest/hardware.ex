defmodule Nest.Hardware do
  @moduledoc """
  Host hardware detection for the sandbox's HPU support.

  `hpu_device_paths/0` detects Habana Gaudi (HPU) devices on the host
  and returns their paths. `Nest.Sandbox` uses this to expose the host's
  `/dev` with `--dev-bind` (instead of a fresh minimal devtmpfs) and to
  overlay `habana_log_dir/0` read-write, since the driver logs there and
  the directory is read-only under the sandbox's root `--ro-bind`.

  Detection is directory-oriented on purpose:

  * `<dev>/accel` (the mainline accel subsystem) carries the `accelN`
    and `accel_controlDN` nodes.
  * `<dev>/hl*` covers the legacy Habana driver nodes.
  * `<dev>/infiniband` (RDMA uverbs) is included when an HPU node is
    present, so the whole device set is discoverable in one call.

  Tests pin `:hpu_device_paths` (see `config/test.exs`) to keep unit
  tests independent of the host's `/dev`; pass a `dev_root` to
  `hpu_device_paths/1` to exercise detection against a fixture tree.
  """

  @default_log_dir "/var/log/habana_logs"

  @doc """
  The host device paths whose presence means an HPU is available.

  Returns the configured `:hpu_device_paths` override when set,
  otherwise detects against `/dev` (see `hpu_device_paths/1`).
  """
  @spec hpu_device_paths() :: [String.t()]
  def hpu_device_paths do
    case Application.get_env(:nest, :hpu_device_paths) do
      nil -> hpu_device_paths("/dev")
      paths when is_list(paths) -> paths
    end
  end

  @doc """
  Detect HPU device paths beneath `dev_root`.

  Returns a sorted, de-duplicated list of paths: the accel directory
  and/or legacy `hl*` nodes, plus the infiniband directory when either
  is present. Returns `[]` when no HPU node exists.
  """
  @spec hpu_device_paths(String.t()) :: [String.t()]
  def hpu_device_paths(dev_root) do
    hpu = accel_path(dev_root) ++ legacy_paths(dev_root)

    if hpu == [] do
      []
    else
      (hpu ++ infiniband_paths(dev_root)) |> Enum.uniq() |> Enum.sort()
    end
  end

  @doc """
  The directory the Habana driver writes its logs to.

  Defaults to `#{@default_log_dir}` when `HABANA_LOGS` is unset or
  empty; otherwise the expanded value of `HABANA_LOGS`.
  """
  @spec habana_log_dir() :: String.t()
  def habana_log_dir do
    habana_log_dir(System.get_env("HABANA_LOGS"))
  end

  @doc """
  Normalize a raw `HABANA_LOGS` value (exposed for tests).
  """
  @spec habana_log_dir(String.t() | nil) :: String.t()
  def habana_log_dir(nil), do: @default_log_dir
  def habana_log_dir(""), do: @default_log_dir
  def habana_log_dir(path), do: Path.expand(path)

  defp accel_path(dev_root) do
    dir = Path.join(dev_root, "accel")

    case File.ls(dir) do
      {:ok, [_ | _]} -> [dir]
      _ -> []
    end
  end

  defp legacy_paths(dev_root) do
    dev_root |> Path.join("hl*") |> Path.wildcard()
  end

  defp infiniband_paths(dev_root) do
    dir = Path.join(dev_root, "infiniband")
    if File.dir?(dir), do: [dir], else: []
  end
end
