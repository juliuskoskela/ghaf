# Copyright 2022-2025 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ config, lib, ... }:
let
  cfg = config.ghaf.logging;
  inherit (lib) optionalString;
in
{
  config = lib.mkIf cfg.client {
    environment.etc."alloy/config.alloy" = {
      text = ''
        // ============================================
        // CLIENT CONFIGURATION
        // Sends logs to admin-vm for aggregation
        // ============================================

        // TLS credentials from systemd
        local.file "tls_cert" {
          filename = sys.env("CREDENTIALS_DIRECTORY") + "/loki_cert"
        }
        local.file "tls_key" {
          filename = sys.env("CREDENTIALS_DIRECTORY") + "/loki_key"
        }
        ${optionalString (cfg.tls.caFile != null) ''
          local.file "tls_ca" {
            filename = sys.env("CREDENTIALS_DIRECTORY") + "/loki_ca"
          }
        ''}

        // Collect local journal logs
        loki.source.journal "journal" {
          path       = "/var/log/journal"
          forward_to = [loki.write.adminvm.receiver]
        }

        // Forward to admin-vm
        loki.write "adminvm" {
          endpoint {
            url = "https://${cfg.listener.address}:${toString cfg.listener.port}/loki/api/v1/push"

            tls_config {
              ${optionalString (cfg.tls.caFile != null) ''ca_pem = local.file.tls_ca.content''}
              cert_pem    = local.file.tls_cert.content
              key_pem     = local.file.tls_key.content
              min_version = "${cfg.tls.minVersion}"
            }
          }

          // Write-Ahead Log for reliability
          wal {
            enabled         = true
            max_segment_age = "240h"
            drain_timeout   = "4s"
          }

          // Only add hostname label
          external_labels = {
            hostname = env("HOSTNAME")
          }
        }
      '';
      mode = "0644";
    };
  };
}
