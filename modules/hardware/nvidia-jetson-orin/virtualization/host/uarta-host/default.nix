# Copyright 2022-2023 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.ghaf.hardware.nvidia.orin.virtualization.host.uarta;
in {
  options.ghaf.hardware.nvidia.orin.virtualization.host.uarta.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable UARTA passthrough on Nvidia Orin";
  };

  config = lib.mkIf cfg.enable {
    systemd.services.enableVfioPlatform = {
      description = "Enable the vfio-platform driver for UARTA";
      wantedBy = ["bindSerial3100000.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "yes";
        ExecStart = ''
          ${pkgs.bash}/bin/bash -c "echo vfio-platform > /sys/bus/platform/devices/3100000.serial/driver_override"
        '';
      };
    };

    systemd.services.bindSerial3100000 = {
      description = "Bind UARTA to the vfio-platform driver";
      wantedBy = ["multi-user.target"];
      after = ["enableVfioPlatform.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "yes";
        ExecStart = ''
          ${pkgs.bash}/bin/bash -c "echo 3100000.serial > /sys/bus/platform/drivers/vfio-platform/bind"
        '';
      };
    };
  };
}
