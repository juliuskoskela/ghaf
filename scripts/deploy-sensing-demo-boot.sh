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

usage() {
  cat <<'EOF'
Upload and stage the sensing-demo closure without hot-switching the Jetson host.

Usage:
  scripts/deploy-sensing-demo-boot.sh [options]
  scripts/deploy-sensing-demo-boot.sh --check [options]
  scripts/deploy-sensing-demo-boot.sh --promote [options]

Options:
  --target-ip ADDRESS   net-vm LAN address (default: 192.168.88.242)
  --host-ip ADDRESS     Ghaf host address behind net-vm (default: 192.168.100.2)
  --identity PATH       SSH private key (default: ~/.ssh/ghaf-vega)
  --flake TARGET        NixOS flake target
  --reboot              Request a normal reboot after staging
  --check               Validate SSH and the current boot entry without changes
  --promote             Make a successfully booted staged entry persistent
  -h, --help            Show this help

The staged generation is a one-shot systemd-boot entry. If it fails, reset the
board and the following boot returns to the previous default entry. Run
--promote only after the new generation and sensing demo have been verified.
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

deploy_tmpdir=$(mktemp -d)
trap 'rm -rf -- "$deploy_tmpdir"' EXIT
known_hosts_file="$deploy_tmpdir/known_hosts"
ssh_config_file="$deploy_tmpdir/ssh_config"

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
  printf 'Requesting a normal reboot. If VFIO teardown stalls, use the physical Reset button.\n'
  "${ssh_host[@]}" systemctl reboot || true
else
  printf 'Reboot was not requested. Re-run with --reboot or reset the board when ready.\n'
fi
