{ config, pkgs, lib, ... }:

# LiveKit + lk-jwt-service as OCI (Podman) containers.
#
# `services.livekit` is NOT a standard NixOS module — running containerised
# is safer than assuming the native module exists.
#
# Caddy (caddy.nix) routes:
#   rtc.example.com/livekit/jwt  → localhost:8082 (lk-jwt-service)
#   rtc.example.com/livekit/sfu  → localhost:7880 (livekit)
#
# Firewall (hosts/matrix-server.nix) opens:
#   7881/tcp  — WebRTC TCP fallback
#   50100-50200/udp — RTP media

let
  domain = config.nixmatrix.domain;
  # Pin specific versions — never use :latest (breaks reproducibility silently)
  # Check for new versions: https://github.com/livekit/livekit/releases
  livekitVersion = "v1.7.2";
  # Check: https://github.com/element-hq/lk-jwt-service/releases
  lkJwtVersion = "v0.2.1";

  turn = config.nixmatrix.turn;
  # relayRange is "start-end"; split it for the LiveKit config keys.
  relayParts = lib.splitString "-" turn.relayRange;
  relayStart = lib.elemAt relayParts 0;
  relayEnd = lib.elemAt relayParts 1;

  # Built-in TURN server, on only when nixmatrix.turn.enable is set. TURN/UDP
  # needs no certificate; clients reach it on turn.udpPort and media is relayed
  # to the SFU through relayRange. domain just needs to resolve to this host.
  turnConfig = lib.optionalString turn.enable ''
    turn:
      enabled: true
      domain: rtc.${domain}
      udp_port: ${toString turn.udpPort}
      relay_range_start: ${relayStart}
      relay_range_end: ${relayEnd}
  '';
in

{
  sops.secrets."matrix/livekit_secret" = {};

  sops.templates."livekit-jwt-env" = {
    content = ''
      LIVEKIT_URL=wss://rtc.${domain}/livekit/sfu
      LIVEKIT_KEY=livekit-key
      LIVEKIT_SECRET=${config.sops.placeholder."matrix/livekit_secret"}
      LIVEKIT_FULL_ACCESS_HOMESERVERS=${domain}
    '';
    mode = "0400";
  };

  sops.templates."livekit-config" = {
    content = ''
      port: 7880
      bind_addresses:
        - "127.0.0.1"
      rtc:
        tcp_port: 7881
        port_range_start: 50100
        port_range_end: 50200
        use_external_ip: true
      keys:
        livekit-key: "${config.sops.placeholder."matrix/livekit_secret"}"
      logging:
        json: true
        level: info
    '' + turnConfig;
    path = "/var/lib/livekit/config.yaml";
    mode = "0644";
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/livekit 0755 root root -"
  ];

  # Open the TURN ports to the internet when TURN is enabled. (The base media
  # ports — TCP 7881, UDP 50100–50200 — are opened in hosts/matrix-server.nix.)
  networking.firewall = lib.mkIf turn.enable {
    allowedUDPPorts = [ turn.udpPort ];
    allowedUDPPortRanges = [{
      from = lib.toInt relayStart;
      to = lib.toInt relayEnd;
    }];
  };

  virtualisation.oci-containers.containers = {

    livekit = {
      image = "livekit/livekit-server:${livekitVersion}";
      ports = [
        "127.0.0.1:7880:7880"  # HTTP / admin (internal only)
        "0.0.0.0:7881:7881"    # WebRTC TCP fallback (public — firewall opens this)
        "0.0.0.0:50100-50200:50100-50200/udp"  # RTP media
      ] ++ lib.optionals turn.enable [
        # TURN server (public) — only when nixmatrix.turn.enable is set.
        "0.0.0.0:${toString turn.udpPort}:${toString turn.udpPort}/udp"  # TURN listener
        "0.0.0.0:${relayStart}-${relayEnd}:${relayStart}-${relayEnd}/udp"  # TURN relay → SFU
      ];
      volumes = [
        "${config.sops.templates."livekit-config".path}:/config.yaml:ro"
      ];
      cmd = [ "--config" "/config.yaml" "--node-ip" "AUTO" ];
      # NB: do NOT add "--restart=..." here. The oci-containers module runs
      # podman with --rm and lets systemd handle restarts; passing --restart
      # conflicts with --rm and podman refuses to start (status 125).
    };

    lk-jwt-service = {
      image = "ghcr.io/element-hq/lk-jwt-service:${lkJwtVersion}";
      ports = [ "127.0.0.1:8082:8080" ];  # bind to localhost only — Caddy proxies
      environmentFiles = [ config.sops.templates."livekit-jwt-env".path ];
    };
  };
}
