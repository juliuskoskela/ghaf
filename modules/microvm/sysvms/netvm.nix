# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ inputs }:
{
  config,
  lib,
  ...
}:
let
  vmName = "net-vm";
  netvmBaseConfiguration = {
    imports = [
      inputs.impermanence.nixosModules.impermanence
      inputs.self.nixosModules.givc
      inputs.self.nixosModules.vm-modules
      inputs.self.nixosModules.profiles
      (
        { lib, ... }:
        {
          ghaf = {
            # Profiles
            profiles.debug.enable = lib.mkDefault config.ghaf.profiles.debug.enable;
            development = {
              # NOTE: SSH port also becomes accessible on the network interface
              #       that has been passed through to NetVM
              ssh.daemon.enable = lib.mkDefault config.ghaf.development.ssh.daemon.enable;
              debug.tools.enable = lib.mkDefault config.ghaf.development.debug.tools.enable;
              nix-setup.enable = lib.mkDefault config.ghaf.development.nix-setup.enable;
            };
            users = {
              proxyUser = {
                enable = true;
                extraGroups = [
                  "networkmanager"
                ];
              };
            };

            # System
            type = "system-vm";
            systemd = {
              enable = true;
              withName = "netvm-systemd";
              withAudit = config.ghaf.profiles.debug.enable;
              withPolkit = true;
              withResolved = true;
              withTimesyncd = true;
              withDebug = config.ghaf.profiles.debug.enable;
              withHardenedConfigs = true;
            };
            givc.netvm.enable = true;

            # Storage
            storagevm = {
              enable = true;
              name = vmName;
              directories = [ "/etc/NetworkManager/system-connections/" ];
            };

            # Networking
            virtualization.microvm.vm-networking = {
              enable = true;
              isGateway = true;
              inherit vmName;
            };

            # Services
            logging.client.enable = config.ghaf.logging.enable;
          };

          time.timeZone = config.time.timeZone;
          system.stateVersion = lib.trivial.release;

          nixpkgs = {
            buildPlatform.system = config.nixpkgs.buildPlatform.system;
            hostPlatform.system = config.nixpkgs.hostPlatform.system;
          };

          networking = {
            firewall = {
              allowedTCPPorts = [ 53 ];
              allowedUDPPorts = [ 53 ];
              extraCommands = lib.mkAfter ''

                # Set the default policies
                iptables -P INPUT DROP
                iptables -P FORWARD ACCEPT
                iptables -P OUTPUT ACCEPT

                # Allow loopback traffic
                iptables -I INPUT -i lo -j ACCEPT
                iptables -I OUTPUT -o lo -j ACCEPT
              '';
            };
          };

          boot.kernelParams = [
            "coherent_pool=8M"
            "cma=64M"
            "swiotlb=force,65536"
            "iommu=soft"
            "initcall_debug" # adds detailed kernel initialization tracing
            "loglevel=7" # verbose logging level
          ];

          boot.extraModprobeConfig = ''
            options rtw88_core debug_mask=0x00000fff
          '';

          microvm = {
            # Optimize is disabled because when it is enabled, qemu is built without libusb
            optimize.enable = false;
            hypervisor = "qemu";
            shares = [
              {
                tag = "ro-store";
                source = "/nix/store";
                mountPoint = "/nix/.ro-store";
                proto = "virtiofs";
              }
            ];

            writableStoreOverlay = lib.mkIf config.ghaf.development.debug.tools.enable "/nix/.rw-store";

            qemu = {
              machine =
                {
                  x86_64-linux = "q35";
                  aarch64-linux = "virt";
                }
                .${config.nixpkgs.hostPlatform.system};

              extraArgs = [
                "-device"
                "qemu-xhci"

                # Enable DMA tracing via individual event options
                "-trace"
                "events=/tmp/trace-events"
                "-trace"
                "memory_region_ram_*,file=/tmp/qemu-trace.log"
                # "-trace"
                # "vfio_dma_map"
                # "-trace"
                # "vfio_dma_unmap"
                # "-trace"
                # "vfio_region_*"
                # "-trace"
                # "memory_region_ram_*"
              ];

            };
          };
        }
      )
    ];
  };
  cfg = config.ghaf.virtualization.microvm.netvm;
in
{
  options.ghaf.virtualization.microvm.netvm = {
    enable = lib.mkEnableOption "NetVM";

    extraModules = lib.mkOption {
      description = ''
        List of additional modules to be imported and evaluated as part of
        NetVM's NixOS configuration.
      '';
      default = [ ];
    };
  };

  config = lib.mkIf cfg.enable {
    microvm.vms."${vmName}" = {
      autostart = true;
      restartIfChanged = false;
      inherit (inputs) nixpkgs;
      config = netvmBaseConfiguration // {
        imports = netvmBaseConfiguration.imports ++ cfg.extraModules;
      };
    };
  };
}
