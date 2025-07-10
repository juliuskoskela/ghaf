# Copyright 2025 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Fix for initrd kernel modules on Jetson platforms
{ config, lib, pkgs, ... }:
{
  # Override the default initrd modules to exclude x86-specific modules
  boot.initrd.availableKernelModules = lib.mkForce [
    # Essential modules for ARM/Jetson platforms
    "nvme"        # NVMe storage support
    "uas"         # USB Attached SCSI
    "usb-storage" # USB storage devices
    "mmc_block"   # MMC/SD card support
    "sdhci"       # SD Host Controller Interface
    "sdhci-tegra" # Tegra-specific SDHCI
    # Virtio modules for microvm support (if available in kernel)
    "virtio_mmio"
    "virtio_pci"
    "virtio_blk"
    "9pnet_virtio"
    "9p"
    # Note: virtiofs requires kernel config changes
    # Explicitly exclude sata_nv which is x86-specific
  ];
}