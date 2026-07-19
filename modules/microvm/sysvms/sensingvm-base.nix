# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  lib,
  ...
}:
{
  imports = [ ./jetson-gpu-base.nix ];

  # Synthetic capture proves the sensing boundary without requiring camera
  # passthrough. Replace the source behind this interface when CSI/USB camera
  # ownership is available.
  ghaf.sensing.demo.enable = lib.mkDefault true;
}
