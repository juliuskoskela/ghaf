# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ pkgs, ... }:

let
  # Create debug scripts as a package
  debugScripts = pkgs.stdenv.mkDerivation {
    name = "gpu-passthrough-debug-scripts";

    buildCommand = ''
      mkdir -p $out/bin

      # GPU Passthrough Comprehensive Debug Script
      cat > $out/bin/debug-gpu-comprehensive <<'EOF'
      #!${pkgs.bash}/bin/bash
      # Comprehensive GPU Passthrough Debug Script

      # Color codes for output
      RED='\033[0;31m'
      GREEN='\033[0;32m'
      YELLOW='\033[1;33m'
      BLUE='\033[0;34m'
      NC='\033[0m' # No Color

      echo -e "''${BLUE}=== GPU Passthrough Comprehensive Debug ===''${NC}"
      echo "Date: $(date)"
      echo "Hostname: $(hostname)"
      echo ""

      # Function to check status
      check_status() {
          if [ "$1" -eq 0 ]; then
              echo -e "''${GREEN}✓''${NC} $2"
          else
              echo -e "''${RED}✗''${NC} $2"
          fi
      }

      # Detect if we're in host or VM
      if [ -d /sys/bus/platform/devices/17000000.gpu ]; then
          echo -e "''${BLUE}System: HOST''${NC}"
          echo ""
          
          echo -e "''${YELLOW}1. GPU VFIO Binding:''${NC}"
          if [ -e /sys/bus/platform/devices/17000000.gpu/driver ]; then
              DRIVER=$(basename $(readlink /sys/bus/platform/devices/17000000.gpu/driver))
              echo "   GPU driver: $DRIVER"
              [ "$DRIVER" = "vfio-platform" ] && check_status 0 "GPU bound to VFIO" || check_status 1 "GPU not bound to VFIO (bound to $DRIVER)"
          else
              check_status 1 "No driver bound to GPU"
          fi
          echo ""
          
          echo -e "''${YELLOW}2. BPMP Host Configuration:''${NC}"
          if [ -e /dev/bpmp-host ]; then
              check_status 0 "/dev/bpmp-host exists"
              ls -la /dev/bpmp-host | sed 's/^/   /'
          else
              check_status 1 "/dev/bpmp-host not found"
          fi
          
          # Check kernel config
          if zgrep -q "CONFIG_TEGRA_BPMP_HOST_PROXY=y" /proc/config.gz 2>/dev/null; then
              check_status 0 "Host kernel has BPMP host proxy enabled"
          else
              check_status 1 "Host kernel missing BPMP host proxy"
          fi
          echo ""
          
          echo -e "''${YELLOW}3. GPU VM Status:''${NC}"
          if systemctl is-active --quiet microvm@gpu-vm; then
              check_status 0 "GPU VM is running"
              
              # Check QEMU command for critical parameters
              QEMU_CMD=$(ps aux | grep qemu-system-aarch64 | grep -v grep)
              
              echo "   Checking QEMU parameters:"
              if echo "$QEMU_CMD" | grep -q "vfio-platform,host=17000000.gpu,mmio-base=0x64000000"; then
                  check_status 0 "GPU VFIO device has mmio-base=0x64000000"
              else
                  check_status 1 "GPU VFIO device missing mmio-base parameter"
              fi
              
              # Extract VM PID for monitoring
              VM_PID=$(pgrep -f "qemu-system-aarch64.*gpu-vm")
              if [ -n "$VM_PID" ]; then
                  echo "   VM PID: $VM_PID"
              fi
          else
              check_status 1 "GPU VM is not running"
          fi
          echo ""
          
      elif [ -d /sys/bus/platform/devices/platform-bus@70000000 ]; then
          echo -e "''${BLUE}System: GPU VM''${NC}"
          echo ""
          
          echo -e "''${YELLOW}1. Kernel Configuration:''${NC}"
          if zgrep -q "CONFIG_TEGRA_BPMP_GUEST_PROXY=y" /proc/config.gz 2>/dev/null; then
              check_status 0 "Guest kernel has BPMP guest proxy enabled"
          else
              check_status 1 "Guest kernel missing BPMP guest proxy"
          fi
          
          if zgrep -q "CONFIG_TEGRA_BPMP_HOST_PROXY=y" /proc/config.gz 2>/dev/null; then
              check_status 1 "Guest kernel incorrectly has HOST proxy enabled"
          else
              check_status 0 "Guest kernel correctly has HOST proxy disabled"
          fi
          echo ""
          
          echo -e "''${YELLOW}2. GPU Device Status:''${NC}"
          GPU_PATH="/sys/bus/platform/devices/platform-bus@70000000:gpu@64000000"
          if [ -d "$GPU_PATH" ]; then
              check_status 0 "GPU device found at platform-bus@70000000:gpu@64000000"
              
              # Check driver binding
              if [ -e "$GPU_PATH/driver" ]; then
                  DRIVER=$(basename $(readlink "$GPU_PATH/driver"))
                  echo "   Driver: $DRIVER"
                  case "$DRIVER" in
                      "gk20a")
                          check_status 1 "WARNING: gk20a driver bound (should be blacklisted)"
                          echo -e "   ''${YELLOW}ℹ''${NC} Add 'boot.blacklistedKernelModules = [ \"gk20a\" \"nouveau\" ];' to VM config"
                          ;;
                      "nvidia")
                          check_status 0 "NVIDIA driver bound"
                          ;;
                      *)
                          echo "   Unknown driver: $DRIVER"
                          ;;
                  esac
              else
                  check_status 0 "No driver bound (ready for NVIDIA driver)"
              fi
              
              # Show device info
              echo "   Modalias: $(cat $GPU_PATH/modalias 2>/dev/null)"
              echo "   Compatible: $(cat $GPU_PATH/of_node/compatible 2>/dev/null | tr '\0' ' ')"
          else
              check_status 1 "GPU device not found"
              echo "   Available platform devices:"
              ls /sys/bus/platform/devices/ | grep -E "platform-bus|gpu" | sed 's/^/     /'
          fi
          echo ""
          
          echo -e "''${YELLOW}3. NVIDIA Driver Status:''${NC}"
          # Check for NVIDIA devices
          if ls /dev/nvidia* 2>/dev/null | grep -q nvidia; then
              check_status 0 "NVIDIA devices found:"
              ls -la /dev/nvidia* 2>/dev/null | sed 's/^/     /'
          else
              check_status 1 "No NVIDIA devices in /dev/"
          fi
          
          # Check loaded modules
          echo "   Loaded modules:"
          lsmod | grep -E "nvidia|gk20a|nouveau" | sed 's/^/     /' || echo "     No NVIDIA/GPU modules loaded"
          echo ""
          
          echo -e "''${YELLOW}4. BPMP Status:''${NC}"
          if [ -e /dev/bpmp-guest ]; then
              check_status 0 "/dev/bpmp-guest exists"
              ls -la /dev/bpmp-guest | sed 's/^/   /'
          else
              check_status 1 "/dev/bpmp-guest not found"
          fi
          
          echo ""
          echo -e "''${YELLOW}5. Recent NVIDIA Messages:''${NC}"
          dmesg | grep -E "NVRM:|nvidia|gpu@64000000" | tail -10 | sed 's/^/   /'
      else
          echo "Unable to determine system type"
      fi

      echo ""
      echo -e "''${BLUE}=== Quick Summary ===''${NC}"
      if [ -d /sys/bus/platform/devices/17000000.gpu ]; then
          echo "Host: Check that GPU is bound to vfio-platform and VM is running"
      elif [ -d "$GPU_PATH" ]; then
          if [ -e "$GPU_PATH/driver" ] && [ "$(basename $(readlink $GPU_PATH/driver 2>/dev/null))" = "gk20a" ]; then
              echo "VM: GPU claimed by gk20a - need to blacklist gk20a driver"
          elif [ ! -e "$GPU_PATH/driver" ]; then
              echo "VM: GPU device present with no driver bound - NVIDIA driver should be able to claim it"
          elif [ "$(basename $(readlink $GPU_PATH/driver 2>/dev/null))" = "nvidia" ]; then
              echo "VM: GPU claimed by NVIDIA driver - check nvidia-smi"
          fi
      else
          echo "VM: GPU device not found - check device tree and QEMU configuration"
      fi
      EOF

      # Check gk20a driver script
      cat > $out/bin/debug-check-gk20a <<'EOF'
      #!${pkgs.bash}/bin/bash
      # Check gk20a driver status and why blacklist might not be working

      echo "=== gk20a Driver Investigation ==="
      echo ""

      echo "1. Checking if gk20a is built-in or module:"
      if zgrep -q "CONFIG_TEGRA_GK20A=y" /proc/config.gz 2>/dev/null; then
          echo "   ✗ gk20a is built into kernel (CONFIG_TEGRA_GK20A=y)"
          echo "   This means blacklisting won't work!"
      elif zgrep -q "CONFIG_TEGRA_GK20A=m" /proc/config.gz 2>/dev/null; then
          echo "   ✓ gk20a is a module (CONFIG_TEGRA_GK20A=m)"
          echo "   Blacklisting should work"
      else
          echo "   ℹ gk20a not found in kernel config"
      fi

      echo ""
      echo "2. Checking loaded modules:"
      if lsmod | grep -q gk20a; then
          echo "   ✗ gk20a module is loaded"
          lsmod | grep gk20a
      else
          echo "   ✓ gk20a module not loaded"
      fi

      echo ""
      echo "3. Checking blacklist configuration:"
      for f in /etc/modprobe.d/*.conf; do
          if [ -f "$f" ] && grep -q "gk20a\|nouveau" "$f"; then
              echo "   Found in $f:"
              grep -E "gk20a|nouveau" "$f" | sed 's/^/     /'
          fi
      done

      echo ""
      echo "4. Checking device binding:"
      GPU_PATH="/sys/bus/platform/devices/platform-bus@70000000:gpu@64000000"
      if [ -L "$GPU_PATH/driver" ]; then
          DRIVER=$(basename $(readlink "$GPU_PATH/driver"))
          echo "   Current driver: $DRIVER"
          
          echo ""
          echo "5. Trying to unbind gk20a:"
          echo "platform-bus@70000000:gpu@64000000" | ${pkgs.coreutils}/bin/tee /sys/bus/platform/drivers/gk20a/unbind
          
          sleep 1
          
          if [ -L "$GPU_PATH/driver" ]; then
              echo "   ✗ Still bound to: $(basename $(readlink $GPU_PATH/driver))"
          else
              echo "   ✓ Successfully unbound!"
          fi
      fi
      EOF

      # BPMP verification script
      cat > $out/bin/debug-verify-bpmp <<'EOF'
      #!${pkgs.bash}/bin/bash
      # Verify BPMP is actually working

      echo "=== BPMP Functionality Test ==="
      echo ""

      echo "1. BPMP device check:"
      ls -la /dev/bpmp-guest 2>/dev/null || echo "   ✗ /dev/bpmp-guest not found"

      echo ""
      echo "2. BPMP memory region (0x090c0000):"
      if grep -q "090c0000" /proc/iomem; then
          echo "   ✓ BPMP region in iomem:"
          grep "090c0000" /proc/iomem | sed 's/^/   /'
      else
          echo "   ✗ BPMP region not in iomem"
      fi

      echo ""
      echo "3. Testing BPMP MMIO access:"
      if command -v busybox >/dev/null 2>&1; then
          # Try to read BPMP signature register
          echo "   Reading BPMP signature (should be non-zero):"
          SIGNATURE=$(${pkgs.busybox}/bin/busybox devmem 0x090c0000 32 2>&1)
          if [[ "$SIGNATURE" =~ ^0x[0-9a-fA-F]+$ ]]; then
              echo "   Signature: $SIGNATURE"
              if [ "$SIGNATURE" != "0x00000000" ] && [ "$SIGNATURE" != "0xFFFFFFFF" ]; then
                  echo "   ✓ BPMP MMIO appears functional"
              else
                  echo "   ⚠ Suspicious signature value"
              fi
          else
              echo "   ✗ Failed to read: $SIGNATURE"
          fi
      fi

      echo ""
      echo "4. Platform device for BPMP:"
      BPMP_DEV="/sys/bus/platform/devices/platform-bus@70000000:nvidia_bpmp_guest@90c0000"
      if [ -d "$BPMP_DEV" ]; then
          echo "   ✓ BPMP platform device exists"
          if [ -L "$BPMP_DEV/driver" ]; then
              echo "   Driver: $(basename $(readlink $BPMP_DEV/driver))"
          else
              echo "   ✗ No driver bound to BPMP device"
          fi
      else
          echo "   ✗ BPMP platform device not found"
          echo "   Looking for BPMP devices:"
          ls /sys/bus/platform/devices/ | grep -i bpmp | sed 's/^/   /'
      fi

      echo ""
      echo "5. Check if BPMP proxy is working:"
      if dmesg | grep -q "BPMP_GUEST:"; then
          echo "   ✓ BPMP guest proxy active (found debug messages)"
          echo "   Recent messages:"
          dmesg | grep "BPMP_GUEST:" | tail -3 | sed 's/^/   /'
      else
          echo "   ⚠ No BPMP guest proxy debug messages found"
      fi

      echo ""
      echo "6. BPMP kernel messages:"
      dmesg | grep -i bpmp | tail -10 | sed 's/^/   /'
      EOF

      # NVIDIA driver debug script
      cat > $out/bin/debug-nvidia-load <<'EOF'
      #!${pkgs.bash}/bin/bash
      # Debug NVIDIA driver loading

      echo "=== NVIDIA Driver Load Debug ==="
      echo ""

      # First ensure gk20a is not bound
      GPU_PATH="/sys/bus/platform/devices/platform-bus@70000000:gpu@64000000"
      if [ -L "$GPU_PATH/driver" ]; then
          DRIVER=$(basename $(readlink "$GPU_PATH/driver"))
          if [ "$DRIVER" = "gk20a" ]; then
              echo "1. Unbinding gk20a first..."
              echo "platform-bus@70000000:gpu@64000000" > /sys/bus/platform/drivers/gk20a/unbind 2>&1
              sleep 1
          fi
      fi

      echo "2. Current module state:"
      lsmod | grep -E "nvidia|gk20a" || echo "   No GPU modules loaded"

      echo ""
      echo "3. Kernel ring buffer before load:"
      dmesg -C  # Clear dmesg

      echo "4. Loading NVIDIA module with debug..."
      # Try to load with verbose kernel messages
      echo 8 > /proc/sys/kernel/printk  # Maximum verbosity
      ${pkgs.kmod}/bin/modprobe nvidia NVreg_EnableDbgBreakpoint=0 NVreg_DebugLevel=0x3f 2>&1 || {
          echo "   ✗ Module load failed"
      }

      echo ""
      echo "5. Kernel messages during load:"
      dmesg | grep -v "audit:" | sed 's/^/   /'

      echo ""
      echo "6. Check what NVIDIA module did:"
      if lsmod | grep -q "^nvidia "; then
          echo "   ✓ NVIDIA module in memory"
          echo "   Module info:"
          lsmod | grep nvidia | sed 's/^/   /'
      else
          echo "   ✗ NVIDIA module not loaded"
      fi

      echo ""
      echo "7. Final GPU binding status:"
      if [ -L "$GPU_PATH/driver" ]; then
          echo "   GPU bound to: $(basename $(readlink $GPU_PATH/driver))"
      else
          echo "   GPU not bound to any driver"
      fi

      # Reset kernel log level
      echo 4 > /proc/sys/kernel/printk
      EOF

      # BPMP-NVIDIA communication debug script
      cat > $out/bin/debug-bpmp-nvidia <<'EOF'
      #!${pkgs.bash}/bin/bash
      # Debug BPMP-NVIDIA communication issue

      echo "=== BPMP-NVIDIA Communication Debug ==="
      echo ""

      echo "1. Check GPU device tree properties:"
      GPU_DT="/proc/device-tree/platform-bus@70000000/gpu@64000000"
      if [ -d "$GPU_DT" ]; then
          echo "   nvidia,bpmp property:"
          if [ -f "$GPU_DT/nvidia,bpmp" ]; then
              echo "   ✓ Has nvidia,bpmp property"
              od -x "$GPU_DT/nvidia,bpmp" | head -2 | sed 's/^/   /'
          else
              echo "   ✗ Missing nvidia,bpmp property"
          fi
          
          echo ""
          echo "   All properties:"
          ls "$GPU_DT/" | grep -v "^name$" | head -10 | sed 's/^/   /'
      fi

      echo ""
      echo "2. BPMP node in device tree:"
      if [ -d /proc/device-tree/bpmp ]; then
          echo "   ✓ /proc/device-tree/bpmp exists"
          ls /proc/device-tree/bpmp/ | head -10 | sed 's/^/   /'
      else
          echo "   ✗ No /proc/device-tree/bpmp"
          echo "   Searching for BPMP nodes:"
          find /proc/device-tree -name "*bpmp*" -type d 2>/dev/null | sed 's/^/   /'
      fi

      echo ""
      echo "3. BPMP device location:"
      find /sys/devices -name "*bpmp*" -type d 2>/dev/null | grep -v "/sys/devices/virtual" | head -10 | sed 's/^/   /'

      echo ""
      echo "4. Check GPU's BPMP reference:"
      GPU_BPMP="/sys/devices/platform/platform-bus@70000000/platform-bus@70000000:gpu@64000000/supplier:platform:bpmp"
      if [ -L "$GPU_BPMP" ]; then
          echo "   ✓ GPU has BPMP supplier link"
          echo "   Points to: $(readlink -f $GPU_BPMP)"
      else
          echo "   ✗ No BPMP supplier link from GPU"
      fi

      echo ""
      echo "5. Related error messages:"
      dmesg | grep -B2 -A2 "failed to get bpmp data" | sed 's/^/   /'
      EOF

      # Quick test script
      cat > $out/bin/debug-quick-test <<'EOF'
      #!${pkgs.bash}/bin/bash
      # Quick GPU Test Script - Run after deployment to verify GPU passthrough

      echo "=== Quick GPU Passthrough Test ==="
      echo ""

      # Function to run on host
      test_host() {
          echo "1. Checking GPU VFIO binding..."
          if [ -L /sys/bus/platform/devices/17000000.gpu/driver ]; then
              DRIVER=$(basename $(readlink /sys/bus/platform/devices/17000000.gpu/driver))
              echo "   GPU driver: $DRIVER"
              [ "$DRIVER" = "vfio-platform" ] && echo "   ✓ PASS" || echo "   ✗ FAIL: Expected vfio-platform"
          else
              echo "   ✗ FAIL: No driver bound"
          fi
          
          echo ""
          echo "2. Checking VM status..."
          if systemctl is-active --quiet microvm@gpu-vm; then
              echo "   ✓ GPU VM is running"
              
              # Quick check for BPMP messages
              if ${pkgs.systemd}/bin/journalctl -u microvm@gpu-vm --since "1 minute ago" | grep -q "BPMP_GUEST:"; then
                  echo "   ✓ BPMP communication active"
              else
                  echo "   ⚠ No recent BPMP messages"
              fi
          else
              echo "   ✗ GPU VM not running"
          fi
          
          echo ""
          echo "Next: SSH to gpu-vm and run this script there"
      }

      # Function to run in VM
      test_vm() {
          echo "1. Checking GPU device..."
          GPU_PATH="/sys/bus/platform/devices/platform-bus@70000000:gpu@64000000"
          if [ -d "$GPU_PATH" ]; then
              echo "   ✓ GPU device found"
              
              if [ -L "$GPU_PATH/driver" ]; then
                  DRIVER=$(basename $(readlink "$GPU_PATH/driver"))
                  echo "   Driver: $DRIVER"
                  
                  case "$DRIVER" in
                      "gk20a")
                          echo "   ✗ FAIL: gk20a driver bound (should be blacklisted)"
                          echo "   Fix: Rebuild with driver blacklist"
                          ;;
                      "nvidia")
                          echo "   ✓ PASS: NVIDIA driver bound"
                          ;;
                      *)
                          echo "   ? Unknown driver: $DRIVER"
                          ;;
                  esac
              else
                  echo "   ✓ No driver bound (ready for NVIDIA)"
              fi
          else
              echo "   ✗ GPU device not found"
          fi
          
          echo ""
          echo "2. Checking BPMP..."
          if [ -e /dev/bpmp-guest ]; then
              echo "   ✓ /dev/bpmp-guest exists"
          else
              echo "   ✗ /dev/bpmp-guest missing"
          fi
          
          echo ""
          echo "3. Checking NVIDIA devices..."
          if ls /dev/nvidia* 2>/dev/null | grep -q nvidia; then
              echo "   ✓ NVIDIA devices found:"
              ls /dev/nvidia* 2>/dev/null | sed 's/^/     /'
              
              echo ""
              echo "4. Testing nvidia-smi..."
              if command -v nvidia-smi >/dev/null 2>&1; then
                  if nvidia-smi >/dev/null 2>&1; then
                      echo "   ✓ nvidia-smi works!"
                      nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | sed 's/^/     /'
                  else
                      echo "   ✗ nvidia-smi failed"
                  fi
              else
                  echo "   ✗ nvidia-smi not found"
              fi
          else
              echo "   ✗ No NVIDIA devices"
              echo "   Check: dmesg | grep -i nvrm"
          fi
          
          echo ""
          echo "5. Testing Ollama..."
          if systemctl is-active --quiet ollama; then
              echo "   ✓ Ollama service running"
              
              if command -v ollama >/dev/null 2>&1; then
                  echo "   Testing GPU detection..."
                  if timeout 5 ollama list 2>&1 | grep -q "NAME"; then
                      echo "   ✓ Ollama responsive"
                  else
                      echo "   ⚠ Ollama not responding"
                  fi
              fi
          else
              echo "   ✗ Ollama service not running"
          fi
      }

      # Detect system and run appropriate test
      if [ -d /sys/bus/platform/devices/17000000.gpu ]; then
          echo "System: HOST"
          echo ""
          test_host
      elif [ -d /sys/bus/platform/devices/platform-bus@70000000 ]; then
          echo "System: GPU VM"
          echo ""
          test_vm
      else
          echo "Unable to determine system type"
      fi

      echo ""
      echo "=== Test Complete ==="
      EOF

      # Make all scripts executable
      chmod +x $out/bin/*
    '';
  };
in
{
  # Add debug scripts to system packages
  environment.systemPackages = [ debugScripts ];

  # Create convenient aliases
  programs.bash.shellAliases = {
    # Quick access to debug scripts
    "gpu-debug" = "debug-gpu-comprehensive";
    "gpu-quick" = "debug-quick-test";
    "gpu-bpmp" = "debug-verify-bpmp";
    "gpu-nvidia" = "debug-nvidia-load";
  };
}
