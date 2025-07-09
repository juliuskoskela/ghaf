# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# TODO: Enable when ghaf.security.sshKeys configuration is available
# Waypipe SSH configuration for GPU VM
{
  config,
  pkgs,
  ...
}:
{
  microvm.shares = [
    {
      tag = "waypipe-ssh-public-key";
      source = config.ghaf.security.sshKeys.waypipeSshPublicKeyDir;
      mountPoint = config.ghaf.security.sshKeys.waypipeSshPublicKeyDir;
      proto = "virtiofs";
    }
  ];

  systemd.services."waypipe-ssh-keygen" =
    let
      uid = "${toString config.ghaf.users.loginUser.uid}";
      pubDir = config.ghaf.security.sshKeys.waypipeSshPublicKeyDir;
      keygenScript = pkgs.writeShellScriptBin "waypipe-ssh-keygen" ''
        set -xeuo pipefail
        mkdir -p /run/waypipe-ssh
        echo -en "\n\n\n" | ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f /run/waypipe-ssh/id_ed25519 -C ""
        chown ${uid}:users /run/waypipe-ssh/*
        cp /run/waypipe-ssh/id_ed25519.pub ${pubDir}/id_ed25519.pub
        chown -R ${uid}:users ${pubDir}
      '';
    in
    {
      enable = true;
      description = "Generate SSH keys for Waypipe";
      path = [ keygenScript ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StandardOutput = "journal";
        StandardError = "journal";
        ExecStart = "${keygenScript}/bin/waypipe-ssh-keygen";
      };
    };
}
