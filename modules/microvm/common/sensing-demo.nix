# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.sensing.demo;
in
{
  _file = ./sensing-demo.nix;

  options.ghaf.sensing.demo = {
    enable = lib.mkEnableOption "the synthetic RGB sensing VM demo";

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Address for the sensing demo observation service.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "TCP port for the sensing demo observation service.";
    };

    framesPerSecond = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Synthetic RGB scene capture rate.";
    };

    staleAfterSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Maximum observation age before the service reports it as stale.";
    };

    acceleratorDevice = lib.mkOption {
      type = lib.types.str;
      default = "/dev/nvgpu/igpu0";
      description = "GPU device whose availability is reported by the health endpoint.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to allow the observation service port through the guest firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.sensing-demo ];
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    systemd.services.sensing-demo = {
      description = "Ghaf synthetic RGB producer and semantic receiver demo";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          "${lib.getExe pkgs.sensing-demo}"
          "--bind ${lib.escapeShellArg cfg.listenAddress}"
          "--port ${toString cfg.port}"
          "--frames-per-second ${toString cfg.framesPerSecond}"
          "--stale-after-seconds ${toString cfg.staleAfterSeconds}"
          "--accelerator-device ${lib.escapeShellArg cfg.acceleratorDevice}"
        ];
        Restart = "on-failure";
        RestartSec = 2;
        DynamicUser = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        CapabilityBoundingSet = "";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
      };
    };
  };
}
