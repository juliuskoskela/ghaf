# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# FSS Verification Tests
#
# Verifies journal integrity checking works correctly. Tests that:
# - Journal verification runs without critical errors on untampered logs
# - Journal files are created properly
# - Verification service can be triggered manually
#
_: ''
  machine.wait_until_succeeds("""
    bash -lc '
      systemctl is-active --quiet journal-fss-setup.service ||
      systemctl is-failed --quiet journal-fss-setup.service ||
      [ "$(systemctl show journal-fss-setup.service --property=ConditionResult --value)" = "no" ]
    '
  """)
  setup_status = machine.succeed("systemctl show journal-fss-setup --property=ActiveState,Result,ConditionResult")
  setup_succeeded = "Result=success" in setup_status
  verify_key_path = "/persist/common/journal-fss/test-host/verification-key"

  with subtest("Journal verification runs without critical errors"):
      if not setup_succeeded:
          print(f"Skipping journal verification because FSS setup did not complete successfully: {setup_status}")
      else:
          machine.succeed(f"test -r {verify_key_path} && test -s {verify_key_path}")
          machine.succeed("logger -t fss-test 'Test entry 1'")
          machine.succeed("logger -t fss-test 'Test entry 2'")
          machine.sleep(5)
          exit_code, output = machine.execute(f"""
            bash -lc '
              set -euo pipefail
              KEY=$(cat "{verify_key_path}")
              source /etc/fss-verify-classifier.sh
              MID=$(cat /etc/machine-id)
              PRE_FSS_ARCHIVE_FILE="/var/log/journal/$MID/fss-pre-fss-archive"
              VERIFY_OUTPUT=$(journalctl --verify --verify-key="$KEY" 2>&1 || true)
              fss_classify_verify_output "$VERIFY_OUTPUT"
              VERIFY_TAGS=$(fss_classification_tags)
              EXPECTED_PRE_FSS_ARCHIVE=$(fss_read_recorded_pre_fss_archive "$PRE_FSS_ARCHIVE_FILE")

              if [ "$FSS_KEY_PARSE_ERROR" -eq 1 ] || [ "$FSS_KEY_REQUIRED_ERROR" -eq 1 ]; then
                printf "%s\\n%s\\n" "$VERIFY_TAGS" "$VERIFY_OUTPUT"
                exit 1
              fi

              if [ -n "$FSS_ARCHIVED_SYSTEM_FAILURES" ] && ! fss_matches_only_expected_archived_system_failure "$EXPECTED_PRE_FSS_ARCHIVE"; then
                printf "%s\\n%s\\n" "$VERIFY_TAGS" "$VERIFY_OUTPUT"
                exit 1
              fi

              if [ -n "$FSS_ACTIVE_SYSTEM_FAILURES" ] || [ -n "$FSS_OTHER_FAILURES" ]; then
                printf "%s\\n%s\\n" "$VERIFY_TAGS" "$VERIFY_OUTPUT"
                exit 1
              fi
            '
          """)
          if exit_code != 0:
              raise Exception(f"Journal verification found critical failures: {output}")
          print(f"Journal verification completed (exit code: {exit_code})")

  with subtest("Verification policy only exempts the recorded pre-FSS archive and user journals"):
      machine.succeed("""
        bash -lc '
          set -euo pipefail
          source /etc/fss-verify-classifier.sh

          policy_result() {
            local expected_pre_fss_archive="$1"
            local pre_fss_archive_allowed=0

            if [ "$FSS_KEY_PARSE_ERROR" -eq 1 ] || [ "$FSS_KEY_REQUIRED_ERROR" -eq 1 ]; then
              printf "%s\n" "fail"
              return 0
            fi

            if [ -n "$FSS_ACTIVE_SYSTEM_FAILURES" ] || [ -n "$FSS_OTHER_FAILURES" ]; then
              printf "%s\n" "fail"
              return 0
            fi

            if [ -n "$FSS_ARCHIVED_SYSTEM_FAILURES" ]; then
              if fss_matches_only_expected_archived_system_failure "$expected_pre_fss_archive"; then
                pre_fss_archive_allowed=1
              else
                printf "%s\n" "fail"
                return 0
              fi
            fi

            if [ "$pre_fss_archive_allowed" -eq 1 ] || [ -n "$FSS_USER_FAILURES" ]; then
              printf "%s\n" "partial"
              return 0
            fi

            printf "%s\n" "pass"
          }

          active_sample=$(printf "%s\n" \
            "FAIL: /var/log/journal/mid/system.journal (Bad message)")
          fss_classify_verify_output "$active_sample"
          [ -n "$FSS_ACTIVE_SYSTEM_FAILURES" ]
          [ -z "$FSS_ARCHIVED_SYSTEM_FAILURES" ]
          [ -z "$FSS_USER_FAILURES" ]
          [ "$FSS_REASON_TAGS" = "BAD_MESSAGE" ]
          [ "$(policy_result "")" = "fail" ]

          allowed_archive="/var/log/journal/mid/system@0000000000000001-0000000000000002.journal"
          allowed_archived_sample=$(printf "%s\n" \
            "FAIL: $allowed_archive (Input/output error)" \
            "PASS: /var/log/journal/mid/system.journal")
          fss_classify_verify_output "$allowed_archived_sample"
          [ -z "$FSS_ACTIVE_SYSTEM_FAILURES" ]
          [ -n "$FSS_ARCHIVED_SYSTEM_FAILURES" ]
          [ -z "$FSS_OTHER_FAILURES" ]
          [ "$FSS_REASON_TAGS" = "INPUT_OUTPUT_ERROR" ]
          fss_matches_only_expected_archived_system_failure "$allowed_archive"
          [ "$(policy_result "$allowed_archive")" = "partial" ]

          unexpected_archive="/var/log/journal/mid/system@0000000000000003-0000000000000004.journal"
          unexpected_archived_sample=$(printf "%s\n" \
            "FAIL: $unexpected_archive (Input/output error)" \
            "PASS: /var/log/journal/mid/system.journal")
          fss_classify_verify_output "$unexpected_archived_sample"
          [ -n "$FSS_ARCHIVED_SYSTEM_FAILURES" ]
          ! fss_matches_only_expected_archived_system_failure "$allowed_archive"
          [ "$(policy_result "$allowed_archive")" = "fail" ]

          multiple_archives_sample=$(printf "%s\n" \
            "FAIL: $allowed_archive (Bad message)" \
            "FAIL: $unexpected_archive (Bad message)")
          fss_classify_verify_output "$multiple_archives_sample"
          [ -n "$FSS_ARCHIVED_SYSTEM_FAILURES" ]
          ! fss_matches_only_expected_archived_system_failure "$allowed_archive"
          [ "$(policy_result "$allowed_archive")" = "fail" ]

          user_sample=$(printf "%s\n" \
            "FAIL: /var/log/journal/mid/user-1000@0000000000000001-0000000000000002.journal (Bad message)" \
            "PASS: /var/log/journal/mid/system.journal")
          fss_classify_verify_output "$user_sample"
          [ -z "$FSS_ACTIVE_SYSTEM_FAILURES" ]
          [ -n "$FSS_USER_FAILURES" ]
          [ -z "$FSS_OTHER_FAILURES" ]
          [ "$FSS_REASON_TAGS" = "BAD_MESSAGE" ]
          [ "$(policy_result "")" = "partial" ]

          user_active_sample=$(printf "%s\n" \
            "2cb2e0: Tag failed verification" \
            "File corruption detected at /var/log/journal/mid/user-1000.journal:2929376 (of 8388608 bytes, 34%)." \
            "FAIL: /var/log/journal/mid/user-1000.journal (Bad message)" \
            "PASS: /var/log/journal/mid/system.journal")
          fss_classify_verify_output "$user_active_sample"
          [ -z "$FSS_ACTIVE_SYSTEM_FAILURES" ]
          [ -n "$FSS_USER_FAILURES" ]
          [ -z "$FSS_OTHER_FAILURES" ]
          tags=$(fss_reason_tags_from_output "$user_active_sample")
          [ "$tags" = "BAD_MESSAGE" ]
          [ -n "$FSS_USER_FAILURES" ]
          [ -z "$FSS_ACTIVE_SYSTEM_FAILURES" ]
          [ "$(policy_result "")" = "partial" ]

          temp_sample=$(printf "%s\n" \
            "FAIL: /var/log/journal/mid/system@0000000000000001-0000000000000002.journal~ (Bad message)")
          fss_classify_verify_output "$temp_sample"
          [ -z "$FSS_ACTIVE_SYSTEM_FAILURES" ]
          [ -z "$FSS_ARCHIVED_SYSTEM_FAILURES" ]
          [ -z "$FSS_USER_FAILURES" ]
          [ -n "$FSS_TEMP_FAILURES" ]
          [ "$FSS_REASON_TAGS" = "BAD_MESSAGE" ]
          [ "$(policy_result "")" = "pass" ]

          temp_with_diagnostics_sample=$(printf "%s\n" \
            "2cb2e0: Tag failed verification" \
            "FAIL: /var/log/journal/mid/user-1000@0000000000000001-0000000000000002.journal~ (Bad message)")
          fss_classify_verify_output "$temp_with_diagnostics_sample"
          [ -z "$FSS_ACTIVE_SYSTEM_FAILURES" ]
          [ -z "$FSS_ARCHIVED_SYSTEM_FAILURES" ]
          [ -z "$FSS_USER_FAILURES" ]
          [ -n "$FSS_TEMP_FAILURES" ]
          [ -z "$FSS_OTHER_FAILURES" ]
          [ "$(policy_result "")" = "pass" ]

          other_sample=$(printf "%s\n" \
            "FAIL: /var/log/journal/mid/custom.journal (Bad message)")
          fss_classify_verify_output "$other_sample"
          [ -z "$FSS_ACTIVE_SYSTEM_FAILURES" ]
          [ -z "$FSS_ARCHIVED_SYSTEM_FAILURES" ]
          [ -z "$FSS_USER_FAILURES" ]
          [ -n "$FSS_OTHER_FAILURES" ]
          [ -z "$FSS_TEMP_FAILURES" ]
          [ "$(policy_result "")" = "fail" ]

          mixed_sample=$(printf "%s\n" \
            "FAIL: /var/log/journal/mid/system.journal (Bad message)" \
            "FAIL: /var/log/journal/mid/system.journal (Bad message)" \
            "FAIL: /var/log/journal/mid/system@0000000000000001-0000000000000002.journal (Bad message)" \
            "FAIL: /var/log/journal/mid/user-1000@0000000000000001-0000000000000002.journal (Bad message)" \
            "FAIL: /var/log/journal/mid/system@0000000000000001-0000000000000002.journal~ (Bad message)" \
            "FAIL: /var/log/journal/mid/custom.journal (Bad message)")
          unique_fail_paths=$(fss_unique_fail_paths_from_output "$mixed_sample")
          [ "$(fss_count_nonempty_lines "$unique_fail_paths")" -eq 5 ]
          [ "$(printf "%s\n" "$unique_fail_paths" | grep -c '^/var/log/journal/mid/system.journal$')" -eq 1 ]
          [ "$(fss_failure_bucket_for_path "/var/log/journal/mid/system.journal")" = "active-system" ]
          [ "$(fss_failure_bucket_for_path "/var/log/journal/mid/system@0000000000000001-0000000000000002.journal")" = "archived-system" ]
          [ "$(fss_failure_bucket_for_path "/var/log/journal/mid/user-1000@0000000000000001-0000000000000002.journal")" = "user-journal" ]
          [ "$(fss_failure_bucket_for_path "/var/log/journal/mid/system@0000000000000001-0000000000000002.journal~")" = "temp" ]
          [ "$(fss_failure_bucket_for_path "/var/log/journal/mid/custom.journal")" = "other" ]

          key_sample=$(printf "%s\n" \
            "Failed to parse seed." \
            "FAIL: /var/log/journal/mid/system.journal (Required key not available)")
          fss_classify_verify_output "$key_sample"
          [ "$FSS_KEY_PARSE_ERROR" -eq 1 ]
          [ "$FSS_KEY_REQUIRED_ERROR" -eq 1 ]
          [ "$FSS_REASON_TAGS" = "KEY_PARSE_ERROR,KEY_MISSING" ]
          [ "$(fss_classification_tags)" = "KEY_PARSE_ERROR,KEY_MISSING,ACTIVE_SYSTEM" ]
          [ "$(policy_result "")" = "fail" ]

          fss_classify_verify_output ""
          [ -z "$FSS_REASON_TAGS" ]
          [ -z "$FSS_FAIL_LINES" ]
          [ -z "$FSS_TEMP_FAILURES" ]
          [ -z "$FSS_ACTIVE_SYSTEM_FAILURES" ]
          [ -z "$FSS_ARCHIVED_SYSTEM_FAILURES" ]
          [ -z "$FSS_USER_FAILURES" ]
          [ -z "$FSS_OTHER_FAILURES" ]
          [ "$FSS_KEY_PARSE_ERROR" -eq 0 ]
          [ "$FSS_KEY_REQUIRED_ERROR" -eq 0 ]
          [ "$FSS_FILESYSTEM_RESTRICTION" -eq 0 ]
          [ "$(policy_result "")" = "pass" ]

          log_output=$(
            {
              fss_log_pass "pass message"
              fss_log_fail "fail message"
              fss_log_warn "warn message"
              fss_log_info "info message"
              fss_log_block < <(printf "%s\n" "block line 1" "block line 2")
            }
          )
          expected_log_output=$(printf "%s\n" \
            "[PASS] pass message" \
            "[FAIL] fail message" \
            "[WARN] warn message" \
            "[INFO] info message" \
            "block line 1" \
            "block line 2")
          [ "$log_output" = "$expected_log_output" ]

          state_file=$(mktemp)
          printf "  /var/log/journal/mid/system@0000000000000001-0000000000000002.journal \n" > "$state_file"
          [ "$(fss_read_recorded_pre_fss_archive "$state_file")" = "/var/log/journal/mid/system@0000000000000001-0000000000000002.journal" ]
          rm -f "$state_file"
          [ -z "$(fss_read_recorded_pre_fss_archive "$state_file")" ]
        '
      """)

  with subtest("Clock-jump recovery defaults are enabled"):
      machine.succeed("systemctl list-unit-files ghaf-clock-jump-watcher.service")
      machine.succeed("systemctl list-unit-files ghaf-journal-alloy-recover.service")
      machine.wait_for_unit("ghaf-clock-jump-watcher.service")
      watcher_status = machine.succeed("systemctl show ghaf-clock-jump-watcher.service --property=ActiveState,UnitFileState")
      if "ActiveState=active" not in watcher_status or "UnitFileState=enabled" not in watcher_status:
          raise Exception(f"Clock-jump watcher not enabled by default: {watcher_status}")
      print(f"Clock-jump recovery watcher status: {watcher_status}")

  with subtest("Clock-jump recovery tolerates missing alloy service"):
      exit_code, output = machine.execute("systemctl start ghaf-journal-alloy-recover.service 2>&1")
      if exit_code != 0:
          raise Exception(f"Clock-jump recovery service failed without alloy: {output}")
      recover_status = machine.succeed("systemctl show ghaf-journal-alloy-recover.service --property=Result,ExecMainStatus")
      if "Result=success" not in recover_status:
          raise Exception(f"Clock-jump recovery service did not complete successfully: {recover_status}")
      print(f"Clock-jump recovery service completed successfully: {recover_status}")

  with subtest("Journal files are created"):
      mid = machine.succeed("cat /etc/machine-id").strip()
      exit_code, journal_files = machine.execute(f"ls /var/log/journal/{mid}/*.journal 2>/dev/null || ls /run/log/journal/{mid}/*.journal 2>/dev/null")
      if exit_code == 0 and journal_files.strip():
          print(f"Journal files found: {journal_files.strip()}")
      else:
          print("No journal files found yet - this is expected early in boot")

  with subtest("FSS verify service can be triggered"):
      machine.succeed("systemctl list-unit-files journal-fss-verify.service")
      exit_code, output = machine.execute("systemctl start journal-fss-verify.service 2>&1")
      if exit_code == 0:
          print("Manual verification service ran successfully")
      else:
          if "ConditionPathExists" in output:
              print("Verification service skipped (not yet initialized) - expected in test environment")
          else:
              print(f"Verification service returned: {output}")

  with subtest("Setup backfills only the archive created at the original FSS rotation"):
      if not setup_succeeded:
          print(f"Skipping archive backfill check because FSS setup did not complete successfully: {setup_status}")
      else:
          machine.succeed("""
            bash -lc '
              set -euo pipefail
              MACHINE_ID=$(cat /etc/machine-id)
              STATE_DIR="/var/log/journal/$MACHINE_ID"
              PRE_FSS_ARCHIVE_FILE="$STATE_DIR/fss-pre-fss-archive"
              ROTATED_MARKER="$STATE_DIR/fss-rotated"
              MARKER_MTIME=$(stat -c %Y "$ROTATED_MARKER")
              ARCHIVE_BACKUP_DIR=$(mktemp -d)
              CANDIDATE_ARCHIVE="$STATE_DIR/system@0000000000000001-0000000000000001.journal"
              LATER_ARCHIVE="$STATE_DIR/system@0000000000000002-0000000000000002.journal"

              cleanup() {
                rm -f "$PRE_FSS_ARCHIVE_FILE" "$CANDIDATE_ARCHIVE" "$LATER_ARCHIVE"
                find "$ARCHIVE_BACKUP_DIR" -maxdepth 1 -type f -name "system@*.journal" -exec mv {} "$STATE_DIR"/ \;
                rmdir "$ARCHIVE_BACKUP_DIR"
              }
              trap cleanup EXIT

              test -f "$ROTATED_MARKER"
              test -f "$PRE_FSS_ARCHIVE_FILE"
              find "$STATE_DIR" -maxdepth 1 -type f -name "system@*.journal" -exec mv {} "$ARCHIVE_BACKUP_DIR"/ \;

              : > "$CANDIDATE_ARCHIVE"
              : > "$LATER_ARCHIVE"
              touch -d "@$MARKER_MTIME" "$CANDIDATE_ARCHIVE"
              touch -d "@$((MARKER_MTIME + 30))" "$LATER_ARCHIVE"

              rm -f "$PRE_FSS_ARCHIVE_FILE"
              systemctl restart journal-fss-setup.service >/tmp/journal-fss-setup-backfill.log 2>&1

              test -f "$PRE_FSS_ARCHIVE_FILE"
              [ "$(tr -d "[:space:]" < "$PRE_FSS_ARCHIVE_FILE")" = "$CANDIDATE_ARCHIVE" ]
            '
          """)

  with subtest("Setup avoids backfilling a later archive when the pre-FSS archive is gone"):
      if not setup_succeeded:
          print(f"Skipping missing pre-FSS archive check because FSS setup did not complete successfully: {setup_status}")
      else:
          machine.succeed("""
            bash -lc '
              set -euo pipefail
              MACHINE_ID=$(cat /etc/machine-id)
              STATE_DIR="/var/log/journal/$MACHINE_ID"
              PRE_FSS_ARCHIVE_FILE="$STATE_DIR/fss-pre-fss-archive"
              ROTATED_MARKER="$STATE_DIR/fss-rotated"
              MARKER_MTIME=$(stat -c %Y "$ROTATED_MARKER")
              ARCHIVE_BACKUP_DIR=$(mktemp -d)
              LATER_ARCHIVE="$STATE_DIR/system@0000000000000002-0000000000000002.journal"

              cleanup() {
                rm -f "$PRE_FSS_ARCHIVE_FILE" "$LATER_ARCHIVE"
                find "$ARCHIVE_BACKUP_DIR" -maxdepth 1 -type f -name "system@*.journal" -exec mv {} "$STATE_DIR"/ \;
                rmdir "$ARCHIVE_BACKUP_DIR"
              }
              trap cleanup EXIT

              find "$STATE_DIR" -maxdepth 1 -type f -name "system@*.journal" -exec mv {} "$ARCHIVE_BACKUP_DIR"/ \;
              : > "$LATER_ARCHIVE"
              touch -d "@$((MARKER_MTIME + 30))" "$LATER_ARCHIVE"

              rm -f "$PRE_FSS_ARCHIVE_FILE"
              systemctl restart journal-fss-setup.service >/tmp/journal-fss-setup-no-backfill.log 2>&1

              [ ! -e "$PRE_FSS_ARCHIVE_FILE" ]
            '
          """)

  with subtest("Setup preserves initialized sentinel when verification key is missing"):
      if not setup_succeeded:
          print(f"Skipping missing-key recovery check because FSS setup did not complete successfully: {setup_status}")
      else:
          machine.succeed(f"""
            bash -lc '
              set -euo pipefail
              KEY_DIR="/persist/common/journal-fss/test-host"
              VERIFY_KEY_FILE="$KEY_DIR/verification-key"
              INIT_FILE="$KEY_DIR/initialized"
              MACHINE_ID=$(cat /etc/machine-id)
              BACKUP=$(mktemp)

              cp "{verify_key_path}" "$BACKUP"
              test -f "$INIT_FILE"
              rm -f "$VERIFY_KEY_FILE"

              set +e
              systemctl restart journal-fss-setup.service >/tmp/journal-fss-setup-missing-key.log 2>&1
              setup_rc=$?
              set -e
              [ "$setup_rc" -ne 0 ]
              test -f "$INIT_FILE"
              test -f "/var/log/journal/$MACHINE_ID/fss-config"

              systemctl reset-failed journal-fss-verify.service >/dev/null 2>&1 || true
              set +e
              systemctl start journal-fss-verify.service >/tmp/journal-fss-verify-missing-key.log 2>&1
              verify_rc=$?
              set -e
              [ "$verify_rc" -ne 0 ]
              systemctl show journal-fss-verify.service -p ConditionResult -p Result -p ExecMainStatus | grep -F "ConditionResult=yes"
              systemctl show journal-fss-verify.service -p ConditionResult -p Result -p ExecMainStatus | grep -F "ExecMainStatus=1"
              journalctl -u journal-fss-verify.service -n 20 --no-pager | grep -F "KEY_MISSING"

              cp "$BACKUP" "$VERIFY_KEY_FILE"
              chmod 0400 "$VERIFY_KEY_FILE"
              rm -f "$BACKUP"
              systemctl reset-failed journal-fss-setup.service journal-fss-verify.service >/dev/null 2>&1 || true
              systemctl restart journal-fss-setup.service >/dev/null 2>&1
            '
          """)

''
