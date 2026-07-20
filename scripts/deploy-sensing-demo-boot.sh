#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

target_ip="192.168.88.242"
host_ip="192.168.100.2"
flake_target=".#nvidia-jetson-orin-agx-sensing-demo-debug-from-x86_64"
identity_file="${HOME}/.ssh/ghaf-vega"
action="stage"
reboot_after_stage=false
uart_device="${GHAF_UART_DEVICE:-/dev/ttyACM0}"
uart_user="${GHAF_UART_USER:-ghaf}"
uart_password="${GHAF_UART_PASSWORD:-ghaf}"
uart_log="${GHAF_UART_LOG:-}"

usage() {
  cat <<'EOF'
Upload and stage the sensing-demo closure without hot-switching the Jetson host.

Usage:
  scripts/deploy-sensing-demo-boot.sh [options]
  scripts/deploy-sensing-demo-boot.sh --check [options]
  scripts/deploy-sensing-demo-boot.sh --uart-reboot [options]
  scripts/deploy-sensing-demo-boot.sh --promote [options]

Options:
  --target-ip ADDRESS   net-vm LAN address (default: 192.168.88.242)
  --host-ip ADDRESS     Ghaf host address behind net-vm (default: 192.168.100.2)
  --identity PATH       SSH private key (default: ~/.ssh/ghaf-vega)
  --flake TARGET        NixOS flake target
  --reboot              Stage, reboot through UART, and monitor until login
  --uart-reboot         Reboot an already-staged update through UART
  --uart-device PATH    Debug UART device (default: /dev/ttyACM0)
  --uart-user USER      Debug-console user (default: ghaf)
  --uart-log PATH       UART capture log (default: a timestamped /tmp file)
  --check               Validate SSH and the current boot entry without changes
  --promote             Make a successfully booted staged entry persistent
  -h, --help            Show this help

The staged generation is a one-shot systemd-boot entry. If it fails, reset the
board and the following boot returns to the previous default entry. Run
--promote only after the new generation and sensing demo have been verified.

The UART password is read from GHAF_UART_PASSWORD and defaults to the debug
image password "ghaf". UART output is printed directly and the command exits
when the new ghaf-host login prompt appears.
EOF
}

while (($# > 0)); do
  case "$1" in
  --target-ip)
    target_ip="${2:?--target-ip requires a value}"
    shift 2
    ;;
  --host-ip)
    host_ip="${2:?--host-ip requires a value}"
    shift 2
    ;;
  --identity)
    identity_file="${2:?--identity requires a value}"
    shift 2
    ;;
  --flake)
    flake_target="${2:?--flake requires a value}"
    shift 2
    ;;
  --reboot)
    reboot_after_stage=true
    shift
    ;;
  --uart-reboot)
    action="uart-reboot"
    reboot_after_stage=true
    shift
    ;;
  --uart-device)
    uart_device="${2:?--uart-device requires a value}"
    shift 2
    ;;
  --uart-user)
    uart_user="${2:?--uart-user requires a value}"
    shift 2
    ;;
  --uart-log)
    uart_log="${2:?--uart-log requires a value}"
    shift 2
    ;;
  --check)
    action="check"
    shift
    ;;
  --promote)
    action="promote"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    printf 'Unknown option: %s\n\n' "$1" >&2
    usage >&2
    exit 2
    ;;
  esac
done

if [[ ! -f $identity_file ]]; then
  printf 'SSH identity does not exist: %s\n' "$identity_file" >&2
  exit 1
fi

for command_name in nixos-rebuild ssh ssh-keygen; do
  if ! command -v "$command_name" >/dev/null; then
    printf 'Required command is unavailable: %s\n' "$command_name" >&2
    exit 1
  fi
done

if [[ $reboot_after_stage == true ]]; then
  for command_name in runscript stty tee; do
    if ! command -v "$command_name" >/dev/null; then
      printf 'Required command is unavailable: %s\n' "$command_name" >&2
      exit 1
    fi
  done
  if [[ ! -c $uart_device || ! -r $uart_device || ! -w $uart_device ]]; then
    printf 'UART device is not accessible: %s\n' "$uart_device" >&2
    printf 'Check the micro-USB debug cable and dialout-group membership.\n' >&2
    exit 1
  fi
