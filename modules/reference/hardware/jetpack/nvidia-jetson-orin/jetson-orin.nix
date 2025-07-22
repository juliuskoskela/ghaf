# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Configuration for NVIDIA Jetson Orin AGX/NX reference boards
{
  lib,
  config,
  ...
}:
let
  cfg = config.ghaf.hardware.nvidia.orin;
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    ;
in
{
  imports = [
    #TODO: fix me
    ../../../../hardware/common/usb/vhotplug.nix
  ];
  options.ghaf.hardware.nvidia.orin = {
    # Enable the Orin boards
    enable = mkEnableOption "Orin hardware";

    flashScriptOverrides.onlyQSPI = mkEnableOption "to only flash QSPI partitions, i.e. disable flashing of boot and root partitions to eMMC";

    flashScriptOverrides.preFlashCommands = mkOption {
      description = "Commands to run before the actual flashing";
      type = types.str;
      default = "";
    };

    somType = mkOption {
      description = "SoM config Type (NX|AGX32|AGX64|Nano)";
      type = types.str;
      default = "agx";
    };

    carrierBoard = mkOption {
      description = "Board Type";
      type = types.str;
      default = "devkit";
    };

    kernelVersion = mkOption {
      description = "Kernel version";
      type = types.str;
      default = "bsp-default";
    };
  };

  config = mkIf cfg.enable {
    hardware.nvidia-jetpack.enable = true;
    hardware.nvidia-jetpack.kernel.version = "${cfg.kernelVersion}";
    nixpkgs.hostPlatform.system = "aarch64-linux";

    ghaf.hardware.aarch64.systemd-boot-dtb.enable = true;

    boot = {
      loader = {
        efi.canTouchEfiVariables = true;
        systemd-boot = {
          enable = true;
          # Disable systemd-boot's built-in device tree handling
          # since we manage it manually in systemd-boot-dtb module
          installDeviceTree = false;
        };
      };

      modprobeConfig.enable = true;

      kernelPatches = [
        {
          name = "vsock-config";
          patch = null;
          extraStructuredConfig = with lib.kernel; {
            VHOST = yes;
            VHOST_MENU = yes;
            VHOST_IOTLB = yes;
            VHOST_VSOCK = yes;
            VSOCKETS = yes;
            VSOCKETS_DIAG = yes;
            VSOCKETS_LOOPBACK = yes;
            VIRTIO_VSOCKETS_COMMON = yes;
          };
        }
        {
          name = "virtiofs-config";
          patch = null;
          extraStructuredConfig = with lib.kernel; {
            # Enable FUSE and VirtioFS for microvm shared filesystems
            FUSE_FS = module;
            VIRTIO_FS = module;
            # DAX support for better performance (optional)
            DAX = yes;
            FS_DAX = yes;
          };
        }
      ];
    };

    ghaf.hardware.usb.vhotplug = {
      enable = true;
      rules = [
        {
          name = "NetVM";
          qmpSocket = "/var/lib/microvms/net-vm/net-vm.sock";
          usbPassthrough = [
            {
              class = 2;
              subclass = 6;
              description = "Communications - Ethernet Networking";
            }
            {
              vendorId = "0b95";
              productId = "1790";
              description = "ASIX Elec. Corp. AX88179 UE306 Ethernet Adapter";
            }
          ];
        }
      ];
    };

    services.nvpmodel = {
      enable = lib.mkDefault true;
      # Enable all CPU cores, full power consumption (50W on AGX, 25W on NX)
      profileNumber = lib.mkDefault 3;
    };
    hardware.deviceTree = {
      enable = lib.mkDefault true;

      # Use kernel's compiled DTB files instead of NVIDIA BSP's to fix BPMP/I2C/SPI issues
      dtbSource = "${config.boot.kernelPackages.kernel}/dtbs/nvidia/";

      # Set the DTB name (without -nv suffix and without .dtb extension)
      name = "tegra234-p3737-0000+p3701-0000";

      # Don't set package here - let the device-tree module handle overlay application
      # package = lib.mkForce config.boot.kernelPackages.kernel;

      # Add the include paths to build the dtb overlays
      dtboBuildExtraIncludePaths = [
        "${lib.getDev config.hardware.deviceTree.kernelPackage}/lib/modules/${config.hardware.deviceTree.kernelPackage.modDirVersion}/source/nvidia/soc/t23x/kernel-include"
      ];
    };

    # NOTE: "-nv.dtb" files are from NVIDIA's BSP
    # Versions of the device tree without PCI passthrough related
    # modifications.
  };
}
