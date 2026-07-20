# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  lib,
  ...
}:
{
  imports = [ ./jetson-gpu-base.nix ];

  # Synthetic RGB frames prove the producer/processor boundary without camera
  # passthrough. Replace the source when CSI/USB camera ownership is available.
  ghaf.sensing.demo.enable = lib.mkDefault true;
}
