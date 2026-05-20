{ config, pkgs, lib, ... }:

{
  # ── Identity ──────────────────────────────────────────────────────────────
  networking.hostName = "matrix";
  networking.domain = "mair.io";
  time.timeZone = "UTC";

  # ── Firewall ──────────────────────────────────────────────────────────────
  # Only ports that need to be externally reachable.
  # All internal service ports (8008 Synapse, 8080 MAS, 5432 PostgreSQL, etc.)
  # bind to 127.0.0.1 and are NOT opened here.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22    # SSH
      80    # Caddy HTTP (redirects to 443)
      443   # Caddy HTTPS
      7881  # LiveKit WebRTC TCP fallback
    ];
    allowedUDPPortRanges = [
      { from = 50100; to = 50200; }  # LiveKit RTP media
    ];
  };

  # ── SSH ───────────────────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  # ── Boot ──────────────────────────────────────────────────────────────────
  # disko (disk.nix) handles partitioning and filesystem for nixos-anywhere.
  # For a manually-installed host, replace with hardware-configuration.nix.
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    # disko sets devices — do not set here
  };

  # ── sops-nix ──────────────────────────────────────────────────────────────
  # Host decryption key derived from /etc/age/key.txt.
  # Generate on target: age-keygen -o /etc/age/key.txt
  # Then add the public key to .sops.yaml and re-encrypt secrets/secrets.yaml.
  sops = {
    defaultSopsFile = ../secrets/secrets.yaml;
    age.keyFile = "/etc/age/key.txt";
    # Alternatively, derive age key from the host SSH key (no separate age key needed):
    # age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };

  # ── Insecure packages ─────────────────────────────────────────────────────
  # libolm is a bridge transitive dependency. We disable E2E encryption in all
  # bridges (encryption.allow = false), so libolm is not functionally used.
  nixpkgs.config.permittedInsecurePackages = [ "olm-3.2.16" ];

  # ── System packages ───────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    curl
    git
    htop
    jq
    age
    sops
    postgresql  # psql client for debugging
  ];

  # ── Container runtime (for LiveKit OCI containers) ────────────────────────
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  system.stateVersion = "25.11";
}
