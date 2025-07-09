# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  inputs,
  lib,
  pkgs,
  vmName,
  cfg,
  ...
}:
let
  inherit (import ../../../../lib/launcher.nix { inherit pkgs lib; }) rmDesktopEntries;

  # Ollama package for Jetson
  ollama-jetson = import ./packages/ollama-jetson.nix { inherit pkgs lib; };

  # A list of applications from all AppVMs
  # TODO: This should be passed from host if needed
  enabledVms = { };
  virtualApps = [ ];

  # Launchers for all virtualized applications that run in AppVMs
  virtualLaunchers = map (app: rec {
    inherit (app) name;
    inherit (app) description;
    vm = app.vmName;
    path = "${pkgs.givc-cli}/bin/givc-cli start app --vm ${vm} ${app.givcName}";
    inherit (app) icon;
  }) virtualApps;

  # Launchers for all desktop, non-virtualized applications that run in the GPUVM
  gpuvmLaunchers = map (app: {
    inherit (app) name;
    inherit (app) description;
    path = app.command;
    inherit (app) icon;
  }) cfg.applications;
in
{
  imports = [
    inputs.self.nixosModules.profiles
    inputs.preservation.nixosModules.preservation
    inputs.self.nixosModules.givc
    inputs.self.nixosModules.vm-modules
  ];

  ghaf = {
    # Profiles
    profiles = {
      debug.enable = false;
      graphics.enable = true;
    };
    users.loginUser.enable = true;

    # Temporary solution
    users.admin.extraGroups = [
      "audio"
      "video"
    ];

    development = {
      ssh.daemon.enable = false;
      debug.tools.enable = false;
      nix-setup.enable = false;
    };

    # System
    type = "system-vm";
    systemd = {
      enable = true;
      withName = "gpuvm-systemd";
      withAudit = false;
      withHomed = true;
      withLocaled = true;
      withNss = true;
      withResolved = true;
      withTimesyncd = true;
      withDebug = false;
      withHardenedConfigs = true;
    };

    # Storage
    storagevm = {
      enable = true;
      name = vmName;
    };

    # Networking
    # TODO: Temporarily disabled because of the following:
    # error: attribute 'gpu-vm' missing
    #  at /nix/store/.../modules/microvm/common/vm-networking.nix:73:43:
    #      72|       links."10-${cfg.interfaceName}" = {
    #      73|         matchConfig.PermanentMACAddress = hosts.${cfg.vmName}.mac;
    #        |                                           ^
    #      74|         linkConfig.Name = cfg.interfaceName;
    # virtualization.microvm.vm-networking = {
    #   enable = true;
    #   inherit vmName;
    # };

    # Services
    graphics = {
      launchers = gpuvmLaunchers ++ virtualLaunchers;
      labwc = {
        autolock.enable = false;
        autologinUser = "ghaf";
        securityContext = map (vm: {
          identifier = vm.name;
          color = vm.borderColor;
        }) (lib.attrsets.mapAttrsToList (name: vm: { inherit name; } // vm) enabledVms);
      };
    };

    # Logging
    logging.client.enable = false;

    services = {
      disks = {
        enable = true;
        fileManager = "${pkgs.pcmanfm}/bin/pcmanfm";
      };
    };
  };

  services = {

    # Suspend inside Qemu causes segfault
    # See: https://gitlab.com/qemu-project/qemu/-/issues/2321
    logind.lidSwitch = "ignore";

    # We dont enable services.blueman because it adds blueman desktop entry
    dbus.packages = [ pkgs.blueman ];

  };

  # Ollama service
  systemd.services.ollama = lib.mkIf cfg.ollamaSupport {
    description = "Ollama AI Model Service";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${ollama-jetson}/bin/ollama serve";
      Restart = "always";
      RestartSec = "10";
      User = "ghaf";
      Group = "users";

      # Security hardening
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      ReadWritePaths = [ "/storage" ];

      # GPU access
      SupplementaryGroups = [
        "video"
        "render"
      ];
      DeviceAllow = [
        "/dev/dri/renderD128"
        "/dev/nvidia*"
      ];

      # Environment
      Environment = [
        "OLLAMA_MODELS=/storage/ai-models"
        "CUDA_VISIBLE_DEVICES=0"
      ];
    };
  };

  systemd = {
    packages = [ pkgs.blueman ];

    # Waypipe SSH key generation can be added if needed

    # Ensure the models directory exists
    tmpfiles.rules = lib.mkIf cfg.ollamaSupport [
      "d /storage/ai-models 0755 ghaf users -"
    ];
  };

  environment = {
    systemPackages =
      (rmDesktopEntries [
        pkgs.networkmanagerapplet
        pkgs.gnome-calculator
        pkgs.sticky-notes
      ])
      ++ [
        pkgs.bt-launcher
        pkgs.pamixer
        pkgs.eww
        pkgs.wlr-randr
        ollama-jetson
        pkgs.nvidia-jetpack.l4t-tools
        pkgs.nvidia-jetpack.l4t-cuda
        pkgs.nvidia-jetpack.l4t-core
        pkgs.nvidia-jetpack.l4t-3d-core
        pkgs.nvidia-jetpack.l4t-firmware
        pkgs.nvidia-jetpack.l4t-wayland
      ]
      # Debug packages can be enabled if needed
      ++ lib.optionals false [
        pkgs.glxinfo
        pkgs.libva-utils
        pkgs.glib
      ];
  };

  # User configuration
  users.users.ghaf = {
    createHome = lib.mkForce true;
    home = lib.mkForce "/home/ghaf";
    extraGroups = [
      "video"
      "render"
      "input"
    ];
  };

  # Networking configuration
  networking = {
    hostName = vmName;
    firewall = {
      enable = false;
      allowedTCPPorts = lib.mkIf cfg.ollamaSupport [ 11434 ];
    };
    useNetworkd = true;
  };

  # Network interface configuration
  microvm.interfaces = [
    {
      type = "tap";
      id = "ethint0";
      mac = "02:00:00:01:01:05"; # GPU VM MAC address
    }
  ];

  systemd.network = {
    enable = true;
    networks."10-ethint0" = {
      matchConfig.MACAddress = "02:00:00:01:01:05";
      addresses = [
        {
          Address = "192.168.101.5/24";
        }
      ];
      routes = lib.mkForce [
        {
          Gateway = "192.168.101.1";
        }
      ];
      linkConfig.RequiredForOnline = "routable";
    };
  };

  services.resolved.enable = true;

  time.timeZone = "UTC";
  system.stateVersion = lib.trivial.release;

  # nixpkgs platform is set by the host

  microvm = {
    # Optimize is disabled because when it is enabled, qemu is built without libusb
    optimize.enable = false;
    # tegra234-gpuvm.dts is generated with 4 cpu cores. Update DTS if you change this value.
    vcpu = 4;
    mem = 6000;
    hypervisor = "qemu";

    # We add these kernel parameters, in order that the BPMP in the VM turn off
    # the clocks that are not used, and the power domain that are not used in the VM
    # but are used in the host.
    kernelParams = [ "clk_ignore_unused pd_ignore_unused" ];

    shares = [
      {
        tag = "ro-store";
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        proto = "virtiofs";
      }
    ];
    # writableStoreOverlay can be enabled for debug if needed

    qemu = {
      # Devices to passthrough to the GPU-VM
      extraArgs = [
        # VSOCK for inter-VM communication
        "-device"
        "vhost-vsock-pci,guest-cid=${toString cfg.vsockCID}"
        # BPMP guest proxy - required for GPU passthrough
        "-device"
        "tegra234-bpmp-guest"
        "-device"
        "vfio-platform,host=60000000.vm_hs_p,mmio-base=0x60000000"
        "-device"
        "vfio-platform,host=80000000.vm_cma_p,mmio-base=0x80000000"
        "-device"
        "vfio-platform,host=100000000.vm_cma_vram_p,mmio-base=0x100000000"
        "-device"
        "vfio-platform,host=17000000.gpu"
        "-device"
        "vfio-platform,host=13e00000.host1x_pt"
        "-device"
        "vfio-platform,host=15340000.vic"
        "-device"
        "vfio-platform,host=15480000.nvdec"
        "-device"
        "vfio-platform,host=15540000.nvjpg"
        "-device"
        "vfio-platform,host=d800000.dce"
        "-device"
        "vfio-platform,host=13800000.display"
      ];

      machine =
        {
          # Use the same machine type as the host
          x86_64-linux = "q35";
          aarch64-linux = "virt";
        }
        .${pkgs.stdenv.hostPlatform.system};
    };
  };
}
