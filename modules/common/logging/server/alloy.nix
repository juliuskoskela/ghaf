# Copyright 2022-2025 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ config, lib, ... }:
let
  cfg = config.ghaf.logging;
  inherit (lib) optionalString concatStringsSep;
in
{
  config = lib.mkIf cfg.server {
    environment.etc."alloy/config.alloy" = {
      text = ''
        // ============================================
        // SERVER CONFIGURATION
        // Receives, processes, and stores logs
        // ============================================

        // Device identifier
        local.file "machine_id" {
          filename = "${cfg.identifierFilePath}"
        }

        // TLS credentials from systemd
        local.file "tls_cert" {
          filename = sys.env("CREDENTIALS_DIRECTORY") + "/loki_cert"
        }
        local.file "tls_key" {
          filename = sys.env("CREDENTIALS_DIRECTORY") + "/loki_key"
        }
        ${optionalString (cfg.tls.remoteCAFile != null) ''
          local.file "remote_ca" {
            filename = sys.env("CREDENTIALS_DIRECTORY") + "/remote_ca"
          }
        ''}
        ${optionalString (cfg.tls.caFile != null) ''
          local.file "tls_ca" {
            filename = sys.env("CREDENTIALS_DIRECTORY") + "/loki_ca"
          }
        ''}

        // ============================================
        // RECEIVE FROM CLIENTS
        // ============================================
        loki.source.api "listener" {
          http {
            listen_address = "127.0.0.1"
            listen_port    = ${toString cfg.listener.backendPort}
          }
          forward_to = [loki.process.incoming.receiver]
        }

        // ============================================
        // ADMIN-VM OWN LOGS
        // ============================================
        discovery.relabel "admin_journal" {
          targets = []
          rule {
            source_labels = ["__journal__hostname"]
            target_label  = "host"
          }
          rule {
            source_labels = ["__journal__systemd_unit"]
            target_label  = "service_name"
          }
          // Fallback to syslog identifier
          rule {
            source_labels = ["service_name","__journal__syslog_identifier"]
            regex         = "^$;(.*)"
            target_label  = "service_name"
            replacement   = "$1"
            separator     = ";"
          }
          ${optionalString cfg.categorization.enable ''
            // Categorization for admin-vm logs
            rule {
              source_labels = ["__journal__systemd_unit"]
              regex         = "^(${concatStringsSep "|" cfg.categorization.securityServices})\\.service$"
              target_label  = "log_category"
              replacement   = "security"
            }
            rule {
              source_labels = ["__journal__systemd_unit"]
              regex         = "^sshd@.+\\.service$"
              target_label  = "log_category"
              replacement   = "security"
            }
            rule {
              source_labels = ["__journal__syslog_identifier"]
              regex         = "(?i)^(${concatStringsSep "|" cfg.categorization.securityIdentifiers})$"
              target_label  = "log_category"
              replacement   = "security"
            }
            rule {
              source_labels = ["log_category"]
              regex         = "^$"
              target_label  = "log_category"
              replacement   = "system"
            }
          ''}
        }

        loki.source.journal "journal" {
          path          = "/var/log/journal"
          relabel_rules = discovery.relabel.admin_journal.rules
          forward_to    = [
            ${optionalString cfg.local.enable "loki.write.local.receiver,"}
            ${optionalString cfg.remote.enable "loki.write.external.receiver,"}
          ]
        }

        // ============================================
        // PROCESS INCOMING LOGS (from clients)
        // ============================================
        loki.process "incoming" {
          forward_to = [
            ${optionalString cfg.local.enable "loki.write.local.receiver,"}
            ${optionalString cfg.remote.enable "loki.write.external.receiver,"}
          ]

          // Extract labels
          stage.labels {
            values = {
              host         = "__journal__hostname",
              service_name = "__journal__systemd_unit",
            }
          }

          // Fallback to syslog identifier
          stage.match {
            selector = "{service_name=\"\"}"
            stage.labels {
              values = {
                service_name = "__journal__syslog_identifier",
              }
            }
          }

          ${optionalString cfg.categorization.enable ''
            // Server-side categorization
            stage.static_labels {
              values = { log_category = "system" }
            }

            stage.match {
              selector = "{service_name=~\"^(${concatStringsSep "|" cfg.categorization.securityServices})\\.service$\"}"
              stage.static_labels {
                values = { log_category = "security" }
              }
            }

            stage.match {
              selector = "{service_name=~\"^sshd@.+\\.service$\"}"
              stage.static_labels {
                values = { log_category = "security" }
              }
            }

            stage.match {
              selector = "{__journal__syslog_identifier=~\"(?i)^(${concatStringsSep "|" cfg.categorization.securityIdentifiers})$\"}"
              stage.static_labels {
                values = { log_category = "security" }
              }
            }
          ''}

          // Filter noisy logs
          stage.drop {
            expression = "(GatewayAuthenticator::login|Gateway login succeeded|csd-wrapper|nmcli)"
          }
        }

        // ============================================
        // WRITE DESTINATIONS
        // ============================================
        ${optionalString cfg.local.enable ''
          loki.write "local" {
            endpoint {
              url = "http://${cfg.local.listenAddress}:${toString cfg.local.listenPort}/loki/api/v1/push"
            }

            wal {
              enabled         = true
              max_segment_age = "240h"
              drain_timeout   = "4s"
            }

            external_labels = {
              machine = local.file.machine_id.content
            }
          }
        ''}

        ${optionalString cfg.remote.enable ''
          loki.write "external" {
            endpoint {
              url = "${cfg.remote.endpoint}"

              basic_auth {
                username = "ghaf"
                password_file = "/etc/loki/pass"
              }

              tls_config {
                ${optionalString (cfg.tls.remoteCAFile != null) ''ca_pem = local.file.remote_ca.content''}
                cert_pem    = local.file.tls_cert.content
                key_pem     = local.file.tls_key.content
                min_version = "${cfg.tls.minVersion}"
                ${optionalString (cfg.tls.serverName != null) ''server_name = "${cfg.tls.serverName}"''}
              }
            }

            wal {
              enabled         = true
              max_segment_age = "240h"
              drain_timeout   = "4s"
            }

            external_labels = {
              machine = local.file.machine_id.content
            }
          }
        ''}
      '';
      mode = "0644";
    };
  };
}
