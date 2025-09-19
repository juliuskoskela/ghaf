# Copyright 2022-2025 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  ...
}:
let
  cfg = config.ghaf.logging.client;
  inherit (config.ghaf.logging) listener categorization;
  inherit (lib) concatStringsSep optionalString;
in
{
  options.ghaf.logging.client = {
    enable = lib.mkEnableOption "Enable the alloy client service";
    endpoint = lib.mkOption {
      description = ''
        Assign endpoint url value to the alloy.service running in
        different log producers. This endpoint URL will include
        protocol, upstream, address along with port value.
      '';
      type = lib.types.str;
      default = "http://${listener.address}:${toString listener.port}/loki/api/v1/push";
    };
  };
  config = lib.mkIf cfg.enable {

    assertions = [
      {
        assertion = listener.address != "";
        message = "Please provide a listener address, or disable the module.";
      }
    ];

    environment.etc."alloy/client.alloy" = {
      text = ''
        discovery.relabel "journal" {
          targets = []
          rule {
            source_labels = ["__journal__hostname"]
            target_label  = "host"
          }
          rule {
            source_labels = ["__journal__systemd_unit"]
            target_label  = "service_name"
          }
          # Fallback: if service_name is empty, use syslog identifier
          rule {
            source_labels = ["service_name","__journal__syslog_identifier"]
            regex         = "^$;(.*)"
            target_label  = "service_name"
            replacement   = "$1"
            separator     = ";"
          }
          ${optionalString categorization.enable ''
            # Log categorization rules (order matters!)

            # 1) Match systemd units (anchored regex)
            rule {
              source_labels = ["__journal__systemd_unit"]
              regex         = "^(${concatStringsSep "|" categorization.securityServices})\.service$"
              target_label  = "log_category"
              replacement   = "security"
            }

            # 2) Match templated sshd units (e.g., sshd@foo.service)
            rule {
              source_labels = ["__journal__systemd_unit"]
              regex         = "^sshd@.+\.service$"
              target_label  = "log_category"
              replacement   = "security"
            }

            # 3) Match syslog identifiers (case-insensitive for robustness)
            rule {
              source_labels = ["__journal__syslog_identifier"]
              regex         = "(?i)^(${concatStringsSep "|" categorization.securityIdentifiers})$"
              target_label  = "log_category"
              replacement   = "security"
            }

            # 4) Default to "system" ONLY if log_category is not already set
            rule {
              source_labels = ["log_category"]
              regex         = "^$"  # Only matches empty label
              target_label  = "log_category"
              replacement   = "system"
            }
          ''}
        }

        loki.source.journal "journal" {
          path          = "/var/log/journal"
          relabel_rules = discovery.relabel.journal.rules
          forward_to    = [loki.write.adminvm.receiver]
        }

        loki.write "adminvm" {
          endpoint {
            url = "${cfg.endpoint}"
          }
        }
      '';
      # The UNIX file mode bits
      mode = "0644";
    };

    services.alloy.enable = true;
    # Once alloy.service in admin-vm stopped this service will
    # still keep on retrying to send logs batch, so we need to
    # stop it forcefully.
    systemd.services.alloy.serviceConfig.TimeoutStopSec = 4;

    ghaf.security.audit.extraRules = [
      "-w /etc/alloy/client.alloy -p rwxa -k alloy_client_config"
    ];
  };
}
