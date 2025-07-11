# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ pkgs, ... }:

let
  # Create host-side debug scripts
  hostDebugScripts = pkgs.stdenv.mkDerivation {
    name = "gpu-passthrough-host-debug-scripts";

    buildCommand = ''
      mkdir -p $out/bin

      # Host GPU status script
      cat > $out/bin/debug-host-gpu-status <<'EOF'
      #!${pkgs.bash}/bin/bash
      # Check GPU passthrough status on host

      echo "=== Host GPU Passthrough Status ==="
      echo "Date: $(date)"
      echo ""

      echo "1. GPU Device Status:"
      if [ -d /sys/bus/platform/devices/17000000.gpu ]; then
          echo "   ✓ GPU device found at 17000000.gpu"
          
          if [ -L /sys/bus/platform/devices/17000000.gpu/driver ]; then
              DRIVER=$(basename $(readlink /sys/bus/platform/devices/17000000.gpu/driver))
              echo "   Driver: $DRIVER"
              if [ "$DRIVER" = "vfio-platform" ]; then
                  echo "   ✓ GPU bound to VFIO (ready for passthrough)"
              else
                  echo "   ✗ GPU not bound to VFIO - bound to $DRIVER"
                  echo "   Fix: echo 17000000.gpu > /sys/bus/platform/drivers/$DRIVER/unbind"
                  echo "        echo 17000000.gpu > /sys/bus/platform/drivers/vfio-platform/bind"
              fi
          else
              echo "   ✗ No driver bound to GPU"
          fi
      else
          echo "   ✗ GPU device not found"
      fi

      echo ""
      echo "2. BPMP Host Proxy:"
      if [ -e /dev/bpmp-host ]; then
          echo "   ✓ /dev/bpmp-host exists"
          ls -la /dev/bpmp-host
          
          # Check if microvm user can access it
          if getent group kvm >/dev/null 2>&1; then
              echo "   KVM group members: $(getent group kvm | cut -d: -f4)"
          fi
      else
          echo "   ✗ /dev/bpmp-host not found"
      fi

      echo ""
      echo "3. VFIO Devices:"
      if [ -d /dev/vfio ]; then
          echo "   ✓ VFIO subsystem active"
          ls -la /dev/vfio/
      else
          echo "   ✗ No VFIO devices"
      fi

      echo ""
      echo "4. GPU VM Status:"
      if systemctl is-active --quiet microvm@gpu-vm; then
          echo "   ✓ GPU VM is running"
          
          # Try multiple methods to find the VM process
          VM_PID=""
          
          # Method 1: Look for qemu-system-aarch64
          VM_PID=$(pgrep -f "qemu-system-aarch64.*gpu-vm" | head -1)
          
          # Method 2: Look through systemd service
          if [ -z "$VM_PID" ]; then
              VM_PID=$(systemctl show -p MainPID microvm@gpu-vm 2>/dev/null | cut -d= -f2)
              if [ "$VM_PID" = "0" ]; then
                  VM_PID=""
              fi
          fi
          
          # Method 3: Look for any qemu process
          if [ -z "$VM_PID" ]; then
              VM_PID=$(pgrep -f "qemu.*gpu" | head -1)
          fi
          
          if [ -n "$VM_PID" ] && [ "$VM_PID" != "0" ]; then
              echo "   PID: $VM_PID"
              if [ -e /proc/$VM_PID/status ]; then
                  echo "   Memory: $(awk '/VmRSS/ {print int($2/1024) "MB"}' /proc/$VM_PID/status)"
              fi
              
              # Check if QEMU has correct parameters
              if [ -e /proc/$VM_PID/cmdline ]; then
                  if tr '\0' ' ' < /proc/$VM_PID/cmdline | grep -q "mmio-base=0x64000000"; then
                      echo "   ✓ GPU VFIO has correct mmio-base"
                  else
                      echo "   ✗ GPU VFIO missing mmio-base parameter"
                  fi
              fi
          else
              echo "   ⚠ Could not find VM process PID"
          fi
          
          # Check for recent errors
          if ${pkgs.systemd}/bin/journalctl -u microvm@gpu-vm --since "2 minutes ago" | grep -q "error\|fail"; then
              echo ""
              echo "   Recent errors:"
              ${pkgs.systemd}/bin/journalctl -u microvm@gpu-vm --since "2 minutes ago" | grep -i "error\|fail" | tail -5 | sed 's/^/   /'
          fi
      else
          echo "   ✗ GPU VM is not running"
          echo "   Start with: systemctl start microvm@gpu-vm"
      fi

      echo ""
      echo "5. IOMMU Groups:"
      if [ -d /sys/kernel/iommu_groups ]; then
          echo "   Looking for GPU in IOMMU groups..."
          find /sys/kernel/iommu_groups -name "17000000.gpu" 2>/dev/null | while read gpu; do
              GROUP=$(basename $(dirname $(dirname $gpu)))
              echo "   GPU in IOMMU group $GROUP"
              echo "   Other devices in group:"
              ls /sys/kernel/iommu_groups/$GROUP/devices/ | sed 's/^/     /'
          done
      fi
      EOF

      # QEMU monitor script
      cat > $out/bin/debug-qemu-monitor <<'EOF'
      #!${pkgs.bash}/bin/bash
      # Access QEMU monitor for GPU VM

      echo "=== QEMU Monitor Access ==="
      echo ""

      # Try to find the socket in multiple locations
      SOCKET=""
      POSSIBLE_SOCKETS=(
          "/run/microvm/gpu-vm/qemu.sock"
          "/run/microvm/gpu-vm.sock"
          "/var/run/microvm/gpu-vm/qemu.sock"
          "/var/run/microvm/gpu-vm.sock"
      )

      echo "Looking for QEMU monitor socket..."
      for sock in "''${POSSIBLE_SOCKETS[@]}"; do
          if [ -S "$sock" ]; then
              SOCKET="$sock"
              echo "   ✓ Found at: $sock"
              break
          fi
      done

      # If not found, search for it
      if [ -z "$SOCKET" ]; then
          echo "   Searching /run for socket..."
          FOUND=$(find /run -name "*gpu-vm*.sock" -type s 2>/dev/null | head -1)
          if [ -n "$FOUND" ]; then
              SOCKET="$FOUND"
              echo "   ✓ Found at: $SOCKET"
          fi
      fi

      if [ -z "$SOCKET" ] || [ ! -S "$SOCKET" ]; then
          echo "✗ QEMU monitor socket not found"
          echo ""
          echo "Checking if VM is running:"
          systemctl is-active microvm@gpu-vm
          echo ""
          echo "You can try finding the socket with:"
          echo "  find /run -name '*.sock' -type s 2>/dev/null | grep -i vm"
          exit 1
      fi

      echo ""
      echo "Connecting to QEMU monitor at $SOCKET..."
      echo "Commands:"
      echo "  info qtree     - Show device tree"
      echo "  info mtree     - Show memory tree"
      echo "  info status    - VM status"
      echo "  quit           - Exit monitor"
      echo ""

      if command -v socat >/dev/null 2>&1; then
          ${pkgs.socat}/bin/socat - UNIX-CONNECT:$SOCKET
      else
          echo "✗ socat not available"
          echo "  Install with: nix-env -iA nixos.socat"
      fi
      EOF

      # BPMP host test script
      cat > $out/bin/debug-test-bpmp-host <<'EOF'
      #!${pkgs.bash}/bin/bash
      # Test BPMP host proxy functionality

      echo "=== BPMP Host Proxy Test ==="
      echo ""

      echo "1. BPMP host device:"
      if [ -e /dev/bpmp-host ]; then
          echo "   ✓ Device exists"
          ls -la /dev/bpmp-host
          
          # Check device node info
          MAJOR=$(stat -c "%t" /dev/bpmp-host)
          MINOR=$(stat -c "%T" /dev/bpmp-host)
          echo "   Major: 0x$MAJOR ($(printf "%d" 0x$MAJOR)), Minor: 0x$MINOR ($(printf "%d" 0x$MINOR))"
      else
          echo "   ✗ /dev/bpmp-host not found"
          exit 1
      fi

      echo ""
      echo "2. BPMP kernel driver:"
      if [ -d /sys/class/bpmp-host ]; then
          echo "   ✓ BPMP host class exists"
      fi

      echo ""
      echo "3. Recent BPMP kernel messages:"
      dmesg | grep -i bpmp | tail -10 | sed 's/^/   /'

      echo ""
      echo "4. QEMU process BPMP access:"
      # Try multiple methods to find VM PID
      VM_PID=""
      VM_PID=$(pgrep -f "qemu-system-aarch64.*gpu-vm" | head -1)
      if [ -z "$VM_PID" ]; then
          VM_PID=$(systemctl show -p MainPID microvm@gpu-vm 2>/dev/null | cut -d= -f2)
          if [ "$VM_PID" = "0" ]; then
              VM_PID=""
          fi
      fi
      if [ -z "$VM_PID" ]; then
          VM_PID=$(pgrep -f "qemu.*gpu" | head -1)
      fi

      if [ -n "$VM_PID" ] && [ "$VM_PID" != "0" ]; then
          echo "   Found VM PID: $VM_PID"
          echo "   Process: $(ps -p $VM_PID -o comm= 2>/dev/null || echo 'unknown')"
          echo "   Checking if QEMU has /dev/bpmp-host open..."
          if ls -la /proc/$VM_PID/fd/ 2>/dev/null | grep -q bpmp-host; then
              echo "   ✓ QEMU has BPMP device open"
          else
              echo "   ✗ QEMU does not have BPMP device open"
              echo "   Open file descriptors:"
              ls -la /proc/$VM_PID/fd/ 2>/dev/null | grep -E "dev|bpmp" | head -5 | sed 's/^/     /'
          fi
      else
          echo "   Could not find VM process"
          echo "   Checking if VM is running:"
          systemctl is-active microvm@gpu-vm
      fi
      EOF

      # VM logs monitor
      cat > $out/bin/debug-monitor-vm-logs <<'EOF'
      #!${pkgs.bash}/bin/bash
      # Monitor GPU VM logs in real-time

      echo "=== Monitoring GPU VM Logs ==="
      echo "Press Ctrl+C to exit"
      echo ""

      # Color codes
      RED='\033[0;31m'
      YELLOW='\033[1;33m'
      GREEN='\033[0;32m'
      NC='\033[0m'

      ${pkgs.systemd}/bin/journalctl -f -u microvm@gpu-vm | while read line; do
          if echo "$line" | grep -q "error\|Error\|ERROR\|fail\|Fail\|FAIL"; then
              echo -e "''${RED}$line''${NC}"
          elif echo "$line" | grep -q "warning\|Warning\|WARNING"; then
              echo -e "''${YELLOW}$line''${NC}"
          elif echo "$line" | grep -q "BPMP_GUEST:\|nvidia\|GPU"; then
              echo -e "''${GREEN}$line''${NC}"
          else
              echo "$line"
          fi
      done
      EOF

      # Make all scripts executable
      chmod +x $out/bin/*
    '';
  };
in
{
  # Add debug scripts to host system packages
  environment.systemPackages = [ hostDebugScripts ];

  # Create convenient aliases for host
  programs.bash.shellAliases = {
    # Quick access to host debug scripts
    "gpu-host-status" = "debug-host-gpu-status";
    "gpu-qemu-monitor" = "debug-qemu-monitor";
    "gpu-monitor-logs" = "debug-monitor-vm-logs";
    "gpu-test-bpmp" = "debug-test-bpmp-host";
  };
}
