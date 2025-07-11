# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ pkgs, ... }:

{
  # Systemd service to fix NVIDIA driver binding
  systemd.services.nvidia-driver-fix = {
    description = "Fix NVIDIA driver binding by unbinding gk20a";
    after = [ "multi-user.target" ];
    wantedBy = [ "multi-user.target" ];
    # Run before ollama service
    before = [ "ollama.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nvidia-driver-fix" ''
        set -euxo pipefail

        GPU_PATH="/sys/bus/platform/devices/platform-bus@70000000:gpu@64000000"

        # Wait for device to appear
        echo "Waiting for GPU device..."
        for i in {1..30}; do
          [ -d "$GPU_PATH" ] && break
          sleep 1
        done

        if [ ! -d "$GPU_PATH" ]; then
          echo "ERROR: GPU device not found after 30 seconds"
          exit 1
        fi

        # Unbind any driver that's attached
        if [ -L "$GPU_PATH/driver" ]; then
          DRIVER=$(basename $(readlink "$GPU_PATH/driver"))
          echo "GPU currently bound to: $DRIVER"
          
          # Force unbind using the proper path
          DRIVER_PATH=$(readlink -f "$GPU_PATH/driver")
          if [ -f "$DRIVER_PATH/unbind" ]; then
            echo "Unbinding $DRIVER..."
            echo "platform-bus@70000000:gpu@64000000" > "$DRIVER_PATH/unbind" || {
              echo "Failed to unbind, trying alternate method..."
              echo -n "platform-bus@70000000:gpu@64000000" > "$DRIVER_PATH/unbind" || true
            }
            sleep 2
          fi
        fi

        # Verify unbind worked
        if [ -L "$GPU_PATH/driver" ]; then
          echo "WARNING: Driver still bound after unbind attempt"
        else
          echo "Successfully unbound driver"
        fi

        # Load NVIDIA module
        echo "Loading NVIDIA kernel module..."
        ${pkgs.kmod}/bin/modprobe nvidia || {
          echo "Failed to load NVIDIA module, checking dmesg..."
          dmesg | tail -20 | grep -E "nvidia|NVRM"
          exit 1
        }

        # Create device nodes if needed
        if [ ! -e /dev/nvidia0 ]; then
          echo "Creating NVIDIA device nodes..."
          mknod /dev/nvidia0 c 195 0 || true
          mknod /dev/nvidiactl c 195 255 || true
          mknod /dev/nvidia-uvm c 511 0 || true
          mknod /dev/nvidia-uvm-tools c 511 1 || true
          chown root:video /dev/nvidia* || true
          chmod 0660 /dev/nvidia* || true
        fi

        echo "NVIDIA driver fix complete"
      '';
    };
  };

  # Also create a manual script for testing
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "fix-nvidia-driver" ''
      echo "Fixing NVIDIA driver binding..."
      systemctl restart nvidia-driver-fix
      systemctl status nvidia-driver-fix --no-pager
    '')
  ];
}