fi

deploy_tmpdir=$(mktemp -d)
trap 'rm -rf -- "$deploy_tmpdir"' EXIT
known_hosts_file="$deploy_tmpdir/known_hosts"
ssh_config_file="$deploy_tmpdir/ssh_config"

reboot_via_uart() {
  if [[ -z $uart_log ]]; then
    uart_log="/tmp/ghaf-jetson-reboot-$(date -u +%Y%m%dT%H%M%SZ).log"
  fi
  mkdir -p -- "$(dirname -- "$uart_log")"
  uart_script="$deploy_tmpdir/reboot.runscript"
  cat >"$uart_script" <<'UART_SCRIPT'
verbose on
timeout 360

send ""
sleep 1
send ""
sleep 1
send ""
expect {
  "login:" goto login
  "$ " goto user_shell
  "# " goto root_shell
  timeout 20 goto failed
}

login:
send "$(GHAF_UART_LOGIN)"
expect {
  "Password:" send "$(GHAF_UART_PASS)"
  timeout 15 goto failed
}
expect {
  "$ " goto user_shell
  "# " goto root_shell
  "Login incorrect" goto failed
  timeout 15 goto failed
}

user_shell:
send "sudo -S -p UART-SUDO-PASSWORD: systemctl reboot"
expect {
  "UART-SUDO-PASSWORD:" goto sudo_password
  "Rebooting" goto monitor
  timeout 5 goto monitor
}

sudo_password:
send "$(GHAF_UART_PASS)"
sleep 2
goto monitor

root_shell:
send "systemctl reboot"
sleep 2
goto monitor

monitor:
print "Reboot requested; monitoring UART until the new login prompt."
expect {
  "ghaf-host login:" goto booted
  timeout 300 goto boot_timeout
}

booted:
print "New ghaf-host login prompt detected; UART monitor complete."
exit 0

boot_timeout:
print "Timed out waiting for the new ghaf-host login prompt."
exit 3

failed:
print "UART automation could not reach a shell; no reboot was requested."
exit 2
UART_SCRIPT

  export GHAF_UART_LOGIN="$uart_user"
  export GHAF_UART_PASS="$uart_password"
  stty \
    --file "$uart_device" \
    raw \
    -echo \
    115200 \
    cs8 \
    -cstopb \
    -parenb \
    -crtscts \
    -ixon \
    -ixoff

  printf 'UART: %s at 115200 8N1, no flow control\n' "$uart_device"
  printf 'Capture log: %s\n' "$uart_log"
  printf 'The monitor exits automatically at the new ghaf-host login prompt.\n\n'

  # runscript is minicom's non-interactive script engine. Its verbose stream is
  # stderr; tee keeps that stream visible while recording it without a pager.
  # Reading and writing the same character device is intentional full-duplex I/O.
  # shellcheck disable=SC2094
  runscript "$uart_script" \
    <"$uart_device" \
    >"$uart_device" \
    2> >(tee -a -- "$uart_log" >&2)
}

if ! ssh-keygen -F "$target_ip" >"$known_hosts_file"; then
  printf 'No trusted SSH host key exists for net-vm at %s.\n' "$target_ip" >&2
  printf 'Connect to it once and verify its fingerprint before retrying.\n' >&2
  exit 1
fi

internal_host_key=$(
  ssh \
    -F /dev/null \
    -i "$identity_file" \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    "root@$target_ip" \
    "ssh-keyscan -T 5 -t ed25519 '$host_ip' 2>/dev/null"
)
if [[ -z $internal_host_key ]]; then
  printf 'Could not obtain the Ghaf host key through authenticated net-vm.\n' >&2
  exit 1
fi
printf '%s\n' "$internal_host_key" >>"$known_hosts_file"

