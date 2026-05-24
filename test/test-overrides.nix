{ lib, config, ... }:

# VM-only overrides — never import this in production configs.
# Provides dummy secrets via a test age key so the VM builds and boots
# without needing a deployed host key or real credentials.

{
  # Use test age key and test secrets instead of the production secrets file.
  # Run test/setup-test-secrets.sh once to generate these files before building.
  sops = {
    defaultSopsFile = lib.mkForce ../test/test-secrets.yaml;
    age = {
      # /etc/test-age-key.txt is embedded below from the gitignored test key.
      # sops-nix reads this at runtime to decrypt test-secrets.yaml.
      keyFile = lib.mkForce "/etc/test-age-key.txt";
      sshKeyPaths = lib.mkForce [];
    };
    gnupg.sshKeyPaths = lib.mkForce [];
  };

  # Embed the test age key into the VM image.
  # builtins.pathExists guard: if setup-test-secrets.sh hasn't been run yet,
  # omit this — the VM will boot but sops decryption will fail at runtime.
  environment.etc."test-age-key.txt" = lib.mkIf (builtins.pathExists ../test/test-age-key.txt) {
    source = ../test/test-age-key.txt;
    mode = "0400";
  };

  # VM resource sizing
  virtualisation.vmVariant.virtualisation = {
    memorySize = 4096;
    diskSize = 20480;
    forwardPorts = [
      { from = "host"; host.port = 8080; guest.port = 80; }
      { from = "host"; host.port = 8443; guest.port = 443; }
      { from = "host"; host.port = 2222; guest.port = 22; }
    ];
  };

  # Use tls internal for all vhosts — Caddy's local CA generates self-signed certs.
  # Do NOT set auto_https off: that prevents Caddy from wiring up the TLS connection
  # policies properly, causing TLS internal error even with explicit tls internal per site.
  # The admin API localhost binding stays from the base caddy.nix globalConfig.
  services.caddy.virtualHosts = builtins.listToAttrs (map (name: {
    inherit name;
    value.extraConfig = lib.mkBefore "tls internal\n";
  }) [
    "mair.io" "matrix.mair.io" "auth.mair.io" "element.mair.io"
    "chat.mair.io" "admin.mair.io" "authelia.mair.io"
    "rtc.mair.io" "call.mair.io" "monitoring.mair.io"
  ]);

  # Allow password auth + root login for easy SSH access in VM
  services.openssh.settings.PasswordAuthentication = lib.mkForce true;
  services.openssh.settings.PermitRootLogin = lib.mkForce "yes";
  users.users.root.password = lib.mkForce "root";  # only for VM testing

  # Disable the disko module activation in VM (no real disk to partition)
  disko.enableConfig = lib.mkForce false;
}
