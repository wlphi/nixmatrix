{ ... }:

{
  # Two isolated Redis instances:
  #   - authelia  (port 6379) — Authelia session store
  #   - matrix    (port 6380) — shared bridge queue (mautrix-whatsapp backfill, etc.)
  #
  # Both bind to 127.0.0.1 only. No passwords — access is network-gated to localhost.

  services.redis.servers = {
    authelia = {
      enable = true;
      bind = "127.0.0.1";
      port = 6379;
      save = [
        [ 900 1 ]
        [ 300 10 ]
        [ 60 10000 ]
      ];
    };

    matrix = {
      enable = true;
      bind = "127.0.0.1";
      port = 6380;
      save = [
        [ 900 1 ]
        [ 300 10 ]
      ];
    };
  };
}
