# Copyright 2022-2025 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  ...
}:
let
  cfg = config.ghaf.logging.loki;
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    mapAttrsToList
    ;
in
{
  options.ghaf.logging.loki = {
    enable = mkEnableOption "local Loki instance with retention policies";

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address for Loki to listen on";
    };

    listenPort = mkOption {
      type = types.port;
      default = 3100;
      description = "Port for Loki HTTP API";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/loki";
      description = "Directory for Loki data storage";
    };

    retention = {
      enable = mkEnableOption "log retention policies";

      defaultPeriod = mkOption {
        type = types.str;
        default = "720h"; # 30 days
        description = "Default retention period for logs without specific category rules (e.g., '720h' for 30 days)";
      };

      categoryPeriods = mkOption {
        type = types.attrsOf types.str;
        default = {
          security = "2160h"; # 90 days
          system = "720h"; # 30 days
        };
        description = "Retention periods per log category";
        example = {
          security = "2160h";
          system = "720h";
          application = "168h";
        };
      };

      compactionInterval = mkOption {
        type = types.str;
        default = "10m";
        description = "How often to run compaction";
      };

      deleteDelay = mkOption {
        type = types.str;
        default = "2h";
        description = "Delay before deleting marked chunks";
      };
    };
  };

  config = mkIf cfg.enable {
    services.loki = {
      enable = true;
      configuration = {
        auth_enabled = false;

        server = {
          http_listen_address = cfg.listenAddress;
          http_listen_port = cfg.listenPort;
          grpc_listen_port = 9096;
          log_level = "info";
        };

        # Common configuration for all components
        common = {
          path_prefix = cfg.dataDir;
          storage = {
            filesystem = {
              chunks_directory = "${cfg.dataDir}/chunks";
              rules_directory = "${cfg.dataDir}/rules";
            };
          };
          replication_factor = 1;
          ring = {
            instance_addr = cfg.listenAddress;
            kvstore = {
              store = "inmemory";
            };
          };
        };

        # Schema configuration - required for retention
        schema_config = {
          configs = [
            {
              from = "2024-01-01";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index = {
                prefix = "ghaf_logs_";
                period = "24h"; # Required for retention to work
              };
            }
          ];
        };

        # Storage configuration
        storage_config = {
          tsdb_shipper = {
            active_index_directory = "${cfg.dataDir}/tsdb-index";
            cache_location = "${cfg.dataDir}/tsdb-cache";
          };
          filesystem = {
            directory = "${cfg.dataDir}/chunks";
          };
        };

        # Compactor configuration for retention
        compactor = mkIf cfg.retention.enable {
          working_directory = "${cfg.dataDir}/compactor";
          compaction_interval = cfg.retention.compactionInterval;
          retention_enabled = true;
          retention_delete_delay = cfg.retention.deleteDelay;
          retention_delete_worker_count = 150;
          delete_request_store = "filesystem";
        };

        # Limits configuration including retention policies
        limits_config = mkIf cfg.retention.enable {
          retention_period = cfg.retention.defaultPeriod;

          # Generate retention streams for each category
          retention_stream = mapAttrsToList (category: period: {
            selector = ''{log_category="${category}"}'';
            priority = 1;
            inherit period;
          }) cfg.retention.categoryPeriods;
        };

        # Query configuration
        query_range = {
          results_cache = {
            cache = {
              embedded_cache = {
                enabled = true;
                max_size_mb = 100;
              };
            };
          };
        };
      };
    };

    # Ensure the data directory exists with correct permissions
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 loki loki -"
      "d ${cfg.dataDir}/chunks 0750 loki loki -"
      "d ${cfg.dataDir}/tsdb-index 0750 loki loki -"
      "d ${cfg.dataDir}/tsdb-cache 0750 loki loki -"
      "d ${cfg.dataDir}/compactor 0750 loki loki -"
      "d ${cfg.dataDir}/rules 0750 loki loki -"
    ];

    # Open firewall for internal access if needed
    # By default only listening on localhost
    ghaf.firewall = mkIf (cfg.listenAddress != "127.0.0.1") {
      allowedTCPPorts = [ cfg.listenPort ];
    };

    # Audit configuration changes
    ghaf.security.audit.extraRules = [
      "-w ${cfg.dataDir} -p wa -k loki_data"
    ];
  };
}