cat >"$ssh_config_file" <<EOF
Host ghaf-netvm-stage
  HostName $target_ip
  User root
  IdentityFile $identity_file
  IdentitiesOnly yes
  BatchMode yes
  ConnectTimeout 8
  StrictHostKeyChecking yes
  UserKnownHostsFile $known_hosts_file

Host ghaf-host-stage
  HostName $host_ip
  User root
  IdentityFile $identity_file
  IdentitiesOnly yes
  BatchMode yes
  ConnectTimeout 8
  ProxyJump ghaf-netvm-stage
  StrictHostKeyChecking yes
  UserKnownHostsFile $known_hosts_file
EOF

ssh_host=(ssh -F "$ssh_config_file" ghaf-host-stage)
"${ssh_host[@]}" true

if [[ $action == "uart-reboot" ]]; then
  "${ssh_host[@]}" bash -s <<'REMOTE_REBOOT_CHECK'
set -euo pipefail

entry=/boot/loader/entries/ghaf-staged.conf
if [[ ! -f "$entry" ]]; then
  printf 'No staged loader entry exists: %s\n' "$entry" >&2
  exit 1
fi
boot_status=$(bootctl --esp-path=/boot status --no-pager)
if [[ "$boot_status" != *"OneShot Entry: ghaf-staged.conf"* ]]; then
  printf 'ghaf-staged.conf is not selected as the one-shot entry.\n' >&2
  exit 1
fi
printf 'Verified staged one-shot entry; proceeding with UART reboot.\n'
REMOTE_REBOOT_CHECK
  reboot_via_uart
  exit 0
fi

if [[ $action == "check" ]]; then
  "${ssh_host[@]}" bash -s <<'REMOTE_CHECK'
set -euo pipefail

current_system=$(readlink -f /run/current-system)
source_entry=""
for candidate in /boot/loader/entries/*.conf; do
  [[ "$candidate" == */ghaf-staged.conf ]] && continue
  if grep -Fq "init=$current_system/init" "$candidate"; then
    source_entry="$candidate"
    break
  fi
done
if [[ -z "$source_entry" ]]; then
  printf 'Could not find the loader entry for the running generation: %s\n' "$current_system" >&2
  exit 1
fi
if ! grep -Eq '^devicetree[[:space:]]+' "$source_entry"; then
  printf 'Loader entry has no devicetree directive: %s\n' "$source_entry" >&2
  exit 1
fi
while read -r esp_path; do
  [[ -n "$esp_path" ]] || continue
  if [[ ! -f "/boot/${esp_path#/}" ]]; then
    printf 'Referenced ESP file is missing: %s\n' "$esp_path" >&2
    exit 1
  fi
done < <(awk '$1 == "linux" || $1 == "initrd" || $1 == "devicetree" { print $2 }' "$source_entry")

printf 'Running system: %s\n' "$current_system"
printf 'Validated entry: %s\n' "$source_entry"
cat "$source_entry"
REMOTE_CHECK
  exit 0
fi

if [[ $action == "promote" ]]; then
  "${ssh_host[@]}" bash -s <<'REMOTE_PROMOTE'
set -euo pipefail

entry=/boot/loader/entries/ghaf-staged.conf
current_system=$(readlink -f /run/current-system)

if [[ ! -f "$entry" ]]; then
  printf 'Staged boot entry is missing: %s\n' "$entry" >&2
  exit 1
fi
if ! grep -Fq "init=$current_system/init" "$entry"; then
  printf 'Refusing promotion: the running system is not the staged entry.\n' >&2
  printf 'Running: %s\n' "$current_system" >&2
  exit 1
fi

bootctl --esp-path=/boot set-default ghaf-staged.conf
printf 'Promoted staged generation: %s\n' "$current_system"
bootctl --esp-path=/boot status --no-pager
REMOTE_PROMOTE
  exit 0
fi

old_system=$("${ssh_host[@]}" readlink -f /run/current-system)
printf 'Running generation: %s\n' "$old_system"
printf 'Building, copying, and installing the new profile for the next boot...\n'

export NIX_SSHOPTS="-F $ssh_config_file"
nixos-rebuild boot \
  --flake "$flake_target" \
  --target-host root@ghaf-host-stage \
  --no-reexec \
  --builders ''

