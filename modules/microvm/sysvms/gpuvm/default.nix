# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ inputs }:
{
  imports = [
    (import ./host.nix { inherit inputs; })

    # Optional modules - enable when dependencies are resolved:
    # ./waypipe-ssh.nix       # TODO: Requires ghaf.security.sshKeys configuration
    # ./givc-integration.nix  # TODO: Requires GIVC configuration dependencies
    # ./debug-profile.nix     # TODO: Enable for development/debugging
    # ./optional-services.nix # TODO: Requires ctrl-panel package and xdgitems
  ];
}
