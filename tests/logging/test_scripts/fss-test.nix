# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# FSS (Forward Secure Sealing) Hardware Test Script
#
# Verifies FSS functionality on a deployed Ghaf system. This script checks
# that journal sealing is properly configured and working, providing
# tamper-evident logging via HMAC-SHA256 chains.
#
# Usage:
#   Build:   nix build .#checks.x86_64-linux.fss-test
#   Deploy:  scp result/bin/fss-test root@ghaf-host:/tmp/
#   Run:     ssh root@ghaf-host /tmp/fss-test
#
# Or deploy with system configuration:
#   environment.systemPackages = [ pkgs.fss-test ];
#   Then run: sudo fss-test
#
# Tests performed:
#   1. FSS setup service status - verifies journal-fss-setup ran
#   2. Sealing key existence - checks /var/log/journal/<machine-id>/fss
#   3. Verification key extraction - for offline log verification
#   4. Initialization sentinel - prevents re-initialization
#   5. Journal integrity verification - runs journalctl --verify
#   6. Verification timer status - periodic integrity checks
#   7. Audit rules configuration - monitors FSS key access
#
# Exit codes:
#   0 - All critical tests passed (warnings may be present)
#   1 - One or more critical tests failed
#
{
  writeShellApplication,
  coreutils,
  systemd,
  gnugrep,
}:
let
  verifyClassifierLib = builtins.readFile ../../../modules/common/logging/fss-verify-classifier.sh;
