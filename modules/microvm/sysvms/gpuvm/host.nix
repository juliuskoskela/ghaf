# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.virtualization.microvm.gpuvm;
  vmName = "gpu-vm";
in
{
  options.ghaf.virtualization.microvm.gpuvm = {
    enable = lib.mkEnableOption "GPUVM";

    extraModules = lib.mkOption {
      description = ''
        List of additional modules to be imported and evaluated as part of
        gpuvm's NixOS configuration.
      '';
      default = [ ];
    };

    # GPUVM uses a VSOCK which requires a CID
    # There are several special addresses:
    # VMADDR_CID_HYPERVISOR (0) is reserved for services built into the hypervisor
    # VMADDR_CID_LOCAL (1) is the well-known address for local communication (loopback)
    # VMADDR_CID_HOST (2) is the well-known address of the host
    # CID 3 is the lowest available number for guest virtual machines
    # Note: Changed from 3 to 105 to avoid conflicts with other VMs
    vsockCID = lib.mkOption {
      type = lib.types.int;
      default = 105;
      description = ''
        Context Identifier (CID) of the GPUVM VSOCK
      '';
    };

    applications = lib.mkOption {
      description = ''
        Applications to include in the GPUVM
      '';
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "The name of the application";
            };
            description = lib.mkOption {
              type = lib.types.str;
              description = "A brief description of the application";
            };
            icon = lib.mkOption {
              type = lib.types.str;
              description = "Application icon";
              default = null;
            };
            command = lib.mkOption {
              type = lib.types.str;
              description = "The command to run the application";
              default = null;
            };
          };
        }
      );
      default = [ ];
    };

    ollamaSupport = lib.mkOption {
      description = ''
        Enable Ollama AI model support with CUDA acceleration
      '';
      type = lib.types.bool;
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    # GPU passthrough patches should be applied via overlay if needed
    # The nvidia-oot modules are already provided by jetpack-nixos
    # No need to add them again here - this was causing duplicate module collision

    services.udev.extraRules = ''
      # Allow group kvm to all devices that are binded to vfio
      SUBSYSTEM=="vfio",GROUP="kvm"
      SUBSYSTEM=="chardrv", KERNEL=="bpmp-host", GROUP="kvm", MODE="0660"
    '';

    # Make sure that GPU-VM runs after the binding services are enabled
    systemd.services."microvm@gpu-vm".after = [ "bindGpu.service" ];

    # Service to bind the devices to passthrough to the VFIO driver
    systemd.services.bindGpu = {
      description = "Bind GPU devices to the vfio-platform driver";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "yes";
        ExecStartPre = [
          ''${pkgs.bash}/bin/bash -c "echo vfio-platform > /sys/bus/platform/devices/80000000.vm_cma_p/driver_override"''
          ''${pkgs.bash}/bin/bash -c "echo vfio-platform > /sys/bus/platform/devices/17000000.gpu/driver_override"''
          ''${pkgs.bash}/bin/bash -c "echo vfio-platform > /sys/bus/platform/devices/13e00000.host1x_pt/driver_override"''
          ''${pkgs.bash}/bin/bash -c "echo vfio-platform > /sys/bus/platform/devices/15340000.vic/driver_override"''
          ''${pkgs.bash}/bin/bash -c "echo vfio-platform > /sys/bus/platform/devices/15480000.nvdec/driver_override"''
          ''${pkgs.bash}/bin/bash -c "echo vfio-platform > /sys/bus/platform/devices/15540000.nvjpg/driver_override"''
          ''${pkgs.bash}/bin/bash -c "echo vfio-platform > /sys/bus/platform/devices/d800000.dce/driver_override"''
          ''${pkgs.bash}/bin/bash -c "echo vfio-platform > /sys/bus/platform/devices/13800000.display/driver_override"''
          ''${pkgs.bash}/bin/bash -c "echo vfio-platform > /sys/bus/platform/devices/60000000.vm_hs_p/driver_override"''
          ''${pkgs.bash}/bin/bash -c "echo vfio-platform > /sys/bus/platform/devices/100000000.vm_cma_vram_p/driver_override"''
        ];
        ExecStart = [
          ''${pkgs.bash}/bin/bash -c "echo 100000000.vm_cma_vram_p > /sys/bus/platform/drivers/vfio-platform/bind"''
          ''${pkgs.bash}/bin/bash -c "echo 80000000.vm_cma_p > /sys/bus/platform/drivers/vfio-platform/bind"''
          ''${pkgs.bash}/bin/bash -c "echo 17000000.gpu > /sys/bus/platform/drivers/vfio-platform/bind"''
          ''${pkgs.bash}/bin/bash -c "echo 13e00000.host1x_pt > /sys/bus/platform/drivers/vfio-platform/bind"''
          ''${pkgs.bash}/bin/bash -c "echo 15340000.vic > /sys/bus/platform/drivers/vfio-platform/bind"''
          ''${pkgs.bash}/bin/bash -c "echo 15480000.nvdec > /sys/bus/platform/drivers/vfio-platform/bind"''
          ''${pkgs.bash}/bin/bash -c "echo 15540000.nvjpg > /sys/bus/platform/drivers/vfio-platform/bind"''
          ''${pkgs.bash}/bin/bash -c "echo d800000.dce > /sys/bus/platform/drivers/vfio-platform/bind"''
          ''${pkgs.bash}/bin/bash -c "echo 13800000.display > /sys/bus/platform/drivers/vfio-platform/bind"''
          ''${pkgs.bash}/bin/bash -c "echo 60000000.vm_hs_p > /sys/bus/platform/drivers/vfio-platform/bind"''
        ];
      };
    };

    boot.kernelPatches = lib.mkIf pkgs.stdenv.isAarch64 [
      {
        name = "enable-vfio-platform";
        patch = null;
        extraStructuredConfig = with lib.kernel; {
          VFIO_PLATFORM = yes;
          VFIO_VIRQFD = yes;
        };
      }
      {
        name = "enable-bpmp-host-proxy";
        patch = null;
        extraStructuredConfig = with lib.kernel; {
          # Host needs HOST proxy for /dev/bpmp-host
          TEGRA_BPMP_HOST_PROXY = yes;
        };
      }
    ];

    # Device tree overlay for GPU passthrough
    hardware.deviceTree = lib.mkIf (cfg.enable && pkgs.stdenv.isAarch64) {
      enable = true;
      overlays = [
        {
          name = "GPU/Display passthrough overlay to host DTB";
          dtsFile = ./device-tree/gpu_passthrough_overlay.dts;
        }
        # Note: BPMP host proxy overlay not needed with "allow all domains" patch
      ];
    };

    # Kernel parameters for VFIO
    boot.kernelParams = lib.mkIf pkgs.stdenv.isAarch64 [
      "vfio-platform.reset_required=0"
      "vfio_iommu_type1.allow_unsafe_interrupts=1"
    ];

    # Kernel modules for VFIO
    boot.kernelModules = lib.mkIf pkgs.stdenv.isAarch64 [
      "vfio"
      "vfio_platform"
      "vfio_iommu_type1"
      "tegra_bpmp_host_proxy"  # Host needs HOST proxy, not guest!
    ];

    # Blacklist GPU drivers on host
    boot.blacklistedKernelModules = lib.mkIf pkgs.stdenv.isAarch64 [
      "nvgpu"
      "tegra-udrm"
      "nvidia-drm"
      "nvidia"
      "nvidia-modeset"
    ];

    # Add vfio options
    boot.extraModprobeConfig = lib.mkIf pkgs.stdenv.isAarch64 ''
      options vfio-platform reset_required=0
      options vfio_iommu_type1 allow_unsafe_interrupts=1
    '';

    microvm.vms."${vmName}" =
      let
        # Check if nvidia-oot is available in host kernel packages
        hostKernelPackages = config.boot.kernelPackages;
        hasNvidiaOot = hostKernelPackages ? nvidia-oot;

        # Apply patches to nvidia-oot modules for GPU passthrough
        nvidia-modules = hostKernelPackages.nvidia-oot.overrideAttrs (oldAttrs: {
          patches = (oldAttrs.patches or [ ]) ++ [
            ./patches/0001-gpu-add-support-for-passthrough.patch
            ./patches/0002-Add-support-for-gpu-display-passthrough.patch
            ./patches/0003-Add-support-for-display-passthrough.patch
          ];
        });

        # Derivation to build the GPU-VM guest device tree
        gpuvm-dtb = pkgs.stdenv.mkDerivation {
          name = "gpuvm-dtb";
          phases = [
            "unpackPhase"
            "buildPhase"
            "installPhase"
          ];
          src = ./device-tree/tegra234-gpuvm.dts;
          nativeBuildInputs =
            with pkgs;
            [
              gcc
              dtc
              binutils
            ]
            ++ lib.optionals hasNvidiaOot [
              hostKernelPackages.nvidia-oot
            ];

          unpackPhase = ''
            mkdir -p build
            cp $src tegra234-gpuvm.dts

            # Copy tegra234-soc-gpu-vm.dtsi from nvidia-oot
            ${lib.optionalString hasNvidiaOot ''
              if [ -d "${hostKernelPackages.nvidia-oot}/nvidia-oot/device-tree" ]; then
                cp -r ${hostKernelPackages.nvidia-oot}/nvidia-oot/device-tree/* .
              elif [ -d "${hostKernelPackages.nvidia-oot}/device-tree" ]; then
                cp -r ${hostKernelPackages.nvidia-oot}/device-tree/* .
              else
                echo "Warning: Could not find device-tree directory in nvidia-oot"
              fi
            ''}
          '';

          buildPhase = ''
            echo "Building DTB without preprocessing (simplified approach)"

            # Create a temporary DTS without the problematic includes
            cat tegra234-gpuvm.dts | sed \
              -e '/#include <dt-bindings\/interrupt\/tegra234-irq.h>/d' \
              -e '/#include <dt-bindings\/p2u\/tegra234-p2u.h>/d' \
              > tegra234-gpuvm-temp.dts

            # Try to build the DTB
            if dtc -I dts -O dtb -o tegra234-gpuvm.dtb tegra234-gpuvm-temp.dts 2>error.log; then
              echo "DTB built successfully without preprocessing"
            else
              echo "DTB build failed, errors:"
              cat error.log
              echo ""
              echo "Attempting build with kernel preprocessing..."
              
              # Fall back to preprocessing with kernel includes
              $CC -E -nostdinc \
                -I${hostKernelPackages.kernel.src}/include \
                -undef -D__DTS__ \
                -x assembler-with-cpp \
                tegra234-gpuvm-temp.dts > preprocessed.dts
                
              dtc -I dts -O dtb -o tegra234-gpuvm.dtb preprocessed.dts
            fi
          '';

          installPhase = ''
            mkdir -p $out
            cp tegra234-gpuvm.dtb $out/
          '';
        };

        # Custom pkgs for GPU VM
        customPkgs = import inputs.nixpkgs {
          system = "aarch64-linux";
          config = {
            allowUnfree = true;
            # Don't set cudaSupport here as it will try to use nixpkgs CUDA
            # The jetpack-nixos overlay provides its own CUDA packages
          };
          overlays = [
            inputs.jetpack-nixos.overlays.default
            inputs.self.overlays.cuda-jetpack
            inputs.self.overlays.default
            inputs.self.overlays.own-pkgs-overlay
          ];
        };

      in
      {
        autostart = true;
        pkgs = customPkgs;
        specialArgs = {
          inherit vmName inputs cfg;
        };
        config = {
          imports = [ ./vm-config.nix ];

          hardware.nvidia = {
            modesetting.enable = true;
            open = false; # Important for Tegra
          };

          # Add the DTB to qemu args
          microvm.qemu.extraArgs = lib.mkAfter [
            "-dtb"
            "${gpuvm-dtb.out}/tegra234-gpuvm.dtb"
          ];

          hardware.firmwareCompression = lib.mkForce "none";
          hardware.firmware = with pkgs.nvidia-jetpack; [
            l4t-firmware
            l4t-xusb-firmware # usb firmware also present in linux-firmware package, but that package is huge and has much more than needed
          ];

          boot = {
            inherit (config.boot) kernelPackages;
            kernelModules = [ 
              "tegra-bpmp-guest-proxy"
              # Force load nvidia modules
              "nvidia"
              "nvidia-uvm" 
              "nvidia-modeset"
            ];

            # CRITICAL: Add patched nvidia kernel modules to the GPU VM
            extraModulePackages = [ nvidia-modules ];
          };

          boot.initrd.systemd.enable = true;
          boot.loader = {
            efi.canTouchEfiVariables = true;
            systemd-boot.enable = true;
            grub.enable = false;
          };
        };
      };
  };
}
