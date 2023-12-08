# Copyright 2022-2023 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  lib,
  config,
  ...
}: let
  cfg = config.ghaf.hardware.nvidia.orin.virtualization;
in {
  options.ghaf.hardware.nvidia.orin.virtualization.enable = lib.mkOption {
    type = lib.t pes.bool;
    default = false;
    description = "Enable virtualization support for NVIDIA Orin";
  };

  config = lib.mkIf cfg.enable {
    boot.kernelPatches = [
      {
        name = "Added Configurations to Support Vda";
        patch = ./patches/0001-added-configurations-to-support-vda.patch;
      }
      {
        name = "Vfio_platform Reset Required False";
        patch = ./patches/0002-vfio_platform-reset-required-false.patch;
      }
      {
        name = "Bpmp Support Virtualization";
        patch = ./patches/0003-bpmp-support-bpmp-virt.patch;
      }
      {
        name = "Bpmp Virt Drivers";
        patch = ./patches/0004-bpmp-virt-drivers.patch;
      }
      {
        name = "Bpmp Overlay";
        patch = ./patches/0005-bpmp-overlay.patch;
      }
    ];

    boot.kernelParams = ["vfio_iommu_type1.allow_unsafe_interrupts=1"];
  };
}
