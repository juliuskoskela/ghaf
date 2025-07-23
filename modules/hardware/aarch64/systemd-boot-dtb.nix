# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Module which adds option ghaf.boot.loader.systemd-boot-dtb.enable
#
# By setting this option to true, device tree file gets copied to
# /boot-partition, and gets added to systemd-boot's entry.
#
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.hardware.aarch64.systemd-boot-dtb;
  inherit (lib) mkEnableOption mkIf;

  # Construct the correct DTB path based on package type
  dtbPath =
    if config.hardware.deviceTree.package == config.boot.kernelPackages.kernel then
      # Kernel package - DTBs are in dtbs/nvidia/
      "${config.hardware.deviceTree.package}/dtbs/nvidia/${config.hardware.deviceTree.name}.dtb"
    else if lib.hasPrefix "device-tree-overlays" (config.hardware.deviceTree.package.name or "") then
      # Device tree overlays package - look for the DTB without -nv suffix
      "${config.hardware.deviceTree.package}/${config.hardware.deviceTree.name}.dtb"
    else
      # Other packages - ensure .dtb extension is present
      let
        basePath = "${config.hardware.deviceTree.package}/${config.hardware.deviceTree.name}";
      in
        if lib.hasSuffix ".dtb" config.hardware.deviceTree.name
        then basePath
        else "${basePath}.dtb";
in
{
  options.ghaf.hardware.aarch64.systemd-boot-dtb = {
    enable = mkEnableOption "systemd-boot-dtb";
  };

  config = mkIf cfg.enable {
    # Add devicetree to bootspec with correct path including .dtb extension
    # This fixes the systemd-boot activation error where bootspec contains path without .dtb
    boot.bootspec.extensions."org.nixos.systemd-boot" = {
      devicetree = dtbPath;
    };

    boot.loader.systemd-boot = {
      # Ensure the extraFiles entry has .dtb extension to match the actual file
      extraFiles."dtbs/${config.hardware.deviceTree.name}.dtb" = dtbPath;

      extraInstallCommands = ''
        # Find out the latest generation from loader.conf
        default_cfg=$(${pkgs.coreutils}/bin/cat /boot/loader/loader.conf | ${pkgs.gnugrep}/bin/grep default | ${pkgs.gawk}/bin/awk '{print $2}')
        FILEHASH=$(${pkgs.coreutils}/bin/sha256sum "${dtbPath}" | ${pkgs.coreutils}/bin/cut -d ' ' -f 1)
        FILENAME="/dtbs/$FILEHASH.dtb"
        ${pkgs.coreutils}/bin/cp -fv "${dtbPath}" "/boot$FILENAME"
        echo "devicetree $FILENAME" >> /boot/loader/entries/$default_cfg
      '';
    };
  };
}
