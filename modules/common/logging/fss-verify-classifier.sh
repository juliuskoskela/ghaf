#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2329

# Shared helpers for classifying `journalctl --verify` output.

fss_log_status() {
  local level="$1"
  local message="$2"
  local color_start=""
  local color_end=""

  case "$level" in
  PASS)
    color_start="${GREEN:-}"
    ;;
  FAIL)
    color_start="${RED:-}"
    ;;
  WARN)
    color_start="${YELLOW:-}"
    ;;
  esac

  color_end="${NC:-}"

  if [ -n "$color_start" ] && [ -n "$color_end" ]; then
    printf '%b[%s]%b %s\n' "$color_start" "$level" "$color_end" "$message"
  else
    printf '[%s] %s\n' "$level" "$message"
  fi
}

fss_log_pass() {
  fss_log_status "PASS" "$1"
}

fss_log_fail() {
  fss_log_status "FAIL" "$1"
}

fss_log_warn() {
  fss_log_status "WARN" "$1"
}

fss_log_info() {
  printf '[INFO] %s\n' "$1"
}

fss_log_block() {
  cat
}

fss_append_tag() {
  local current="$1"
  local tag="$2"

  if [ -z "$current" ]; then
    printf '%s' "$tag"
  elif printf '%s\n' ",$current," | grep -Fq ",$tag,"; then
    printf '%s' "$current"
  else
    printf '%s,%s' "$current" "$tag"
  fi
}

fss_append_line() {
  local current="$1"
  local line="$2"

  if [ -z "$current" ]; then
    printf '%s' "$line"
  else
    printf '%s\n%s' "$current" "$line"
  fi
}

fss_append_unique_line() {
  local current="$1"
  local line="$2"

  if [ -z "$line" ]; then
    printf '%s' "$current"
  elif printf '%s\n' "$current" | grep -Fxq "$line"; then
    printf '%s' "$current"
  else
    fss_append_line "$current" "$line"
  fi
}

# shellcheck disable=SC2329
fss_count_nonempty_lines() {
  local text="$1"
  local line
  local count=0

  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$line" ]; then
      count=$((count + 1))
    fi
  done <<<"$text"

  printf '%s' "$count"
}

# shellcheck disable=SC2329
fss_failure_bucket_for_path() {
  local failure_path="$1"

  case "$failure_path" in
  *.journal~)
    printf '%s' "temp"
    ;;
  */system.journal)
    printf '%s' "active-system"
    ;;
  */system@*.journal)
    printf '%s' "archived-system"
    ;;
  */user-[0-9]*.journal)
    printf '%s' "user-journal"
    ;;
  *)
    printf '%s' "other"
    ;;
  esac
}

# shellcheck disable=SC2329
fss_unique_fail_paths_from_output() {
  local output="$1"
  local line
  local failure_path
  local unique_paths=""

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    FAIL:\ *)
      failure_path="${line#FAIL: }"
      failure_path="${failure_path%% *}"

      if [ -n "$failure_path" ] && ! printf '%s\n' "$unique_paths" | grep -Fxq "$failure_path"; then
        unique_paths=$(fss_append_line "$unique_paths" "$failure_path")
      fi
      ;;
    esac
  done <<<"$output"

  printf '%s' "$unique_paths"
}

fss_path_list_contains() {
  local path_list="$1"
  local needle="$2"

  [ -n "$needle" ] && printf '%s\n' "$path_list" | grep -Fxq "$needle"
}

fss_merge_path_lists() {
  local merged="$1"
  local additions="$2"
  local line

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    merged=$(fss_append_unique_line "$merged" "$line")
  done <<<"$additions"

  printf '%s' "$merged"
}

# shellcheck disable=SC2329
fss_read_recorded_pre_fss_archive() {
  local state_file="$1"

  if [ -r "$state_file" ] && [ -s "$state_file" ]; then
    tr -d '[:space:]' <"$state_file"
  fi
}

