#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=bash
# shellcheck disable=SC2034

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
