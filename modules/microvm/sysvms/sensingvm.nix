# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  inputs,
  lib,
  ...
}:
let
  cfg = config.ghaf.virtualization.microvm.sensingvm;
  vmName = "sensing-vm";
in
{
  _file = ./sensingvm.nix;

  options.ghaf.virtualization.microvm.sensingvm = {
    enable = lib.mkEnableOption "the sensing VM";

    evaluatedConfig = lib.mkOption {
      type = lib.types.nullOr lib.types.unspecified;
      default = null;
      description = "Pre-evaluated NixOS configuration for sensing-vm.";
    };

    extraNetworking = lib.mkOption {
      type = lib.types.networking;
      default = { };
      description = "Additional sensing-vm networking configuration.";
    };
  };

  config = lib.mkMerge [
    {
      ghaf.virtualization.microvm.sysvm.vms.sensingvm = {
        inherit vmName;
        inherit (cfg) enable evaluatedConfig extraNetworking;
      };
    }
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.evaluatedConfig != null;
          message = ''
            ghaf.virtualization.microvm.sensingvm.evaluatedConfig must be set.
            Use a profile that provides sensingvmBase (orin).
          '';
        }
      ];

      ghaf.common = {
        extraNetworking.hosts.${vmName} = cfg.extraNetworking;
        policies = lib.mkIf cfg.evaluatedConfig.config.ghaf.givc.policyClient.enable {
          ${vmName} = cfg.evaluatedConfig.config.ghaf.givc.policyClient.policies;
        };
        spire.agents = lib.mkIf cfg.evaluatedConfig.config.ghaf.security.spire.agent.enable {
          ${vmName} = {
            inherit (cfg.evaluatedConfig.config.ghaf.security.spire.agent) nodeAttestationMode workloads;
          };
        };
      };

      microvm.vms.${vmName} = {
        autostart = !config.ghaf.microvm-boot.enable;
        restartIfChanged = false;
        inherit (inputs) nixpkgs;
        inherit (cfg) evaluatedConfig;
      };
    })
  ];
}
