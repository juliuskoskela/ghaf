# Copyright 2022-2025 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.logging;
  enableLoki = cfg.server && cfg.local.enable;

  # Generate Loki config using buildPackages.jq for cross-compilation support
  lokiConfig = {
    auth_enabled = false;

    server = {
      http_listen_address = cfg.local.listenAddress;
      http_listen_port = cfg.local.listenPort;
      grpc_listen_port = 9096;
      log_level = "info";
    };

    common = {
      path_prefix = cfg.local.dataDir;
      storage = {
        filesystem = {
          chunks_directory = "${cfg.local.dataDir}/chunks";
          rules_directory = "${cfg.local.dataDir}/rules";
        };
      };
      replication_factor = 1;
      ring = {
        instance_addr = cfg.local.listenAddress;
        kvstore.store = "inmemory";
      };
    };

    # Ingester config - reduce memory usage
    ingester = {
      chunk_idle_period = "15m";
      chunk_block_size = 262144; # 256KB
      chunk_target_size = 1048576; # 1MB (smaller chunks)
      chunk_retain_period = "30s";
      max_transfer_retries = 0;
      wal = {
        enabled = false; # Disable WAL to save memory
      };
    };

    schema_config = {
      configs = [
        {
          from = "2024-01-01";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = {
            prefix = "ghaf_logs_";
            period = "24h";
          };
        }
      ];
    };

    storage_config = {
      tsdb_shipper = {
        active_index_directory = "${cfg.local.dataDir}/tsdb-index";
        cache_location = "${cfg.local.dataDir}/tsdb-cache";
      };
      filesystem = {
        directory = "${cfg.local.dataDir}/chunks";
      };
    };

    # Compactor for retention
    compactor = lib.optionalAttrs cfg.local.retention.enable {
      working_directory = "${cfg.local.dataDir}/compactor";
      compaction_interval = cfg.local.retention.compactionInterval;
      retention_enabled = true;
      retention_delete_delay = cfg.local.retention.deleteDelay;
      retention_delete_worker_count = 10; # Reduced from 150
      delete_request_store = "filesystem";
    };

    # Retention policies and resource limits
    limits_config = lib.optionalAttrs cfg.local.retention.enable {
      retention_period = cfg.local.retention.defaultPeriod;

      # Per-category retention
      retention_stream = lib.mapAttrsToList (category: period: {
        selector = ''{log_category="${category}"}'';
        priority = 1;
        inherit period;
      }) cfg.local.retention.categoryPeriods;

      # Resource limits for lightweight deployment
      max_query_parallelism = 4;
      max_query_series = 500;
      max_streams_per_user = 1000;
      max_global_streams_per_user = 2000;
      ingestion_rate_mb = 4;
      ingestion_burst_size_mb = 8;
      max_chunks_per_query = 2000000;
      max_query_length = "721h"; # ~30 days
    };

    # Query cache - reduced for low memory
    query_range = {
      results_cache = {
        cache = {
          embedded_cache = {
            enabled = true;
            max_size_mb = 32; # Reduced from 100
          };
        };
      };
    };
  };

  # Use buildPackages.jq for cross-compilation compatibility
  lokiConfigFile =
    pkgs.runCommand "loki-config.json" { nativeBuildInputs = [ pkgs.buildPackages.jq ]; }
      ''
        echo '${builtins.toJSON lokiConfig}' | jq > $out
      '';
in
{
  config = lib.mkIf enableLoki {
    services.loki = {
      enable = true;
      configFile = lokiConfigFile;
    };

    # Resource limits for Loki service
    systemd.services.loki.serviceConfig = {
      # Limit memory to 256MB
      MemoryMax = "256M";
      MemoryHigh = "200M";

      # Limit CPU to 50% of one core
      CPUQuota = "50%";

      # Lower priority
      Nice = 10;

      # OOM score (more likely to be killed under memory pressure)
      OOMScoreAdjust = 500;
    };

    # Create data directories
    systemd.tmpfiles.rules = [
      "d ${cfg.local.dataDir} 0750 loki loki -"
      "d ${cfg.local.dataDir}/chunks 0750 loki loki -"
      "d ${cfg.local.dataDir}/tsdb-index 0750 loki loki -"
      "d ${cfg.local.dataDir}/tsdb-cache 0750 loki loki -"
      "d ${cfg.local.dataDir}/compactor 0750 loki loki -"
      "d ${cfg.local.dataDir}/rules 0750 loki loki -"
    ];
  };
}
