defmodule Nest.HardwareTest do
  use ExUnit.Case, async: true

  alias Nest.Hardware

  setup do
    root = Path.join(System.tmp_dir!(), "nest_hw_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  describe "hpu_device_paths/2" do
    test "detects the accel dir plus infiniband when the Habana driver is loaded", %{root: root} do
      File.mkdir_p!(Path.join(root, "accel"))
      File.write!(Path.join(root, "accel/accel0"), "")
      File.write!(Path.join(root, "accel/accel_controlD0"), "")
      File.mkdir_p!(Path.join(root, "infiniband"))
      File.write!(Path.join(root, "infiniband/uverbs0"), "")

      assert Hardware.hpu_device_paths(root, true) == [
               Path.join(root, "accel"),
               Path.join(root, "infiniband")
             ]
    end

    test "ignores the accel dir when the Habana driver is not loaded or the dir is empty",
         %{root: root} do
      File.mkdir_p!(Path.join(root, "accel"))
      File.write!(Path.join(root, "accel/accel0"), "")

      assert Hardware.hpu_device_paths(root, false) == []

      File.rm!(Path.join(root, "accel/accel0"))
      assert Hardware.hpu_device_paths(root, true) == []
    end

    test "detects legacy /dev/hl* nodes regardless of the Habana driver, including infiniband",
         %{root: root} do
      File.write!(Path.join(root, "hl0"), "")
      File.write!(Path.join(root, "hl1"), "")
      File.mkdir_p!(Path.join(root, "infiniband"))

      expected = [
        Path.join(root, "hl0"),
        Path.join(root, "hl1"),
        Path.join(root, "infiniband")
      ]

      assert Hardware.hpu_device_paths(root, false) == expected
      assert Hardware.hpu_device_paths(root, true) == expected
    end

    test "omits infiniband when no HPU node is present", %{root: root} do
      File.mkdir_p!(Path.join(root, "infiniband"))
      File.write!(Path.join(root, "infiniband/uverbs0"), "")

      assert Hardware.hpu_device_paths(root, true) == []
    end

    test "returns an empty list for a bare dev root", %{root: root} do
      assert Hardware.hpu_device_paths(root, true) == []
      assert Hardware.hpu_device_paths(root, false) == []
    end
  end

  describe "habana_log_dir/1" do
    test "uses the default when unset or empty" do
      assert Hardware.habana_log_dir(nil) == "/var/log/habana_logs"
      assert Hardware.habana_log_dir("") == "/var/log/habana_logs"
    end

    test "expands a configured HABANA_LOGS path" do
      assert Hardware.habana_log_dir("/var/log/habana_logs/") == "/var/log/habana_logs"
      assert Hardware.habana_log_dir("/custom/logs") == "/custom/logs"
    end
  end

  describe "ensure_habana_log_dir/2" do
    test "creates the log dir when an HPU is present", %{root: root} do
      log_dir = Path.join(root, "habana_logs")
      refute File.exists?(log_dir)

      assert Hardware.ensure_habana_log_dir(["/dev/accel"], log_dir) == :ok
      assert File.dir?(log_dir)
    end

    test "is a no-op without an HPU", %{root: root} do
      log_dir = Path.join(root, "habana_logs")

      assert Hardware.ensure_habana_log_dir([], log_dir) == :ok
      refute File.exists?(log_dir)
    end
  end
end
