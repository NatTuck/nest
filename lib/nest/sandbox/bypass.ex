defmodule Nest.Sandbox.Bypass do
  @moduledoc """
  Decides whether to skip bwrap sandboxing for a given caps map.

  bwrap is skipped when all of these are true:
  1. HPU (Habana Gaudi) devices are detected on the host
  2. The process is inside a Docker container
  3. The caps include a writable workspace (`":workspace"` in
     `caps["fs"]["write"]`) — i.e. a build/act mode, not plan

  When skipped, the command runs under a minimal bwrap mount instead
  (`Nest.Sandbox.build_bypass/2`): the host root is bound read-write
  and the host's `/dev` re-bound, so nothing is unshared and HPU
  devices, network, and IPC are the container's; only the per-agent
  scratch dir is overlaid at `/tmp`. Read/write/network caps do not
  apply — the container itself is the sandbox. Plan mode (no writable
  workspace) is never bypassed.
  """

  alias Nest.Hardware

  @doc """
  Returns true when bwrap should be bypassed for the given caps.
  """
  @spec bypass?(map()) :: boolean()
  def bypass?(%{"fs" => %{"write" => writes}} = caps) do
    # TEMP: forced off to test the full bwrap sandbox on HPU.
    # Revert by deleting the leading `false and`.
    false and ":workspace" in writes and bypass?(caps, hpu_detected?(), inside_docker?())
  end

  def bypass?(_caps), do: false

  @doc false
  @spec bypass?(map(), boolean(), boolean()) :: boolean()
  def bypass?(%{"fs" => %{"write" => writes}}, hpu?, docker?) do
    ":workspace" in writes and hpu? and docker?
  end

  def bypass?(_caps, _hpu?, _docker?), do: false

  defp hpu_detected? do
    Hardware.hpu_device_paths() != []
  end

  defp inside_docker? do
    File.exists?("/.dockerenv") or File.exists?("/run/.containerenv") or container_markers?()
  end

  # Docker drops /.dockeren and podman /run/.containerenv; containerd
  # (what this host uses) drops neither, so fall back to the runtime
  # name in cgroup/mountinfo.
  defp container_markers? do
    Enum.any?(["/proc/1/cgroup", "/proc/self/mountinfo"], fn path ->
      case File.read(path) do
        {:ok, body} -> Regex.match?(~r/docker|containerd|kubepods|libpod|podman/, body)
        _ -> false
      end
    end)
  end
end
