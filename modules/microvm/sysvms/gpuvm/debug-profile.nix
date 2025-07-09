# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Debug profile configuration for GPU VM
# This module provides debug settings that can be enabled via host configuration
{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.ghaf.gpuvm.debug = {
    enable = lib.mkEnableOption "debug mode for GPU VM";
  };

  config = lib.mkIf config.ghaf.gpuvm.debug.enable {
    # Enable debug profiles
    ghaf.profiles.debug.enable = true;

    # Enable development tools
    ghaf.development = {
      ssh.daemon.enable = true;
      debug.tools.enable = true;
      nix-setup.enable = true;
    };

    # Enable systemd debug features
    ghaf.systemd = {
      withAudit = true;
      withDebug = true;
    };

    # Enable writable store overlay for development
    microvm.writableStoreOverlay = "/nix/.rw-store";

    # Debug packages
    environment.systemPackages =
      with pkgs;
      [
        # Graphics debugging
        glxinfo
        libva-utils
        glib

        # System debugging
        htop
        iotop
        strace
        gdb

        # Network debugging
        tcpdump
        wireshark-cli
      ]
      # MitmProxy UI when available
      ++ lib.optional (config.ghaf.virtualization.microvm.idsvm.mitmproxy.enable or false
      ) pkgs.mitmweb-ui;
  };
}
