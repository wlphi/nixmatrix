{ config, pkgs, lib, ... }:

# Prometheus + node_exporter + Grafana
# Grafana: https://monitoring.mair.io (proxied by Caddy)
# Prometheus and exporters: localhost only, not externally exposed

{
  sops.secrets."matrix/grafana_secret_key" = { owner = "grafana"; };

  services.prometheus = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9090;
    retentionTime = "30d";

    exporters = {
      node = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 9100;
        enabledCollectors = [
          "cpu" "diskstats" "filesystem" "loadavg"
          "meminfo" "netdev" "netstat" "stat"
          "time" "uname"
        ];
      };
    };

    scrapeConfigs = [
      {
        job_name = "node";
        static_configs = [{
          targets = [ "127.0.0.1:9100" ];
        }];
      }
      {
        job_name = "synapse";
        metrics_path = "/_synapse/metrics";
        static_configs = [{
          targets = [ "127.0.0.1:9092" ];
        }];
      }
      {
        job_name = "caddy";
        static_configs = [{
          # Caddy exposes Prometheus metrics if configured
          targets = [ "127.0.0.1:2019" ];
        }];
      }
      {
        job_name = "postgresql";
        static_configs = [{
          targets = [ "127.0.0.1:9187" ];
        }];
      }
    ];
  };

  # PostgreSQL exporter for Prometheus
  services.prometheus.exporters.postgres = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9187;
    runAsLocalSuperUser = true;
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "127.0.0.1";
        http_port = 3000;
        domain = "monitoring.mair.io";
        root_url = "https://monitoring.mair.io";
      };
      security = {
        admin_user = "admin";
        disable_gravatar = true;
        # Required since NixOS 26.05 — used to encrypt secrets stored in Grafana's DB
        secret_key = "$__file{${config.sops.secrets."matrix/grafana_secret_key".path}}";
      };
      analytics.reporting_enabled = false;
    };

    provision = {
      enable = true;
      datasources.settings.datasources = [{
        name = "Prometheus";
        type = "prometheus";
        url = "http://127.0.0.1:9090";
        isDefault = true;
      }];
    };
  };

  # Enable Caddy Prometheus metrics endpoint (requires Caddy admin API)
  services.caddy.globalConfig = lib.mkAfter ''
    servers {
      metrics
    }
  '';
}
