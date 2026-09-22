defmodule Nest.HardwareTest do
  use ExUnit.Case, async: true

  alias Nest.Hardware

  setup do
    root = Path.join(System.tmp_dir!(), "nest_hw_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  describe "hpu_device_paths/1" do
    test "detects the accel dir plus infiniband when HPUs are present", %{root: root} do
      File.mkdir_p!(Path.join(root, "accel"))
      File.write!(Path.join(root, "accel/accel0"), "")
      File.write!(Path.join(root, "accel/accel_controlD0"), "")
      File.mkdir_p!(Path.join(root, "infiniband"))
      File.write!(Path.join(root, "infiniband/uverbs0"), "")

      assert Hardware.hpu_device_paths(root) == [
               Path.join(root, "accel"),
               Path.join(root, "infiniband")
             ]
    end

    test "detects legacy /dev/hl* nodes and includes infiniband", %{root: root} do
      File.write!(Path.join(root, "hl0"), "")
      File.write!(Path.join(root, "hl1"), "")
      File.mkdir_p!(Path.join(root, "infiniband"))

      assert Hardware.hpu_device_paths(root) == [
               Path.join(root, "hl0"),
               Path.join(root, "hl1"),
               Path.join(root, "infiniband")
             ]
    end

    test "omits infiniband when no HPU node is present", %{root: root} do
      File.mkdir_p!(Path.join(root, "infiniband"))
      File.write!(Path.join(root, "infiniband/uverbs0"), "")

      assert Hardware.hpu_device_paths(root) == []
    end

    test "ignores an empty accel directory", %{root: root} do
      File.mkdir_p!(Path.join(root, "accel"))
      assert Hardware.hpu_device_paths(root) == []
    end

    test "returns an empty list for a bare dev root", %{root: root} do
      assert Hardware.hpu_device_paths(root) == []
    end
  end

  describe "habana_log_dir/1" do
    test "defaults to /var/log/habana_logs for nil or empty values" do
      assert Hardware.habana_log_dir(nil) == "/var/log/habana_logs"
      assert Hardware.habana_log_dir("") == "/var/log/habana_logs"
    end

    test "expands HABANA_LOGS and strips the trailing slash" do
      assert Hardware.habana_log_dir("/tmp/habana_logs/") == "/tmp/habana_logs"
    end
  end
end