fss_read_recorded_archive_list() {
  local state_file="$1"
  local line
  local archive_paths=""

  if [ -r "$state_file" ] && [ -s "$state_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=$(printf '%s' "$line" | tr -d '[:space:]')
      [ -n "$line" ] || continue
      archive_paths=$(fss_append_unique_line "$archive_paths" "$line")
    done <"$state_file"
  fi

  printf '%s' "$archive_paths"
}

# shellcheck disable=SC2329
fss_matches_only_expected_archived_system_failure() {
  local expected_archive="$1"
  local archived_failures="${2:-$FSS_ARCHIVED_SYSTEM_FAILURES}"
  local archive_fail_paths

  if [ -z "$expected_archive" ] || [ -z "$archived_failures" ]; then
    return 1
  fi

  archive_fail_paths=$(fss_unique_fail_paths_from_output "$archived_failures")
  [ "$(fss_count_nonempty_lines "$archive_fail_paths")" -eq 1 ] || return 1
  [ "$archive_fail_paths" = "$expected_archive" ]
}

fss_archived_system_failures_match_allowlist() {
  local allowed_archives="$1"
  local archived_failures="${2:-$FSS_ARCHIVED_SYSTEM_FAILURES}"
  local archive_fail_paths
  local archive_path

  if [ -z "$allowed_archives" ] || [ -z "$archived_failures" ]; then
    return 1
  fi

  archive_fail_paths=$(fss_unique_fail_paths_from_output "$archived_failures")
  [ -n "$archive_fail_paths" ] || return 1

  while IFS= read -r archive_path || [ -n "$archive_path" ]; do
    [ -n "$archive_path" ] || continue
    fss_path_list_contains "$allowed_archives" "$archive_path" || return 1
  done <<<"$archive_fail_paths"
}

fss_reset_classification() {
  FSS_REASON_TAGS=""
  FSS_FAIL_LINES=""
  FSS_TEMP_FAILURES=""
  FSS_ACTIVE_SYSTEM_FAILURES=""
  FSS_ARCHIVED_SYSTEM_FAILURES=""
  FSS_USER_FAILURES=""
  FSS_OTHER_FAILURES=""
  FSS_KEY_PARSE_ERROR=0
  FSS_KEY_REQUIRED_ERROR=0
  FSS_FILESYSTEM_RESTRICTION=0
}

# shellcheck disable=SC2329
fss_reason_tags_from_output() {
  fss_classify_verify_output "$1"
  printf '%s' "$FSS_REASON_TAGS"
}

fss_classify_verify_output() {
  local output="$1"
  local line
  local line_lower
  local failure_path

  fss_reset_classification

  while IFS= read -r line || [ -n "$line" ]; do
    line_lower="${line,,}"

    case "$line_lower" in
    *"bad message"*)
      FSS_REASON_TAGS=$(fss_append_tag "$FSS_REASON_TAGS" "BAD_MESSAGE")
      ;;
    esac

    case "$line_lower" in
    *"input/output error"* | *"i/o error"*)
      FSS_REASON_TAGS=$(fss_append_tag "$FSS_REASON_TAGS" "INPUT_OUTPUT_ERROR")
      ;;
    esac

    case "$line_lower" in
    *parse*seed*)
      FSS_REASON_TAGS=$(fss_append_tag "$FSS_REASON_TAGS" "KEY_PARSE_ERROR")
      FSS_KEY_PARSE_ERROR=1
      ;;
    esac

    case "$line_lower" in
    *"required key not available"*)
      FSS_REASON_TAGS=$(fss_append_tag "$FSS_REASON_TAGS" "KEY_MISSING")
      FSS_KEY_REQUIRED_ERROR=1
      ;;
    esac

    case "$line_lower" in
    *"read-only file system"* | *"permission denied"* | *"cannot create"*)
      FSS_REASON_TAGS=$(fss_append_tag "$FSS_REASON_TAGS" "FILESYSTEM_RESTRICTION")
      FSS_FILESYSTEM_RESTRICTION=1
      ;;
    esac

    case "$line" in
    FAIL:\ *)
      FSS_FAIL_LINES=$(fss_append_line "$FSS_FAIL_LINES" "$line")
      failure_path="${line#FAIL: }"
      failure_path="${failure_path%% *}"

      case "$failure_path" in
      *.journal~)
        FSS_TEMP_FAILURES=$(fss_append_line "$FSS_TEMP_FAILURES" "$line")
        ;;
      */system.journal)
        FSS_ACTIVE_SYSTEM_FAILURES=$(fss_append_line "$FSS_ACTIVE_SYSTEM_FAILURES" "$line")
        ;;
      */system@*.journal)
        FSS_ARCHIVED_SYSTEM_FAILURES=$(fss_append_line "$FSS_ARCHIVED_SYSTEM_FAILURES" "$line")
        ;;
      */user-[0-9]*.journal)
        FSS_USER_FAILURES=$(fss_append_line "$FSS_USER_FAILURES" "$line")
        ;;
      *)
        FSS_OTHER_FAILURES=$(fss_append_line "$FSS_OTHER_FAILURES" "$line")
        ;;
      esac
      ;;
    esac
  done <<<"$output"
}

fss_classification_tags() {
  local tags="${1:-$FSS_REASON_TAGS}"

  if [ -n "$FSS_ACTIVE_SYSTEM_FAILURES" ]; then
    tags=$(fss_append_tag "$tags" "ACTIVE_SYSTEM")
  fi

  if [ -n "$FSS_ARCHIVED_SYSTEM_FAILURES" ]; then
    tags=$(fss_append_tag "$tags" "ARCHIVED_SYSTEM")
  fi

  if [ -n "$FSS_USER_FAILURES" ]; then
    tags=$(fss_append_tag "$tags" "USER_JOURNAL")
  fi

  if [ -n "$FSS_TEMP_FAILURES" ]; then
    tags=$(fss_append_tag "$tags" "TEMP")
  fi

  if [ -n "$FSS_OTHER_FAILURES" ]; then
    tags=$(fss_append_tag "$tags" "OTHER_FAILURE")
  fi

  printf '%s' "$tags"
}
