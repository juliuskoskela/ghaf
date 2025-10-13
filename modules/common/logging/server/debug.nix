# Copyright 2022-2025 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Debugging tools for the logging server
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.logging;

  # Test script for verifying logging server configuration
  logging-server-tests = pkgs.writeShellApplication {
    name = "logging-server-tests";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
      systemd
      nettools
      gnugrep
      gawk
    ];
    text = ''
      set +e  # Don't exit on test failures

      RED='\033[0;31m'
      GREEN='\033[0;32m'
      YELLOW='\033[1;33m'
      NC='\033[0m' # No Color

      echo "============================================"
      echo "  Ghaf Logging Server Test Suite"
      echo "  Admin-VM Verification"
      echo "============================================"
      echo ""

      PASSED=0
      FAILED=0

      pass() {
        echo -e "''${GREEN}[PASS]''${NC} $1"
        ((PASSED++))
      }

      fail() {
        echo -e "''${RED}[FAIL]''${NC} $1"
        ((FAILED++))
      }

      warn() {
        echo -e "''${YELLOW}[WARN]''${NC} $1"
      }

      section() {
        echo ""
        echo ">>> $1"
      }

      # 1. Service Status Checks
      section "Service Status"

      if systemctl is-active --quiet alloy.service; then
        pass "Alloy service is running"
      else
        fail "Alloy service is not running"
        systemctl status alloy.service --no-pager -l
      fi

      if systemctl is-active --quiet loki.service; then
        pass "Loki service is running"
      else
        fail "Loki service is not running"
        systemctl status loki.service --no-pager -l
      fi

      if systemctl is-active --quiet stunnel.service; then
        pass "stunnel service is running"
      else
        fail "stunnel service is not running"
        systemctl status stunnel.service --no-pager -l
      fi

      # 2. Port Listening Checks
      section "Port Listeners"

      if netstat -tln | grep -q ":${toString cfg.local.listenPort} "; then
        pass "Loki listening on port ${toString cfg.local.listenPort}"
      else
        fail "Loki not listening on port ${toString cfg.local.listenPort}"
      fi

      if netstat -tln | grep -q ":${toString cfg.listener.backendPort} "; then
        pass "Alloy listening on port ${toString cfg.listener.backendPort}"
      else
        fail "Alloy not listening on port ${toString cfg.listener.backendPort}"
      fi

      if netstat -tln | grep -q ":${toString cfg.listener.port} "; then
        pass "stunnel listening on port ${toString cfg.listener.port}"
      else
        fail "stunnel not listening on port ${toString cfg.listener.port}"
      fi

      # 3. Configuration Files
      section "Configuration Files"

      if [ -f /etc/alloy/config.alloy ]; then
        pass "Alloy config exists"
      else
        fail "Alloy config missing"
      fi

      if [ -f ${cfg.identifierFilePath} ]; then
        pass "Device identifier exists"
      else
        fail "Device identifier missing"
      fi

      if [ -f ${cfg.tls.certFile} ]; then
        pass "TLS certificate exists"
      else
        fail "TLS certificate missing"
      fi

      if [ -f ${cfg.tls.keyFile} ]; then
        pass "TLS key exists"
      else
        fail "TLS key missing"
      fi

      # 4. Loki API Health
      section "Loki API Health"

      READY=$(curl -s http://${cfg.local.listenAddress}:${toString cfg.local.listenPort}/ready || echo "failed")
      if [ "$READY" = "ready" ]; then
        pass "Loki is ready"
      else
        fail "Loki not ready (got: $READY)"
      fi

      METRICS=$(curl -s http://${cfg.local.listenAddress}:${toString cfg.local.listenPort}/metrics | grep -c "loki_" || echo "0")
      if [ "$METRICS" -gt 0 ]; then
        pass "Loki metrics available ($METRICS metrics)"
      else
        fail "Loki metrics not available"
      fi

      # 5. Query Test
      section "Log Query Test"

      # Query for logs from the last 5 minutes
      QUERY_URL="http://${cfg.local.listenAddress}:${toString cfg.local.listenPort}/loki/api/v1/query_range"
      NOW=$(date +%s)000000000
      FIVE_MIN_AGO=$(( $(date +%s) - 300 ))000000000

      RESULT=$(curl -s -G "$QUERY_URL" \
        --data-urlencode "query={host=~\".+\"}" \
        --data-urlencode "start=$FIVE_MIN_AGO" \
        --data-urlencode "end=$NOW" \
        --data-urlencode "limit=10" | jq -r '.status' 2>/dev/null || echo "failed")

      if [ "$RESULT" = "success" ]; then
        pass "Can query Loki successfully"

        # Count unique hosts
        HOSTS=$(curl -s -G "$QUERY_URL" \
          --data-urlencode "query={host=~\".+\"}" \
          --data-urlencode "start=$FIVE_MIN_AGO" \
          --data-urlencode "end=$NOW" | \
          jq -r '.data.result[].stream.host' 2>/dev/null | sort -u | wc -l)

        if [ "$HOSTS" -gt 1 ]; then
          pass "Receiving logs from $HOSTS different hosts"
        elif [ "$HOSTS" -eq 1 ]; then
          warn "Only receiving logs from 1 host (admin-vm itself?)"
        else
          warn "No hosts found in recent logs"
        fi
      else
        fail "Cannot query Loki (got: $RESULT)"
      fi

      # 6. Categorization Check
      ${lib.optionalString cfg.categorization.enable ''
        section "Log Categorization"

        SECURITY_LOGS=$(curl -s -G "$QUERY_URL" \
          --data-urlencode 'query={log_category="security"}' \
          --data-urlencode "start=$FIVE_MIN_AGO" \
          --data-urlencode "end=$NOW" | \
          jq -r '.data.result | length' 2>/dev/null || echo "0")

        SYSTEM_LOGS=$(curl -s -G "$QUERY_URL" \
          --data-urlencode 'query={log_category="system"}' \
          --data-urlencode "start=$FIVE_MIN_AGO" \
          --data-urlencode "end=$NOW" | \
          jq -r '.data.result | length' 2>/dev/null || echo "0")

        if [ "$SECURITY_LOGS" -gt 0 ]; then
          pass "Security logs found ($SECURITY_LOGS streams)"
        else
          warn "No security logs in last 5 minutes"
        fi

        if [ "$SYSTEM_LOGS" -gt 0 ]; then
          pass "System logs found ($SYSTEM_LOGS streams)"
        else
          warn "No system logs in last 5 minutes"
        fi
      ''}

      # 7. Retention Configuration
      ${lib.optionalString cfg.local.retention.enable ''
        section "Retention Configuration"

        COMPACTOR_RUNNING=$(curl -s http://${cfg.local.listenAddress}:${toString cfg.local.listenPort}/metrics | grep -c "loki_compactor_" || echo "0")
        if [ "$COMPACTOR_RUNNING" -gt 0 ]; then
          pass "Compactor is active"
        else
          warn "Compactor metrics not found (may not have run yet)"
        fi
      ''}

      # 8. Disk Usage
      section "Disk Usage"

      if [ -d "${cfg.local.dataDir}" ]; then
        DISK_USAGE=$(du -sh ${cfg.local.dataDir} 2>/dev/null | awk '{print $1}')
        pass "Loki data directory: $DISK_USAGE"
      else
        fail "Loki data directory not found"
      fi

      WAL_SIZE=$(du -sh /var/lib/alloy/data/loki.write.*/wal 2>/dev/null | awk '{sum+=$1} END {print sum}' || echo "0")
      if [ "$WAL_SIZE" != "0" ]; then
        pass "Alloy WAL size: $WAL_SIZE"
      else
        warn "Alloy WAL not found or empty"
      fi

      # Summary
      section "Summary"
      echo ""
      echo "Tests passed: $PASSED"
      echo "Tests failed: $FAILED"
      echo ""

      if [ $FAILED -eq 0 ]; then
        echo -e "''${GREEN}All tests passed!''${NC}"
        exit 0
      else
        echo -e "''${RED}Some tests failed. Check the output above.''${NC}"
        exit 1
      fi
    '';
  };
in
{
  config = lib.mkIf (cfg.server && cfg.debug) {
    # Install debug tools
    environment.systemPackages = [ logging-server-tests ];
  };
}