new_system=$("${ssh_host[@]}" readlink -f /nix/var/nix/profiles/system)
if [[ -z $new_system || $new_system == "$old_system" ]]; then
  printf 'The system profile did not advance; refusing to stage a reboot.\n' >&2
  exit 1
fi
printf 'Staged profile:     %s\n' "$new_system"

"${ssh_host[@]}" bash -s -- "$new_system" <<'REMOTE_STAGE'
set -euo pipefail

new_system="$1"
current_system=$(readlink -f /run/current-system)
entries_dir=/boot/loader/entries
staged_entry="$entries_dir/ghaf-staged.conf"

case "$new_system" in
  /nix/store/*-nixos-system-ghaf-host-*) ;;
  *)
    printf 'Unexpected target system path: %s\n' "$new_system" >&2
    exit 1
    ;;
esac
if [[ ! -x "$new_system/init" ]]; then
  printf 'Target init is unavailable: %s/init\n' "$new_system" >&2
  exit 1
fi

source_entry=""
for candidate in "$entries_dir"/*.conf; do
  [[ "$candidate" == "$staged_entry" ]] && continue
  if grep -Fq "init=$current_system/init" "$candidate"; then
    source_entry="$candidate"
    break
  fi
done
if [[ -z "$source_entry" ]]; then
  printf 'Could not find the loader entry for the running generation: %s\n' "$current_system" >&2
  exit 1
fi
if ! grep -Eq '^devicetree[[:space:]]+' "$source_entry"; then
  printf 'Known-good loader entry has no devicetree directive: %s\n' "$source_entry" >&2
  exit 1
fi

while read -r esp_path; do
  [[ -n "$esp_path" ]] || continue
  if [[ ! -f "/boot/${esp_path#/}" ]]; then
    printf 'Referenced ESP file is missing: %s\n' "$esp_path" >&2
    exit 1
  fi
done < <(awk '$1 == "linux" || $1 == "initrd" || $1 == "devicetree" { print $2 }' "$source_entry")

staged_tmp=$(mktemp "$entries_dir/.ghaf-staged.XXXXXX")
trap 'rm -f -- "$staged_tmp"' EXIT
awk -v new_init="$new_system/init" -v new_title="Ghaf staged $(basename "$new_system")" '
  $1 == "title" {
    print "title " new_title
    next
  }
  $1 == "options" {
    replaced = 0
    for (field = 2; field <= NF; field++) {
      if ($field ~ /^init=\/nix\/store\//) {
        $field = "init=" new_init
        replaced = 1
      }
    }
    if (!replaced) {
      exit 42
    }
  }
  { print }
' "$source_entry" >"$staged_tmp"

if ! grep -Fq "init=$new_system/init" "$staged_tmp"; then
  printf 'Generated loader entry does not reference the staged init.\n' >&2
  exit 1
fi
if ! grep -Eq '^devicetree[[:space:]]+' "$staged_tmp"; then
  printf 'Generated loader entry lost its devicetree directive.\n' >&2
  exit 1
fi

if [[ -f "$staged_entry" ]]; then
  cp -a -- "$staged_entry" "$staged_entry.$(date -u +%Y%m%dT%H%M%SZ).bak"
fi
chmod 0644 "$staged_tmp"
mv -f -- "$staged_tmp" "$staged_entry"
trap - EXIT

# One-shot is deliberate: an unsuccessful boot automatically falls back to the
# previous default entry after the board is reset again.
bootctl --esp-path=/boot set-oneshot ghaf-staged.conf

printf '\nStaged one-shot loader entry from %s:\n' "$source_entry"
cat "$staged_entry"
printf '\nBoot status:\n'
bootctl --esp-path=/boot status --no-pager
REMOTE_STAGE

printf '\nUpload and one-shot boot staging completed successfully.\n'
printf 'If the next boot fails, reset the board once more to return to the old default.\n'

if [[ $reboot_after_stage == true ]]; then
  reboot_via_uart
else
  printf 'Reboot was not requested. Re-run with --reboot when ready.\n'
fi
