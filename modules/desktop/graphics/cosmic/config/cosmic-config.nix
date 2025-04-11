# Copyright 2022-2025 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  lib,
  pkgs,
  ...
}:

pkgs.stdenv.mkDerivation rec {
  pname = "ghaf-cosmic-config";
  version = "0.1";

  phases = [
    "unpackPhase"
    "installPhase"
    "postInstall"
  ];

  src = ./.;

  nativeBuildInputs = [ pkgs.yq-go ];

  unpackPhase = ''
    mkdir -p cosmic-unpacked

    # Process the YAML configuration
    for entry in $(yq e 'keys | .[]' $src/cosmic-config.yaml); do
      mkdir -p "cosmic-unpacked/$entry/v1"

      for subentry in $(yq e ".\"$entry\" | keys | .[]" "$src/cosmic-config.yaml"); do
        content=$(yq e --unwrapScalar=false ".\"$entry\".\"$subentry\"" $src/cosmic-config.yaml | grep -vE '^\s*\|')
        echo -ne "$content" > "cosmic-unpacked/$entry/v1/$subentry"
      done
    done
  '';

  installPhase = ''
    mkdir -p $out/share/cosmic
    cp -rf cosmic-unpacked/* $out/share/cosmic/
    rm -rf cosmic-unpacked
  '';

  postInstall = ''
    substituteInPlace $out/share/cosmic/com.system76.CosmicBackground/v1/all \
    --replace-fail "None" "Path(\"${pkgs.ghaf-artwork}/ghaf-desert-sunset.jpg\")"
    substituteInPlace $out/share/cosmic/com.system76.CosmicSettings.Shortcuts/v1/system_actions \
    --replace-fail 'VolumeLower: ""' 'VolumeLower: "pamixer --unmute --decrease 5 && ${pkgs.pulseaudio}/bin/paplay ${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/audio-volume-change.oga"' \
    --replace-fail 'VolumeRaise: ""' 'VolumeRaise: "pamixer --unmute --increase 5 && ${pkgs.pulseaudio}/bin/paplay ${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/audio-volume-change.oga"'
  '';

  meta = with lib; {
    description = "Installs default Ghaf COSMIC configuration";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
}
