# Copyright 2022-2023 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
(_final: prev: {
  # Override qemu_kvm with a custom build that includes tegra device support
  # The default qemu_kvm (qemu-host-cpu-only) doesn't include misc devices
  # We need to build QEMU with the tegra device enabled
  qemu_kvm =
    (prev.qemu.override {
      # Use minimal targets to reduce build time
      hostCpuTargets = [ "aarch64-softmmu" ];
      # Disable features we don't need to avoid build issues
      gtkSupport = false;
      sdlSupport = false;
      spiceSupport = false;
      smartcardSupport = false;
      libiscsiSupport = false;
      tpmSupport = false;
      cephSupport = false;
      # Keep essential features
      virglSupport = true;
      openGLSupport = true;
      seccompSupport = true;
    }).overrideAttrs
      (
        # Patches from https://github.com/jpruiz84/qemu/tree/bpmp_for_v9.2
        _finalAttrs: prevAttrs: {
          patches = prevAttrs.patches ++ [
            ./patches/0001-nvidia-bpmp-guest-driver-initial-commit.patch
            ./patches/0002-NOP_PREDEFINED_DTB_MEMORY.patch
            ./patches/0004-vfio-platform-Add-mmio-base-property-to-define-start.patch
          ];

          # Ensure the tegra device is compiled in
          # The patch adds the device, but we need to ensure it's enabled in the build
          postPatch =
            (prevAttrs.postPatch or "")
            + ''
              # Ensure tegra234-bpmp-guest device is included in the build
              if ! grep -q "tegra234-bpmp-guest" hw/misc/meson.build; then
                echo "system_ss.add(when: 'CONFIG_NVIDIA_BPMP_GUEST', if_true: files('nvidia_bpmp_guest.c'))" >> hw/misc/meson.build
              fi

              # Enable the device in default configs
              echo "CONFIG_NVIDIA_BPMP_GUEST=y" >> configs/devices/aarch64-softmmu/default.mak
            '';
        }
      );
})
