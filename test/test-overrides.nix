{ lib, ... }:

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

  # Disable ACME — no real domain in VM, use plain HTTP
  services.caddy.globalConfig = lib.mkForce ''
    auto_https off
  '';

  # Allow password auth for easy SSH access in VM
  services.openssh.settings.PasswordAuthentication = lib.mkForce true;
  users.users.root.password = lib.mkForce "root";  # only for VM testing

  # Disable the disko module activation in VM (no real disk to partition)
  disko.enableConfig = lib.mkForce false;
}
