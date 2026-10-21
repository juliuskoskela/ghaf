# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  exportNvme ? false,
  lib,
  pkgs,
}:
let
  buildPkgs = pkgs.buildPackages;
  busybox = pkgs.pkgsStatic.busybox;
  jetpack = pkgs.nvidia-jetpack;
  modules = [
    "pcie_tegra194"
    "nvme-core"
    "nvme"
    "libcomposite"
    "udc-core"
    "tegra-xudc"
    "xhci-tegra"
    "u_serial"
    "usb_f_acm"
  ]
  ++ lib.optionals exportNvme [ "usb_f_mass_storage" ];
  moduleClosure = pkgs.makeModulesClosure {
    rootModules = modules;
    kernel = config.system.modulesTree;
    firmware = config.hardware.firmware;
    allowMissing = false;
  };
  init = pkgs.writeScript (if exportNvme then "nx-rcm-nvme-export-init" else "nx-rcm-nvme-init") ''
    #!/bin/sh
    export PATH=/bin:${lib.getBin pkgs.util-linux}/bin:${lib.getBin pkgs.pciutils}/bin

    mkdir -p /proc /sys /dev /sys/kernel/config /tmp
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t devtmpfs devtmpfs /dev

    for module in ${lib.concatStringsSep " " modules}; do
      modprobe -v "$module" >> /tmp/module-load.log 2>&1 || echo "$module may be built into the kernel" >> /tmp/module-load.log
    done
    mount -t configfs configfs /sys/kernel/config
    mdev -s

    gadget=/sys/kernel/config/usb_gadget/${if exportNvme then "nx-recovery" else "nx-diagnostic"}
    mkdir -p "$gadget/strings/0x409" "$gadget/configs/c.1" "$gadget/functions/acm.usb0"
    echo 0x1d6b > "$gadget/idVendor"
    echo ${if exportNvme then "0x0105" else "0x0104"} > "$gadget/idProduct"
    echo Ghaf > "$gadget/strings/0x409/manufacturer"
    echo ${if exportNvme then "NX-recovery" else "NX-diagnostic"} > "$gadget/strings/0x409/product"
    echo ${if exportNvme then "S4EVNM0TA19050K" else "0"} > "$gadget/strings/0x409/serialnumber"
    ln -s "$gadget/functions/acm.usb0" "$gadget/configs/c.1/acm.usb0"
    ${lib.optionalString exportNvme ''
      attempt=0
      while [ "$attempt" -lt 60 ]; do
        mdev -s
        if [ -b /dev/nvme0n1 ] \
          && [ -r /sys/class/nvme/nvme0/model ] \
          && [ -r /sys/class/nvme/nvme0/serial ] \
          && [ -r /sys/block/nvme0n1/size ]; then
          break
        fi
        attempt=$((attempt + 1))
        sleep 1
      done
      if [ ! -b /dev/nvme0n1 ] \
        || [ "$(sed 's/[[:space:]]*$//' /sys/class/nvme/nvme0/model)" != "Samsung SSD 970 EVO Plus 500GB" ] \
        || [ "$(sed 's/[[:space:]]*$//' /sys/class/nvme/nvme0/serial)" != "S4EVNM0TA19050K" ] \
        || [ "$(cat /sys/block/nvme0n1/size)" != "976773168" ]; then
        echo "NVMe identity mismatch; refusing USB storage export" > /dev/console
        while :; do sleep 10; done
      fi
      mkdir -p "$gadget/functions/mass_storage.usb0"
      echo 0 > "$gadget/functions/mass_storage.usb0/lun.0/ro"
      echo 0 > "$gadget/functions/mass_storage.usb0/lun.0/removable"
      echo 0 > "$gadget/functions/mass_storage.usb0/lun.0/nofua"
      echo /dev/nvme0n1 > "$gadget/functions/mass_storage.usb0/lun.0/file"
      ln -s "$gadget/functions/mass_storage.usb0" "$gadget/configs/c.1/mass_storage.usb0"
    ''}
    if [ -w /sys/class/usb_role/usb2-0-role-switch/role ]; then
      echo device > /sys/class/usb_role/usb2-0-role-switch/role
    fi
    mdev -s
    sleep 5

    report() {
      echo "BEGIN GHAF-NX-RCM-NVME-${if exportNvme then "EXPORT" else "DIAGNOSTIC"}"
      uname -a
      cat /proc/cmdline
      echo "Module load:"
      cat /tmp/module-load.log
      echo "PCI devices:"
      lspci -nn
      echo "Block devices:"
      lsblk -b -o NAME,TYPE,SIZE,MODEL,SERIAL,TRAN
      echo "NVMe identity:"
      for dev in /sys/class/nvme/nvme*; do
        [ -d "$dev" ] || continue
        echo "$dev"
        for field in model serial firmware_rev state; do
          [ -r "$dev/$field" ] && cat "$dev/$field"
        done
      done
      echo "Kernel log:"
      dmesg
      echo "END GHAF-NX-RCM-NVME-${if exportNvme then "EXPORT" else "DIAGNOSTIC"}"
    }

    report > /dev/console 2>&1
    echo "Waiting for recovery USB ACM${lib.optionalString exportNvme " and NVMe export"}" > /dev/console
    while :; do
      for udc in /sys/class/udc/*; do
        if [ -d "$udc" ]; then
          echo "''${udc##*/}" > "$gadget/UDC"
          break 2
        fi
      done
      sleep 1
    done
    while [ ! -c /dev/ttyGS0 ]; do
      mdev -s
      sleep 1
    done
    while :; do
      report > /dev/ttyGS0 2>&1
      sleep 10
    done
  '';
  initrd = pkgs.makeInitrd {
    name = if exportNvme then "nx-rcm-nvme-export-initrd" else "nx-rcm-nvme-initrd";
    contents = [
      {
        object = init;
        symlink = "/init";
      }
      {
        object = busybox;
        symlink = "/bin";
        suffix = "/bin";
      }
      {
        object = moduleClosure;
        symlink = "/lib";
        suffix = "/lib";
      }
      {
        object = lib.getBin pkgs.util-linux;
        symlink = "/tools/util-linux";
      }
      {
        object = lib.getBin pkgs.pciutils;
        symlink = "/tools/pciutils";
      }
    ];
  };
  usbDts = buildPkgs.writeText "nx-rcm-usb.dts" ''
    /dts-v1/;
    /plugin/;

    / {
      fragment@0 {
        target-path = "/bus@0/padctl@3520000/ports/usb2-0";
        board_config { sw-modules = "kernel", "uefi"; };
        __overlay__ {
          mode = "peripheral";
          usb-role-switch;
          connector {
            compatible = "usb-b-connector", "gpio-usb-b-connector";
            cable-connected-on-boot = <2>;
          };
        };
      };
      fragment@1 {
        target-path = "/bus@0/usb@3550000";
        board_config { sw-modules = "kernel", "uefi"; };
        __overlay__ { status = "okay"; };
      };
    };
  '';
  usbOverlay = buildPkgs.runCommand "nx-rcm-usb.dtbo" { nativeBuildInputs = [ buildPkgs.dtc ]; } ''
    dtc -@ -I dts -O dtb ${usbDts} -o "$out"
  '';
  flashArgs = [
    "--rcm-boot"
    "-r"
  ]
  ++ config.hardware.nvidia-jetpack.flashScriptOverrides.flashArgs;
  script = jetpack.mkFlashScript buildPkgs.nvidia-jetpack.flash-tools {
    inherit flashArgs;
    partitionTemplate = null;
    preFlashCommands = ''
      cp ${config.system.build.kernel}/${config.system.boot.loader.kernelFile} kernel/Image
      cp ${initrd}/initrd bootloader/l4t_initrd.img
      export CMDLINE="${
        lib.concatStringsSep " " (
          config.hardware.nvidia-jetpack.console.args
          ++ [
            "root=/dev/ram0"
            "ro"
            "rdinit=/init"
          ]
        )
      }"
      export INITRD_IN_BOOTIMG=yes
    '';
    postFlashCommands = "";
    additionalDtbOverlays =
      (lib.filter (
        path: (path.name or "") != "DefaultBootOrder.dtbo"
      ) config.hardware.nvidia-jetpack.flashScriptOverrides.additionalDtbOverlays)
      ++ [ usbOverlay ];
  };
in
buildPkgs.writeShellApplication {
  name = if exportNvme then "nx-rcm-nvme-export" else "nx-rcm-nvme-diagnostic";
  text = ''
    if [ "$#" -ne 0 ]; then
      echo "This ${if exportNvme then "recovery exporter" else "diagnostic"} takes no arguments" >&2
      exit 2
    fi
    unset WORKDIR ADDITIONAL_DTB_OVERLAY
    ${script}
  '';
  meta.platforms = [ "x86_64-linux" ];
}
