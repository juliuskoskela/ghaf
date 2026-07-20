# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  lib,
  ...
}:
{
  imports = [ ./jetson-gpu-base.nix ];

  # Synthetic RGB frames prove the producer/processor boundary without camera
  # passthrough. Raw-frame export remains opt-in for explicit debug targets.
  ghaf.sensing.demo.enable = lib.mkDefault true;
}
