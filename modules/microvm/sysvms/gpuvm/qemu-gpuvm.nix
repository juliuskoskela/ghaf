# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  qemu,
}:
qemu.overrideAttrs (
  _finalAttrs: prevAttrs: {
    pname = "qemu-gpuvm";

    patches = prevAttrs.patches ++ [
      ./qemu/patches/0001-nvidia-bpmp-guest-driver-initial-commit.patch
      ./qemu/patches/0002-NOP_PREDEFINED_DTB_MEMORY.patch
      ./qemu/patches/0004-vfio-platform-Add-mmio-base-property-to-define-start.patch
    ];

    postPatch =
      (prevAttrs.postPatch or "")
      + ''
        set -e  # Fail on error

        echo "GPUVM: Configuring Jetson GPU support..."

        # First verify the patches were applied correctly
        echo "GPUVM: Verifying patch application..."

        # Check Kconfig entries
        if ! grep -q "config NVIDIA_BPMP_GUEST" hw/misc/Kconfig; then
          echo "GPUVM: ERROR - Kconfig missing NVIDIA_BPMP_GUEST definition"
          exit 1
        fi
        echo "GPUVM: ✓ Kconfig has NVIDIA_BPMP_GUEST definition"

        if ! grep -q "select NVIDIA_BPMP_GUEST" hw/arm/Kconfig; then
          echo "GPUVM: ERROR - ARM Kconfig doesn't select NVIDIA_BPMP_GUEST"
          exit 1
        fi
        echo "GPUVM: ✓ ARM Kconfig selects NVIDIA_BPMP_GUEST"

        # Check source file
        if [ ! -f hw/misc/nvidia_bpmp_guest.c ]; then
          echo "GPUVM: ERROR - nvidia_bpmp_guest.c NOT found"
          exit 1
        fi
        echo "GPUVM: ✓ nvidia_bpmp_guest.c found"

        # Check meson.build
        if ! grep -q "nvidia_bpmp_guest.c" hw/misc/meson.build; then
          echo "GPUVM: ERROR - meson.build missing nvidia_bpmp_guest.c"
          exit 1
        fi
        echo "GPUVM: ✓ meson.build includes nvidia_bpmp_guest.c"

        # Now enable it in the default.mak files
        echo "GPUVM: Enabling CONFIG_NVIDIA_BPMP_GUEST in target configs..."

        # CRITICAL: Use the correct path for modern QEMU (6.2+)
        # Old path: default-configs/
        # New path: configs/devices/

        # Enable for aarch64-softmmu
        if [ -f configs/devices/aarch64-softmmu/default.mak ]; then
          echo "CONFIG_NVIDIA_BPMP_GUEST=y" >> configs/devices/aarch64-softmmu/default.mak
          echo "GPUVM: ✓ Added to configs/devices/aarch64-softmmu/default.mak"
        else
          echo "GPUVM: WARNING - configs/devices/aarch64-softmmu/default.mak not found"
        fi

        # Also enable for arm-softmmu if it exists
        if [ -f configs/devices/arm-softmmu/default.mak ]; then
          echo "CONFIG_NVIDIA_BPMP_GUEST=y" >> configs/devices/arm-softmmu/default.mak
          echo "GPUVM: ✓ Added to configs/devices/arm-softmmu/default.mak"
        fi

        # Debug: Show what we added
        echo "GPUVM: Verifying CONFIG_NVIDIA_BPMP_GUEST is enabled:"
        grep -r "CONFIG_NVIDIA_BPMP_GUEST" configs/devices/ || true

        # Also check the device type name
        echo "GPUVM: Device type name from patch:"
        grep "TYPE_NVIDIA_BPMP_GUEST" hw/misc/nvidia_bpmp_guest.c | grep define || true

        echo "GPUVM: Configuration complete"
      '';

    meta = prevAttrs.meta // {
      description = "QEMU with NVIDIA Jetson GPU passthrough support";
      longDescription = ''
        QEMU patched with NVIDIA tegra234-bpmp-guest device support
        for GPU passthrough on Jetson Orin platforms.
      '';
    };
  }
)
