# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Function to generate NVIDIA Jetson Orin flash script
hostConfiguration:
let
  inherit (hostConfiguration) pkgs;
  inherit (hostConfiguration.config.ghaf.hardware.nvidia.orin.flashScriptOverrides) preFlashCommands;

  baseFlashScript = pkgs.nvidia-jetpack.mkFlashScript pkgs.nvidia-jetpack.flash-tools {
    inherit preFlashCommands;
  };

  patchFlashScript =
    builtins.replaceStrings
      [
        "@pzstd@"
        "@sed@"
        "@patch@"
        "@l4tVersion@"
      ]
      [
        "${pkgs.zstd}/bin/pzstd"
        "${pkgs.gnused}/bin/sed"
        "${pkgs.patch}/bin/patch"
        "${pkgs.nvidia-jetpack.l4tVersion}"
      ];

  flashScript = patchFlashScript baseFlashScript;
in
pkgs.writeShellApplication {
  name = "flash-ghaf";
  text = flashScript;
}
