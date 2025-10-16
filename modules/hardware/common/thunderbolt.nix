# Copyright 2022-2025 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Thunderbolt/USB4 support module
#
# This module enables Thunderbolt/USB4 support on the host system, allowing
# Thunderbolt devices (including docks with ethernet adapters) to be enumerated
# and authorized. Once authorized, USB ethernet adapters from Thunderbolt docks
# are automatically routed to net-vm via vhotplug.
#
# ## Usage
#
# To enable Thunderbolt support in your configuration:
#
#   ghaf.hardware.thunderbolt.enable = true;
#
# For example, in targets/laptop/flake-module.nix:
#
#   (laptop-configuration "my-laptop" "debug" (withCommonModules [
#     self.nixosModules.hardware-lenovo-x1-carbon-gen11
#     {
#       ghaf = {
#         hardware.thunderbolt.enable = true;
#         # ... other config ...
#       };
#     }
#   ]))
#
# ## Device Authorization
#
# After boot, Thunderbolt devices must be authorized before they can be used:
#
#   1. Connect your Thunderbolt device/dock
#   2. Run `boltctl` to list connected devices and their UUIDs
#   3. For each unauthorized device (shown in orange), run:
#      `boltctl enroll --chain UUID_FROM_DEVICE`
#   4. Verify with `boltctl` that all devices are authorized (green)
#
# ## Ethernet Passthrough
#
# USB ethernet adapters from Thunderbolt docks are automatically detected and
# passed through to net-vm by the vhotplug system. No additional configuration
# is required for standard USB ethernet adapters (CDC Ethernet, class 2:6).
#
# For vendor-specific ethernet adapters, add the VID:PID to vhotplug rules:
# See modules/hardware/common/usb/vhotplug.nix for examples.
#
# ## Security Note
#
# Enabling this module increases the host attack surface by enabling USB and
# Thunderbolt support in the kernel. This is necessary for Thunderbolt dock
# functionality but conflicts with the minimal hardened baseline.
# Use only when Thunderbolt support is required.
#
# ## Kernel Modules
#
# This module adds the following kernel modules to initrd:
# - thunderbolt: Thunderbolt/USB4 host controller support
# - xhci_pci: USB 3.x host controller (required for Thunderbolt)
# - sd_mod: SCSI disk support (for Thunderbolt storage devices)
#
# Note: nvme and uas modules are already included in x86_64-generic configuration.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.hardware.thunderbolt;
in
{
  options.ghaf.hardware.thunderbolt = {
    enable = lib.mkEnableOption "Thunderbolt/USB4 support for docks and external devices";
  };

  config = lib.mkIf cfg.enable {

    # Enable Thunderbolt device authorization daemon
    # This daemon handles Thunderbolt security and device authorization
    services.hardware.bolt.enable = true;

    # Add Thunderbolt and USB-related kernel modules to initrd
    # These modules are required for Thunderbolt device enumeration
    boot.initrd.availableKernelModules = [
      "thunderbolt" # Thunderbolt/USB4 host support
      "xhci_pci" # USB 3.x host controller (required for Thunderbolt)
      "sd_mod" # SCSI disk support (for Thunderbolt storage devices)
      # Note: nvme, uas are already in x86_64-generic config
    ];

    # Enable all firmware to support various Thunderbolt controllers
    hardware.enableAllFirmware = true;

    # Add boltctl to system packages for manual device management
    environment.systemPackages = with pkgs; [
      bolt
    ];

    # USB ethernet adapters from Thunderbolt docks are automatically
    # routed to net-vm by vhotplug (see modules/hardware/common/usb/vhotplug.nix)
    # No additional configuration needed for USB ethernet passthrough
  };
}