in
writeShellApplication {
  name = "fss-test";
  runtimeInputs = [
    coreutils
    systemd
    gnugrep
  ];
  text = ''
        set -euo pipefail

        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        NC='\033[0m'
        ${verifyClassifierLib}

        PASSED=0
        FAILED=0
        WARNED=0

        pass() { fss_log_pass "$1"; PASSED=$((PASSED + 1)); }
        fail() { fss_log_fail "$1"; FAILED=$((FAILED + 1)); }
        warn() { fss_log_warn "$1"; WARNED=$((WARNED + 1)); }
        info() { fss_log_info "$1"; }
        count_matches() {
          local pattern="$1"
          local text="$2"

          printf '%s\n' "$text" | grep -Eic "$pattern" || true
        }
        print_prefixed_lines() {
          local prefix="$1"
          local text="$2"
          local limit="''${3:-0}"
          local line
          local total=0
          local shown=0

          total=$(fss_count_nonempty_lines "$text")
          if [ "$total" -eq 0 ]; then
            return 0
          fi

          while IFS= read -r line || [ -n "$line" ]; do
            if [ -z "$line" ]; then
              continue
            fi

            shown=$((shown + 1))
            if [ "$limit" -gt 0 ] && [ "$shown" -gt "$limit" ]; then
              break
            fi

            printf '%s%s\n' "$prefix" "$line"
          done <<<"$text"

          if [ "$limit" -gt 0 ] && [ "$total" -gt "$limit" ]; then
            printf '%s... (%s more lines)\n' "$prefix" "$((total - limit))"
          fi
        }
        summarize_header_output() {
          local header_output="$1"

          printf '%s\n' "$header_output" | grep -E '^(State:|Compatible flags:|Incompatible flags:|Boot ID:|Machine ID:|Head realtime timestamp:|Tail realtime timestamp:|Tail monotonic timestamp:|Rotate suggested:|Disk usage:)' || true
        }
        summarize_file_verify_output() {
          local verify_output="$1"

          printf '%s\n' "$verify_output" | grep -E '(^[[:xdigit:]]+: )|(^File corruption detected)|(^FAIL: )|(^PASS: )|(^=> Validated)|(^Journal file .* is truncated, ignoring file\.)|(Required key not available)|(parse.*seed)|(tag/entry realtime timestamp out of synchronization)' || true
        }
        print_recent_journald_alerts() {
          local alerts

          alerts=$(journalctl -u systemd-journald --no-pager 2>/dev/null | grep -Ei 'corrupt|unclean|renaming and replacing|failed to append tag when closing journal|time jumped backwards|rotating|recover' | tail -n 12 || true)
          if [ -n "$alerts" ]; then
            echo "   Recent systemd-journald alerts:"
            print_prefixed_lines "     " "$alerts"
          fi
        }
        print_failed_file_diagnostics() {
          local verify_output="$1"
          local verify_key="$2"
          local failed_paths
          local failed_count=0
          local path
          local bucket
          local stat_output
          local header_output
          local header_summary
          local file_verify_output
          local file_verify_summary
          local path_limit=4
          local total_failed_paths

          failed_paths=$(fss_unique_fail_paths_from_output "$verify_output")
          if [ -z "$failed_paths" ]; then
            return 0
          fi
          total_failed_paths=$(fss_count_nonempty_lines "$failed_paths")

          echo "   Detailed file diagnostics (up to $path_limit unique failing files):"
          while IFS= read -r path || [ -n "$path" ]; do
            if [ -z "$path" ]; then
              continue
            fi

            failed_count=$((failed_count + 1))
            if [ "$failed_count" -gt "$path_limit" ]; then
              printf '     ... %s additional failing file(s) omitted\n' "$((total_failed_paths - path_limit))"
              break
            fi

            bucket=$(fss_failure_bucket_for_path "$path")
            printf '   - %s [%s]\n' "$path" "$bucket"

            if [ ! -e "$path" ]; then
              echo "     file no longer exists"
              continue
            fi

            stat_output=$(stat -c 'size=%s mode=%a uid=%u gid=%g mtime=%y' "$path" 2>/dev/null || true)
            if [ -n "$stat_output" ]; then
              echo "     stat: $stat_output"
            fi

            header_output=$(journalctl --header --file="$path" 2>/dev/null || true)
            header_summary=$(summarize_header_output "$header_output")
            if [ -n "$header_summary" ]; then
              print_prefixed_lines "     header: " "$header_summary" 8
            fi

            if [ -n "$verify_key" ]; then
              file_verify_output=$(journalctl --verify --verify-key="$verify_key" --file="$path" 2>&1 || true)
              file_verify_summary=$(summarize_file_verify_output "$file_verify_output")
              if [ -n "$file_verify_summary" ]; then
                print_prefixed_lines "     verify: " "$file_verify_summary" 8
              fi
            fi
          done <<<"$failed_paths"
        }
        print_verify_diagnostics() {
          local verify_output="$1"
          local verify_tags="$2"
          local verify_exit="$3"
          local verify_key="''${4:-}"
          local active_count
          local archived_count
          local user_count
          local temp_count
          local other_count
          local tag_failed_count
          local epoch_count
          local time_sync_count
          local corruption_count
          local io_error_count
          local fail_path_count

          active_count=$(fss_count_nonempty_lines "$FSS_ACTIVE_SYSTEM_FAILURES")
          archived_count=$(fss_count_nonempty_lines "$FSS_ARCHIVED_SYSTEM_FAILURES")
          user_count=$(fss_count_nonempty_lines "$FSS_USER_FAILURES")
          temp_count=$(fss_count_nonempty_lines "$FSS_TEMP_FAILURES")
          other_count=$(fss_count_nonempty_lines "$FSS_OTHER_FAILURES")
          fail_path_count=$(fss_count_nonempty_lines "$(fss_unique_fail_paths_from_output "$verify_output")")

          tag_failed_count=$(count_matches 'Tag failed verification' "$verify_output")
          epoch_count=$(count_matches 'Epoch sequence not continuous' "$verify_output")
          time_sync_count=$(count_matches 'tag/entry realtime timestamp out of synchronization' "$verify_output")
          corruption_count=$(count_matches 'File corruption detected at ' "$verify_output")
          io_error_count=$(count_matches 'Input/output error|I/O error' "$verify_output")

          printf '   Diagnostic summary: exit=%s tags=[%s] failing_files=%s active=%s archived=%s user=%s temp=%s other=%s\n' \
            "$verify_exit" "$verify_tags" "$fail_path_count" "$active_count" "$archived_count" "$user_count" "$temp_count" "$other_count"
          printf '   Signals: tag_failed=%s epoch_discontinuity=%s time_sync=%s file_corruption=%s io_error=%s key_parse=%s key_missing=%s filesystem_restriction=%s\n' \
            "$tag_failed_count" "$epoch_count" "$time_sync_count" "$corruption_count" "$io_error_count" \
            "$FSS_KEY_PARSE_ERROR" "$FSS_KEY_REQUIRED_ERROR" "$FSS_FILESYSTEM_RESTRICTION"

          print_failed_file_diagnostics "$verify_output" "$verify_key"
          print_recent_journald_alerts
        }

        fss_log_block <<'EOF'
    ==========================================
      FSS (Forward Secure Sealing) Test Suite
    ==========================================
    EOF
        printf '\n'

        # Test 1: Check FSS setup service
        info "Test 1: Checking journal-fss-setup service..."
        if systemctl list-unit-files 2>/dev/null | grep -q "journal-fss-setup"; then
          SERVICE_RESULT=$(systemctl show journal-fss-setup --property=Result 2>/dev/null | cut -d= -f2)
          SERVICE_STATE=$(systemctl show journal-fss-setup --property=ActiveState 2>/dev/null | cut -d= -f2)
          if [ "$SERVICE_RESULT" = "success" ] || [ "$SERVICE_STATE" = "active" ]; then
            pass "journal-fss-setup service completed successfully"
          else
            # One-shot service with RemainAfterExit=yes shows as inactive but with success result
            warn "journal-fss-setup service status: state=$SERVICE_STATE result=$SERVICE_RESULT"
          fi
        elif systemctl cat journal-fss-setup.service &>/dev/null; then
          # Service exists but may not show in list-unit-files
          pass "journal-fss-setup service exists"
        else
          # Fallback: if FSS key exists, service must have run
          MACHINE_ID=$(cat /etc/machine-id)
          if [ -f "/var/log/journal/$MACHINE_ID/fss" ] || [ -f "/run/log/journal/$MACHINE_ID/fss" ]; then
            pass "journal-fss-setup service ran (FSS key exists)"
          else
            fail "journal-fss-setup service not found - FSS may not be enabled"
          fi
        fi

        # Test 2: Check sealing key exists
        info "Test 2: Checking FSS sealing key..."
        MACHINE_ID=$(cat /etc/machine-id)
        FSS_KEY="/var/log/journal/$MACHINE_ID/fss"
        FSS_KEY_VOLATILE="/run/log/journal/$MACHINE_ID/fss"

        if [ -f "$FSS_KEY" ]; then
          pass "FSS sealing key exists at $FSS_KEY"
        elif [ -f "$FSS_KEY_VOLATILE" ]; then
          warn "FSS key in volatile storage: $FSS_KEY_VOLATILE (will be lost on reboot)"
        else
          fail "FSS sealing key not found in persistent or volatile storage"
        fi

        # Discover KEY_DIR: prefer fss-config pointer, fall back to hostname-based paths
        # The fss-config file is written by journal-fss-setup and contains the Nix-configured
        # key directory path, which is stable even when the runtime hostname differs (e.g. net-vm
        # with dynamic AD hostname).
        KEY_DIR=""
        FSS_CONFIG="/var/log/journal/$MACHINE_ID/fss-config"
        if [ -f "$FSS_CONFIG" ] && [ -s "$FSS_CONFIG" ]; then
          KEY_DIR=$(cat "$FSS_CONFIG")
          info "Discovered key directory from fss-config: $KEY_DIR"
        else
          # Fallback: try hostname-based paths (works for VMs without dynamic hostname)
          HOSTNAME=$(hostname)
          for CANDIDATE in \
            "/persist/common/journal-fss/$HOSTNAME" \
            "/etc/common/journal-fss/$HOSTNAME"; do
            if [ -d "$CANDIDATE" ]; then
              KEY_DIR="$CANDIDATE"
              info "Discovered key directory from hostname fallback: $KEY_DIR"
              break
            fi
          done
        fi

        # Test 3: Check verification key
        info "Test 3: Checking verification key..."
        FOUND_VERIFY_KEY=false
        VERIFY_KEY_PATH=""
        VERIFY_KEY_UNREADABLE=false

        if [ -n "$KEY_DIR" ] && [ -e "$KEY_DIR/verification-key" ]; then
          VERIFY_KEY_PATH="$KEY_DIR/verification-key"
          if [ -s "$VERIFY_KEY_PATH" ] && [ -r "$VERIFY_KEY_PATH" ]; then
            pass "Verification key exists at $VERIFY_KEY_PATH"
            FOUND_VERIFY_KEY=true
          elif [ -s "$VERIFY_KEY_PATH" ]; then
            VERIFY_KEY_UNREADABLE=true
            if [ "$(id -u)" -eq 0 ]; then
              fail "Verification key exists but is unreadable at $VERIFY_KEY_PATH"
            else
              warn "Verification key exists but is unreadable as $(id -un); rerun fss-test as root"
            fi
          else
            fail "Verification key exists but is empty at $VERIFY_KEY_PATH"
          fi
        fi

        if [ "$FOUND_VERIFY_KEY" = false ] && [ "$VERIFY_KEY_UNREADABLE" = false ]; then
          if [ -n "$KEY_DIR" ]; then
            fail "Verification key not found - journal verification cannot validate sealed logs"
          else
            warn "Verification key directory could not be discovered"
          fi
        fi

        # Test 4: Check initialized sentinel
        info "Test 4: Checking initialization sentinel..."
        FOUND_INIT=false

        if [ -n "$KEY_DIR" ] && [ -f "$KEY_DIR/initialized" ]; then
          pass "Initialization sentinel exists at $KEY_DIR/initialized"
          FOUND_INIT=true
        fi

        if [ "$FOUND_INIT" = false ]; then
          warn "Initialization sentinel not found"
        fi

        # Test 5: Run journal verification
        info "Test 5: Running journal verification..."

        VERIFY_KEY=""
        SHOULD_RUN_VERIFY=true
        if [ -n "$VERIFY_KEY_PATH" ] && [ -r "$VERIFY_KEY_PATH" ] && [ -s "$VERIFY_KEY_PATH" ]; then
          VERIFY_KEY=$(cat "$VERIFY_KEY_PATH")
          echo "   Using verification key from $VERIFY_KEY_PATH"
        elif [ "$VERIFY_KEY_UNREADABLE" = true ] && [ "$(id -u)" -ne 0 ]; then
          warn "Skipping sealed journal verification because the verification key is unreadable as $(id -un)"
          SHOULD_RUN_VERIFY=false
        elif [ -n "$KEY_DIR" ]; then
          fail "Skipping sealed journal verification because the verification key is unavailable"
          SHOULD_RUN_VERIFY=false
        else
          warn "Skipping sealed journal verification because the verification key directory is unknown"
          SHOULD_RUN_VERIFY=false
        fi

        if [ "$SHOULD_RUN_VERIFY" = true ]; then
          VERIFY_OUTPUT=""
          VERIFY_EXIT=0
          if VERIFY_OUTPUT=$(journalctl --verify --verify-key="$VERIFY_KEY" 2>&1); then
            VERIFY_EXIT=0
          else
            VERIFY_EXIT=$?
          fi

          fss_classify_verify_output "$VERIFY_OUTPUT"
          VERIFY_TAGS=$(fss_classification_tags)

          if [ "$FSS_KEY_PARSE_ERROR" -eq 1 ] || [ "$FSS_KEY_REQUIRED_ERROR" -eq 1 ]; then
            fail "Journal verification failed due to verification key defect [$VERIFY_TAGS]"
            echo "   Output: $VERIFY_OUTPUT"
            print_verify_diagnostics "$VERIFY_OUTPUT" "$VERIFY_TAGS" "$VERIFY_EXIT"
          elif [ -n "$FSS_ACTIVE_SYSTEM_FAILURES" ]; then
            fail "Active system journal verification failed [$VERIFY_TAGS]"
            echo "   Output: $VERIFY_OUTPUT"
            print_verify_diagnostics "$VERIFY_OUTPUT" "$VERIFY_TAGS" "$VERIFY_EXIT" "$VERIFY_KEY"
          elif [ -n "$FSS_OTHER_FAILURES" ]; then
            fail "Journal verification found unclassified critical failures [$VERIFY_TAGS]"
            echo "   Output: $VERIFY_OUTPUT"
            print_verify_diagnostics "$VERIFY_OUTPUT" "$VERIFY_TAGS" "$VERIFY_EXIT" "$VERIFY_KEY"
          elif [ -n "$FSS_ARCHIVED_SYSTEM_FAILURES" ] || [ -n "$FSS_USER_FAILURES" ]; then
            warn "Journal verification passed with archive/user warnings [$VERIFY_TAGS]"
            echo "   Output: $VERIFY_OUTPUT"
            print_verify_diagnostics "$VERIFY_OUTPUT" "$VERIFY_TAGS" "$VERIFY_EXIT" "$VERIFY_KEY"
          elif [ -n "$FSS_TEMP_FAILURES" ]; then
            pass "Journal verification passed (temporary journal files ignored)"
            echo "   Ignored temp failures: $FSS_TEMP_FAILURES"
            print_verify_diagnostics "$VERIFY_OUTPUT" "$VERIFY_TAGS" "$VERIFY_EXIT" "$VERIFY_KEY"
          elif [ "$VERIFY_EXIT" -eq 0 ]; then
            pass "Journal verification passed"
          elif [ "$FSS_FILESYSTEM_RESTRICTION" -eq 1 ]; then
            warn "Verification encountered filesystem restrictions [$VERIFY_TAGS]"
            echo "   Output: $VERIFY_OUTPUT"
            print_verify_diagnostics "$VERIFY_OUTPUT" "$VERIFY_TAGS" "$VERIFY_EXIT"
          else
            warn "Verification returned exit code $VERIFY_EXIT without critical failures [$VERIFY_TAGS]"
            echo "   Output: $VERIFY_OUTPUT"
            print_verify_diagnostics "$VERIFY_OUTPUT" "$VERIFY_TAGS" "$VERIFY_EXIT" "$VERIFY_KEY"
          fi
        fi

        # Test 6: Check verification timer
        info "Test 6: Checking verification timer..."
        if systemctl list-unit-files 2>/dev/null | grep -q "journal-fss-verify.timer"; then
          if systemctl is-active --quiet journal-fss-verify.timer; then
            pass "journal-fss-verify.timer is active"
            NEXT_RUN=$(systemctl list-timers journal-fss-verify --no-pager 2>/dev/null | grep journal-fss-verify | awk '{print $1, $2}' || echo "unknown")
            echo "   Next run: $NEXT_RUN"
          else
            warn "journal-fss-verify.timer exists but is not active"
          fi
        elif systemctl cat journal-fss-verify.timer &>/dev/null; then
          if systemctl is-active --quiet journal-fss-verify.timer; then
            pass "journal-fss-verify.timer is active"
          else
            pass "journal-fss-verify.timer exists"
          fi
        else
          warn "journal-fss-verify.timer not found"
        fi

        # Test 7: Check audit rules (if auditd is available)
        info "Test 7: Checking audit rules..."
        if command -v auditctl &>/dev/null; then
          RULES=$(auditctl -l 2>/dev/null || echo "no rules")
          if echo "$RULES" | grep -q "journal_fss_keys\|journal_sealed_logs"; then
            pass "FSS audit rules are configured"
          elif echo "$RULES" | grep -q "No rules"; then
            warn "No audit rules configured (auditd may not be enabled)"
          else
            warn "FSS-specific audit rules not found"
          fi
        else
          warn "auditctl not available, skipping audit check"
        fi

        # Summary
        printf '\n'
        fss_log_block <<'EOF'
    ==========================================
      FSS Test Suite Complete
    ==========================================
    EOF
        printf '\n'
        printf "  %bPassed:%b  %s\n" "''${GREEN}" "''${NC}" "$PASSED"
        printf "  %bFailed:%b  %s\n" "''${RED}" "''${NC}" "$FAILED"
        printf "  %bWarned:%b  %s\n" "''${YELLOW}" "''${NC}" "$WARNED"
        printf '\n'

        if [ "$FAILED" -gt 0 ]; then
          printf "%bSome tests failed. FSS may not be working correctly.%b\n" "''${RED}" "''${NC}"
          exit 1
        elif [ "$WARNED" -gt 0 ]; then
          printf "%bAll critical tests passed, but some warnings were raised.%b\n" "''${YELLOW}" "''${NC}"
          exit 0
        else
          printf "%bAll tests passed. FSS is working correctly.%b\n" "''${GREEN}" "''${NC}"
          exit 0
        fi
  '';
}
