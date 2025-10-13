# Copyright 2022-2025 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Debugging tools for the logging client
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.logging;

  # Test script for verifying logging client configuration
  logging-client-tests = pkgs.writeShellApplication {
    name = "logging-client-tests";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      systemd
      nettools
      gnugrep
      gawk
      iproute2
      procps
    ];
    text = ''
      set +e  # Don't exit on test failures

      RED='\033[0;31m'
      GREEN='\033[0;32m'
      YELLOW='\033[1;33m'
      NC='\033[0m' # No Color

      echo "============================================"
      echo "  Ghaf Logging Client Test Suite"
      echo "  Client VM/Host Verification"
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

      # 1. Service Status
      section "Service Status"

      if systemctl is-active --quiet alloy.service; then
        pass "Alloy service is running"
      else
        fail "Alloy service is not running"
        systemctl status alloy.service --no-pager -l
      fi

      # 2. Configuration Files
      section "Configuration Files"

      if [ -f /etc/alloy/config.alloy ]; then
        pass "Alloy config exists"
      else
        fail "Alloy config missing"
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

      ${lib.optionalString (cfg.tls.caFile != null) ''
        if [ -f ${cfg.tls.caFile} ]; then
          pass "TLS CA certificate exists"
        else
          fail "TLS CA certificate missing"
        fi
      ''}

      # 3. Network Connectivity
      section "Network Connectivity"

      if ping -c 1 -W 2 ${cfg.listener.address} > /dev/null 2>&1; then
        pass "Can reach admin-vm at ${cfg.listener.address}"
      else
        fail "Cannot reach admin-vm at ${cfg.listener.address}"
      fi

      # Check if admin-vm port is reachable
      if timeout 3 bash -c "echo > /dev/tcp/${cfg.listener.address}/${toString cfg.listener.port}" 2>/dev/null; then
        pass "Admin-vm logging port ${toString cfg.listener.port} is reachable"
      else
        warn "Cannot connect to admin-vm port ${toString cfg.listener.port} (may be TLS handshake issue)"
      fi

      # 4. Alloy Configuration
      section "Alloy Configuration"

      if grep -q "loki.source.journal" /etc/alloy/config.alloy; then
        pass "Alloy configured to read journal"
      else
        fail "Alloy journal source not configured"
      fi

      if grep -q "loki.write.server" /etc/alloy/config.alloy; then
        pass "Alloy configured to write to server"
      else
        fail "Alloy server write target not configured"
      fi

      if grep -q "https://${cfg.listener.address}:${toString cfg.listener.port}" /etc/alloy/config.alloy; then
        pass "Alloy points to correct server endpoint"
      else
        fail "Alloy server endpoint mismatch"
      fi

      # 5. WAL Directory
      section "Write-Ahead Log"

      WAL_DIR="/var/lib/alloy/data/loki.write.server/wal"
      if [ -d "$WAL_DIR" ]; then
        pass "WAL directory exists"

        WAL_COUNT=$(find "$WAL_DIR" -type f 2>/dev/null | wc -l)
        WAL_SIZE=$(du -sh "$WAL_DIR" 2>/dev/null | awk '{print $1}')

        if [ "$WAL_COUNT" -gt 0 ]; then
          pass "WAL contains $WAL_COUNT segment(s), size: $WAL_SIZE"
        else
          warn "WAL directory is empty (may not have collected logs yet)"
        fi
      else
        warn "WAL directory not found (service may not have started yet)"
      fi

      # 6. Journal Status
      section "Journal Status"

      if systemctl is-active --quiet systemd-journald.service; then
        pass "systemd-journald is running"
      else
        fail "systemd-journald is not running"
      fi

      JOURNAL_SIZE=$(journalctl --disk-usage 2>/dev/null | grep -oP 'Archived and active journals take up \K[^ ]+' || echo "unknown")
      pass "Journal disk usage: $JOURNAL_SIZE"

      # Check recent journal entries
      RECENT_ENTRIES=$(journalctl --since "5 minutes ago" --no-pager | wc -l)
      if [ "$RECENT_ENTRIES" -gt 0 ]; then
        pass "Journal has $RECENT_ENTRIES entries in last 5 minutes"
      else
        warn "No journal entries in last 5 minutes"
      fi

      # 7. Alloy Metrics (if available)
      section "Alloy Internal Metrics"

      # Try to get Alloy's internal metrics endpoint if exposed
      ALLOY_METRICS=$(pgrep -a alloy | grep -oP -- '--server.http.listen-addr=[^ ]+' | cut -d= -f2 || echo "")

      if [ -n "$ALLOY_METRICS" ]; then
        if curl -s --max-time 5 "http://$ALLOY_METRICS/metrics" > /dev/null 2>&1; then
          pass "Alloy metrics endpoint accessible at $ALLOY_METRICS"

          # Check for WAL stats
          WAL_SEGMENTS=$(curl -s --max-time 5 "http://$ALLOY_METRICS/metrics" 2>/dev/null | grep "alloy_loki_write_wal_segments" | grep -v "#" | awk '{print $2}' || echo "0")
          if [ "$WAL_SEGMENTS" != "0" ]; then
            pass "WAL has $WAL_SEGMENTS active segments"
          fi
        else
          warn "Alloy metrics endpoint not accessible"
        fi
      else
        warn "Alloy metrics endpoint not configured"
      fi

      # 8. Service Permissions
      section "Service Permissions"

      # Check if alloy is in systemd-journal group
      if groups alloy 2>/dev/null | grep -q systemd-journal; then
        pass "Alloy user is in systemd-journal group"
      else
        fail "Alloy user missing systemd-journal group membership"
      fi

      # 9. Recent Errors
      section "Recent Errors"

      ERROR_COUNT=$(journalctl -u alloy.service --since "5 minutes ago" --no-pager -p err | grep -v -c -e "^--" -e "^Hint:" || echo "0")
      if [ "$ERROR_COUNT" -eq 0 ]; then
        pass "No errors in Alloy logs (last 5 minutes)"
      else
        fail "Found $ERROR_COUNT error(s) in Alloy logs:"
        journalctl -u alloy.service --since "5 minutes ago" --no-pager -p err | tail -10
      fi

      # Summary
      section "Summary"
      echo ""
      echo "Tests passed: $PASSED"
      echo "Tests failed: $FAILED"
      echo ""

      if [ $FAILED -eq 0 ]; then
        echo -e "''${GREEN}All tests passed!''${NC}"
        echo ""
        echo "Client is sending logs to: https://${cfg.listener.address}:${toString cfg.listener.port}"
        exit 0
      else
        echo -e "''${RED}Some tests failed. Check the output above.''${NC}"
        exit 1
      fi
    '';
  };
in
{
  config = lib.mkIf (cfg.client && cfg.debug) {
    # Install debug tools
    environment.systemPackages = [ logging-client-tests ];
  };
}
