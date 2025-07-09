# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# TODO: Enable when GIVC configuration dependencies are resolved
# GIVC (Ghaf Inter-VM Communication) integration for GPU VM
{
  config,
  pkgs,
  ...
}:
{
  ghaf.givc.guivm.enable = true;

  services.acpid = {
    enable = true;
    lidEventCommands = ''
      case "$1" in
        "button/lid LID close")
          # Lock sessions
          ${pkgs.systemd}/bin/loginctl lock-sessions

          # Switch off display, if wayland is running
          if ${pkgs.procps}/bin/pgrep -fl "wayland" > /dev/null; then
            wl_running=1
            WAYLAND_DISPLAY=/run/user/${builtins.toString config.ghaf.users.loginUser.uid}/wayland-0 ${pkgs.wlopm}/bin/wlopm --off '*'
          else
            wl_running=0
          fi

          # Initiate Suspension
          ${pkgs.givc-cli}/bin/givc-cli ${config.ghaf.givc.cliArgs} suspend

          # Enable display
          if [ "$wl_running" -eq 1 ]; then
            WAYLAND_DISPLAY=/run/user/${builtins.toString config.ghaf.users.loginUser.uid}/wayland-0 ${pkgs.wlopm}/bin/wlopm --on '*'
          fi
          ;;
        "button/lid LID open")
          # Command to run when the lid is opened
          ;;
      esac
    '';
  };
}
