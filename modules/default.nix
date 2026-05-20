{ ... }:

{
  imports = [
    # Core services (Phase 1)
    ./postgres.nix
    ./redis.nix
    ./synapse.nix
    ./mas.nix
    ./caddy.nix

    # Client frontends (Phase 2)
    ./element-web.nix

    # Optional SSO (Phase 3)
    ./authelia.nix

    # Bridges (Phase 4)
    ./bridges/doublepuppet.nix
    ./bridges/telegram.nix
    ./bridges/whatsapp.nix
    ./bridges/signal.nix
    ./bridges/discord.nix

    # Element Call / LiveKit (Phase 5)
    ./livekit.nix

    # Monitoring (Phase 6)
    ./monitoring.nix
  ];
}
