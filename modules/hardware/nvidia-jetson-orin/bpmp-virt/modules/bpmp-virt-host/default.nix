# Copyright 2022-2023 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  lib,
  pkgs,
  ...
}: {
  imports = [../bpmp-virt-common];

  nixpkgs.overlays = [(import ./overlays/qemu)];

  boot.kernelPatches = [
    {
      name = "Bpmp virtualization host proxy device tree";
      patch = ./patches/0001-bpmp-host-proxy-dts.patch;
    }
    {
      name = "Bpmp virtualization host uarta device tree";
      patch = ./patches/0002-bpmp-host-uarta-dts.patch;
    }
    {
      name = "Bpmp virtualization host kernel configuration";
      patch = null;
      extraStructuredConfig = with lib.kernel; {
        VFIO_PLATFORM = yes;
        TEGRA_BPMP_HOST_PROXY = yes;
      };
    }
  ];

  environment.systemPackages = with pkgs; [
    qemu
    dtc
  ];

  systemd.services.enableVfioPlatform = {
    description = "Bind UARTA to the vfio-platform driver";
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
}
