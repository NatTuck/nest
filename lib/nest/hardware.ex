defmodule Nest.Hardware do
  @moduledoc """
  Host hardware detection for the sandbox HPU bypass.

  `hpu_device_paths/0` detects Habana Gaudi (HPU) devices on the host
  and returns their paths. Used by `Nest.Sandbox.Bypass` to decide
  whether to skip bwrap entirely (HPU passthrough through bwrap did not
  work reliably). Nothing else in the sandbox consults this.

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
