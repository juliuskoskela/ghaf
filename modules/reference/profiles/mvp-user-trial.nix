# Copyright 2022-2025 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ config, lib, ... }:
let
  cfg = config.ghaf.reference.profiles.mvp-user-trial;
in
{
  options.ghaf.reference.profiles.mvp-user-trial = {
    enable = lib.mkEnableOption "Enable the mvp configuration for apps and services";
  };

  config = lib.mkIf cfg.enable {
    ghaf = {
      graphics = {
        labwc = {
          autologinUser = lib.mkForce null;
        };
      };

      # Enable shared directories for the selected VMs
      virtualization.microvm-host.sharedVmDirectory.vms = [
        "business-vm"
        "comms-vm"
        "chrome-vm"
      ];

      virtualization.microvm.appvm = {
        enable = true;
        vms = {
          chrome.enable = true;
          gala.enable = false;
          zathura.enable = true;
          comms.enable = true;
          business.enable = true;
        };
      };

      hardware.passthrough = {
        mode = "dynamic";
        VMs = {
          gui-vm.permittedDevices = [
            "crazyradio0"
            "crazyradio1"
            "crazyfile0"
            "fpr0"
            "usbKBD"
            "xbox0"
            "xbox1"
            "xbox2"
          ];
          comms-vm.permittedDevices = [ "gps0" ];
          audio-vm.permittedDevices = [ "bt0" ];
          business-vm.permittedDevices = [ "cam0" ];
        };
      };

      reference = {
        appvms.enable = true;
        services = {
          enable = true;
          dendrite = true;
          proxy-business = lib.mkForce config.ghaf.virtualization.microvm.appvm.vms.business.enable;
          google-chromecast = {
            enable = true;
            # Should match the name of the chrome VM above
            vmName = "chrome-vm";
          };
          alpaca-ollama = true;
          wireguard-gui = true;
        };

        personalize = {
          keys.enable = true;
        };

        desktop.applications.enable = true;
      };

      profiles = {
        laptop-x86 = {
          enable = true;
          netvmExtraModules = [
            ../services
            ../personalize
            { ghaf.reference.personalize.keys.enable = true; }
          ];
          guivmExtraModules = [
            ../services
            ../programs
            ../personalize
            { ghaf.reference.personalize.keys.enable = true; }
          ];
        };
      };

      # Enable logging with local Loki, retention, and external sync
      logging = {
        enable = true;
        listener.address = config.ghaf.networking.hosts.admin-vm.ipv4;

        # Enable log categorization
        categorization = {
          enable = true;
          # Using default security services: sshd, ssh, polkit, polkit-1, audit, auditd
          # Using default security identifiers: sudo, audit, polkitd, sshd
        };

        # Enable local Loki instance with retention policies
        loki = {
          enable = true;
          retention = {
            enable = true;
            # Security logs retained for 90 days (compliance requirement)
            # System logs retained for 30 days (troubleshooting)
            categoryPeriods = {
              security = "2160h"; # 90 days
              system = "720h"; # 30 days
            };
          };
        };

        # Forward logs to external server for company-wide monitoring
        server.externalEndpoint = "https://loki.ghaflogs.vedenemo.dev/loki/api/v1/push";

        # Enable local retention on hosts and VMs
        localRetention = {
          enable = true;
          maxRetentionDays = 1; # Minimize storage on edge devices
          maxDiskUsage = "500M"; # Limit journal size
        };
      };

      # Disk encryption
      storage.encryption.enable = true;

      # Enable audit
      security.audit.enable = false;

      # Enable power management
      services.power-manager.enable = true;

      # Enable kill switch
      services.kill-switch.enable = true;
    };
  };
}
