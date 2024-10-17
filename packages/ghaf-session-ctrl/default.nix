# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  lib,
  labwc,
  gtklock,
  writeShellApplication,
  writeText,
  ...
}:
let
  gtklockStyle = writeText "gtklock.css" ''
    window {
        background: rgba(18, 18, 18, 1);
        color: #fff;
    }
    button {
        box-shadow: none;
        border-radius: 5px;
        border: none;
        background: #171717;
    }
    entry {
        background-color: #232323;
        border: 1px solid rgba(46, 46, 46, 1);
        color: #fff;
    }
    entry:focus {
        box-shadow: none;
        border: 1px solid rgba(223, 92, 55, 1);
    }
  '';
in
writeShellApplication {
  name = "ghaf-session-ctrl";

  runtimeInputs = [
      labwc
      gtklock
    ];
    
  text = ''
    logout() {
      labwc --exit
    }

    lock() {
      gtklock -s ${gtklockStyle}
    }

    case "$1" in
      logout)
          logout
          ;;
      lock)
          lock
          ;;
      *)
          echo "Usage: $0 {logout|lock}"
          exit 1
          ;;
      esac
  '';

  meta = {
    description = "Script to control current ghaf user session.";
    platforms = lib.platforms.linux;
  };
}
