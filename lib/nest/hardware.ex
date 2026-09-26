defmodule Nest.Hardware do
  @moduledoc """
  Host hardware detection for the sandbox's HPU (Habana Gaudi) support.

  `hpu_device_paths/0` detects HPU devices on the host and returns their
  paths. `Nest.Sandbox` uses this to choose the HPU sandbox path: the
  host's `/dev` is bound with `--dev-bind` (a fresh devtmpfs has no
  accelerator nodes) and the Habana log directory is bound read-write,
  since the driver logs there and the path is read-only under the root
  `--ro-bind`.

  Detection requires proof the host is actually an HPU host, because the
  `/dev/accel` subsystem is shared with other accelerators (AMD XDNA,
  Intel VPU, ...):

  * `<dev>/hl*` — the legacy Habana driver nodes. Their presence is
    Habana-specific, so they count on their own.
  * `<dev>/accel` — the generic accel subsystem. It only counts when the
    Habana driver or module is loaded (see `habanalabs_loaded?/0`).
  * `<dev>/infiniband` (RDMA uverbs) is included when an HPU node is
    present, so the whole device set is discoverable in one call.

  Tests pin `:hpu_device_paths` (see `config/test.exs`) to keep unit
  tests independent of the host's `/dev`; pass a `dev_root` and the
  `habana_accel?` flag to `hpu_device_paths/2` to exercise detection
  against a fixture tree.
  """

  @default_log_dir "/var/log/habana_logs"

  @doc """
  The host device paths whose presence means an HPU is available.

  Returns the configured `:hpu_device_paths` override when set,
  otherwise detects against `/dev` (see `hpu_device_paths/2`).
  """
  @spec hpu_device_paths() :: [String.t()]
  def hpu_device_paths do
    case Application.get_env(:nest, :hpu_device_paths) do
      nil -> hpu_device_paths("/dev", habanalabs_loaded?())
      paths when is_list(paths) -> paths
    end
  end

  @doc """
  Detect HPU device paths beneath `dev_root`.

  `habana_accel?` says whether the Habana driver is loaded; the generic
  `<dev>/accel` directory only counts as an HPU when it is `true`.
  Legacy `hl*` nodes always count. Returns a sorted, de-duplicated list:
  the accel directory and/or `hl*` nodes, plus the infiniband directory
  when either is present. Returns `[]` when no HPU node exists.
  """
  @spec hpu_device_paths(String.t(), boolean()) :: [String.t()]
  def hpu_device_paths(dev_root, habana_accel?) do
    hpu = accel_paths(dev_root, habana_accel?) ++ legacy_paths(dev_root)

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

  @doc """
  Ensure the Habana log directory exists on the host.

  Only creates anything when `hpu_device_paths` is non-empty — i.e. we
  have proof we're on an HPU host. A no-op on any other host, so a
  non-HPU system never gets a stray `/var/log/habana_logs`.
  """
  @spec ensure_habana_log_dir([String.t()], String.t()) :: :ok
  def ensure_habana_log_dir([], _log_dir), do: :ok

  def ensure_habana_log_dir(_hpu_device_paths, log_dir) do
    File.mkdir_p!(log_dir)
    :ok
  end

  # `/dev/accel` hosts AMD XDNA, Intel VPU, and other accelerators too,
  # so its presence alone is not proof of an HPU. Require Habana's
  # driver (or its module) to be loaded.
  defp habanalabs_loaded? do
    File.dir?("/sys/module/habanalabs") or File.dir?("/sys/bus/pci/drivers/habanalabs")
  end

  defp accel_paths(dev_root, true) do
    dir = Path.join(dev_root, "accel")

    case File.ls(dir) do
      {:ok, [_ | _]} -> [dir]
      _ -> []
    end
  end

  defp accel_paths(_dev_root, false), do: []

  defp legacy_paths(dev_root) do
    dev_root |> Path.join("hl*") |> Path.wildcard()
  end

  defp infiniband_paths(dev_root) do
    dir = Path.join(dev_root, "infiniband")
    if File.dir?(dir), do: [dir], else: []
  end
end
