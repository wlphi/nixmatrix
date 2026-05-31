{ config, pkgs, lib, ... }:

{
  # ── Identity ──────────────────────────────────────────────────────────────
  # ┌─────────────────────────────────────────────────────────────────────┐
  # │ CHANGE THIS to deploy your own instance. This is the ONE value that   │
  # │ matters — every service subdomain (matrix.*, auth.*, element.*, …)    │
  # │ and Matrix user IDs (@user:<domain>) are derived from it.             │
  # └─────────────────────────────────────────────────────────────────────┘
  nixmatrix.domain = "example.com";
  # Optional: contact email for Let's Encrypt (defaults to admin@<domain>).
  # nixmatrix.acmeEmail = "you@example.com";

  networking.hostName = "matrix";
  networking.domain = config.nixmatrix.domain;
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
      8448  # Matrix federation (some servers connect here directly, bypassing
            # well-known delegation). Caddy listens on 443; 8448 is opened so
            # federation still works for peers that don't honour delegation.
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

  # ┌─────────────────────────────────────────────────────────────────────┐
  # │ REQUIRED: add your SSH public key(s) here BEFORE deploying.           │
  # │ Password auth is disabled, so without this you will be locked out of  │
  # │ the server after the install. Get yours with: cat ~/.ssh/id_ed25519.pub
  # └─────────────────────────────────────────────────────────────────────┘
  users.users.root.openssh.authorizedKeys.keys = [
    # "ssh-ed25519 AAAA... you@example.com"
  ];

  # ── Boot ──────────────────────────────────────────────────────────────────
  # disko (disk.nix) handles partitioning and filesystem for nixos-anywhere.
  # For a manually-installed host, replace with hardware-configuration.nix.
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    # UEFI boot: GRUB installs to the EFI System Partition (the EF00 partition
    # disko creates), not to a disk MBR — so "nodev". efiInstallAsRemovable
    # writes the fallback bootloader path, which is what VPS firmware boots.
    devices = [ "nodev" ];
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

  # ── Cloud metadata / DNS protection ───────────────────────────────────────
  # CRITICAL on cloud VMs (GCP, AWS, Azure, Hetzner Cloud, …): the metadata and
  # DNS service lives at the link-local address 169.254.169.254. When podman
  # starts containers, dhcpcd hands their veth interfaces IPv4 link-local
  # (169.254.0.0/16) addresses, which install a 169.254.0.0/16 route that
  # HIJACKS the metadata IP onto the container bridge — DNS then dies host-wide
  # once containers run. Two guards:
  #   1. tell dhcpcd not to auto-assign link-local addresses, and
  #   2. pin an explicit /32 route to the metadata server via the real gateway,
  #      so it always wins regardless of any link-local route.
  networking.dhcpcd.extraConfig = ''
    noipv4ll
  '';
  # The metadata IP is reached via the default gateway on the primary interface.
  # 169.254.169.254 is the universal cloud metadata address; routing it over the
  # default route keeps DNS working even if a link-local /16 route reappears.
  systemd.services.pin-metadata-route = {
    description = "Pin a host route to the cloud metadata server (169.254.169.254)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # Route via the interface that owns the default route; harmless if it already exists.
    script = ''
      dev=$(${pkgs.iproute2}/bin/ip -o route show default | ${pkgs.gawk}/bin/awk '{print $5; exit}')
      gw=$(${pkgs.iproute2}/bin/ip -o route show default | ${pkgs.gawk}/bin/awk '{print $3; exit}')
      if [ -n "$dev" ] && [ -n "$gw" ]; then
        ${pkgs.iproute2}/bin/ip route replace 169.254.169.254/32 via "$gw" dev "$dev" || \
        ${pkgs.iproute2}/bin/ip route replace 169.254.169.254/32 dev "$dev"
      fi
    '';
  };

  system.stateVersion = "25.11";
}
