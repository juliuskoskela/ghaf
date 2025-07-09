# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# TODO: Enable when these services are implemented
# Optional services for GPU VM
{
  pkgs,
  ...
}:
{
  # Reference services
  ghaf.reference.services.ollama = true;

  # XDG items support
  ghaf.xdgitems.enable = true;

  # Control panel application
  environment.systemPackages = with pkgs; [
    ctrl-panel
  ];
}
