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
    ./nvidia-driver-fix.nix
    ./debug-scripts.nix
  ];

  ghaf = {
    # System
    type = "system-vm";

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
      # NOTE: SSH port also becomes accessible on the network interface
      #       that has been passed through to NetVM
      ssh.daemon.enable = lib.mkDefault true;
      debug.tools.enable = lib.mkDefault true;
      nix-setup.enable = lib.mkDefault true;
    };

    # System
    systemd = {
      enable = true;
      withName = "gpuvm-systemd";
      withAudit = true;
      withHomed = true;
      withLocaled = true;
      withNss = true;
      withResolved = true;
      withTimesyncd = true;
      withDebug = true;
      # withHardenedConfigs = true;
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
    virtualization.microvm.vm-networking = {
      enable = true;
      inherit vmName;
    };

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

      # State directory for Ollama config and keys
      # This creates /var/lib/ollama owned by ghaf:users
      StateDirectory = "ollama";

      # Security hardening
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;

      # Allow access to storage and bind state directory to expected location
      ReadWritePaths = [ "/storage" ];
      BindPaths = [ "/var/lib/ollama:/home/ghaf/.ollama" ];

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
        "HOME=/home/ghaf" # Ensure HOME is set for Ollama
        "LD_LIBRARY_PATH=/run/current-system/sw/lib:/run/opengl-driver/lib"
      ];

      # Pre-start script to ensure proper setup
      ExecStartPre = pkgs.writeShellScript "ollama-pre-start" ''
        # Ensure state directory has correct permissions
        chmod 750 /var/lib/ollama

        # Create models symlink if it doesn't exist
        if [ ! -e /var/lib/ollama/models ]; then
          ln -sf /storage/ai-models /var/lib/ollama/models
        fi
      '';
    };
  };

  systemd = {
    packages = [ pkgs.blueman ];

    # Waypipe SSH key generation can be added if needed

    # Ensure the models directory exists
    tmpfiles.rules = lib.mkIf cfg.ollamaSupport [
      "d /storage/ai-models 0755 ghaf users -"
    ];

    # Create NVIDIA device nodes since modules are built-in
    services.nvidia-devices = {
      description = "Create NVIDIA device nodes";
      wantedBy = [ "multi-user.target" ];
      before = [ "ollama.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "create-nvidia-devices" ''
          # Create device nodes if they don't exist
          [ ! -e /dev/nvidia0 ] && ${pkgs.coreutils}/bin/mknod /dev/nvidia0 c 195 0
          [ ! -e /dev/nvidiactl ] && ${pkgs.coreutils}/bin/mknod /dev/nvidiactl c 195 255
          [ ! -e /dev/nvidia-uvm ] && ${pkgs.coreutils}/bin/mknod /dev/nvidia-uvm c 511 0
          [ ! -e /dev/nvidia-uvm-tools ] && ${pkgs.coreutils}/bin/mknod /dev/nvidia-uvm-tools c 511 1

          # Set permissions
          ${pkgs.coreutils}/bin/chown root:video /dev/nvidia* || true
          ${pkgs.coreutils}/bin/chmod 0660 /dev/nvidia* || true

          # Load UVM if it's a module (might fail if built-in)
          ${pkgs.kmod}/bin/modprobe nvidia-uvm || true
        '';
      };
    };
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

    # Set Ollama environment variables for all users
    variables = lib.mkIf cfg.ollamaSupport {
      OLLAMA_MODELS = "/storage/ai-models";
      OLLAMA_HOST = "0.0.0.0:11434"; # Allow external connections
      # Add CUDA library path - libraries are in system profile
      LD_LIBRARY_PATH = "/run/current-system/sw/lib:/run/opengl-driver/lib";
    };
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

  # vm-networking module will handle all network configuration
  networking = {
    firewall = {
      enable = false; # Disabled for development/debugging
      allowedTCPPorts = lib.mkIf cfg.ollamaSupport [ 11434 ];
    };
  };

  time.timeZone = "UTC";
  system.stateVersion = lib.trivial.release;

  # Set the platform explicitly for aarch64
  nixpkgs.hostPlatform = "aarch64-linux";

  # Override initrd modules to exclude x86-specific modules like sata_nv
  boot.initrd.availableKernelModules = lib.mkForce [
    # Essential modules for ARM/Jetson platforms
    "nvme" # NVMe storage support
    "uas" # USB Attached SCSI
    "usb-storage" # USB storage devices
    "mmc_block" # MMC/SD card support
    "sdhci" # SD Host Controller Interface
    "sdhci-tegra" # Tegra-specific SDHCI
    # Virtio modules for microvm support
    "virtio_mmio"
    "virtio_pci"
    "virtio_blk"
    "9pnet_virtio"
    "9p"
    # Note: virtiofs requires kernel config changes
  ];

  # Blacklist drivers that would interfere with NVIDIA proprietary driver
  boot.blacklistedKernelModules = [ "gk20a" "nouveau" "nvgpu" ];
  
  # Add kernel parameters to prevent driver binding
  boot.kernelParams = [ "modprobe.blacklist=gk20a,nouveau,nvgpu" ];

  # Enable BPMP guest proxy for GPU VM
  boot.kernelPatches = [
    {
      name = "enable-bpmp-guest-proxy";
      patch = null;
      extraStructuredConfig = with lib.kernel; {
        TEGRA_BPMP_GUEST_PROXY = yes;
      };
    }
    {
      name = "disable-gk20a-driver";
      patch = null;
      extraStructuredConfig = with lib.kernel; {
        # Disable the open-source gk20a driver
        TEGRA_GK20A = lib.mkForce no;
        # Also disable nouveau if it's enabled
        DRM_NOUVEAU = lib.mkForce no;
        # Disable DRM Tegra to ensure no conflicts
        DRM_TEGRA = lib.mkForce no;
      };
    }
  ];

  microvm = {
    # Optimize is disabled because when it is enabled, qemu is built without libusb
    optimize.enable = false;
    # tegra234-gpuvm.dts is generated with 4 cpu cores. Update DTS if you change this value.
    vcpu = 4;
    mem = 6000;
    hypervisor = "qemu";
    qemu.package = pkgs.callPackage ./qemu-gpuvm.nix { };

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
        # BPMP guest proxy is created automatically by virt machine
        # The following are VFIO platform devices for GPU passthrough
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
