# Copyright 2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Fix for RCU stall issues during shutdown on NVIDIA Jetson
# Based on analysis showing Plymouth causes shutdown-ramfs generation failures
{
  config,
  lib,
  pkgs,
  ...
}:
{
  # Disable Plymouth which causes shutdown-ramfs generation failures
  boot.plymouth.enable = lib.mkForce false;

  # Ensure proper shutdown sequence
  systemd.services."generate-shutdown-ramfs" = {
    enable = lib.mkDefault false;
    # If we need to keep it enabled, ensure it doesn't hang
    serviceConfig = lib.mkIf config.systemd.services."generate-shutdown-ramfs".enable {
      TimeoutSec = "30s";
      KillMode = "mixed";
    };
  };

  # Add kernel parameters to help with shutdown
  boot.kernelParams = [
    # Reduce RCU stall timeout for faster detection
    "rcupdate.rcu_cpu_stall_timeout=60"
    # Enable more aggressive RCU processing
    "rcu_nocbs=0-11" # All CPUs on Jetson Orin
  ];

  # Ensure clean shutdown for VMs
  systemd.services."stop-all-vms" = {
    description = "Stop all MicroVMs before shutdown";
    wantedBy = [ "shutdown.target" ];
    before = [ "shutdown.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStop = "${pkgs.bash}/bin/bash -c 'for vm in /var/lib/microvms/*; do [ -d \"$vm\" ] && microvm -S \"$(basename \"$vm\")\" || true; done'";
      TimeoutStopSec = "60s";
    };
  };
}
