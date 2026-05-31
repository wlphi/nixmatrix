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

  # Exercise the optional SSO path in the integration test (it's off by default
  # in production). The test asserts authelia-main starts cleanly with NRestarts=0.
  nixmatrix.sso.enable = true;

  # Exercise hookshot too — it needs no external credentials (generic webhooks),
  # so unlike the chat bridges it can actually be boot-tested here.
  nixmatrix.bridges.hookshot.enable = true;

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
  # Subdomains are derived from nixmatrix.domain so this keeps working if you
  # change the domain.
  services.caddy.virtualHosts =
    let
      d = config.nixmatrix.domain;
    in
    builtins.listToAttrs (map (name: {
      inherit name;
      value.extraConfig = lib.mkBefore "tls internal\n";
    }) [
      "${d}" "matrix.${d}" "auth.${d}" "element.${d}"
      "chat.${d}" "admin.${d}" "authelia.${d}"
      "rtc.${d}" "call.${d}" "monitoring.${d}"
    ]);

  # Allow password auth + root login for easy SSH access in VM
  services.openssh.settings.PasswordAuthentication = lib.mkForce true;
  services.openssh.settings.PermitRootLogin = lib.mkForce "yes";
  users.users.root.password = lib.mkForce "root";  # only for VM testing

  # Disable the disko module activation in VM (no real disk to partition)
  disko.enableConfig = lib.mkForce false;

  # With disko off, nothing defines a root filesystem, so `system.build.toplevel`
  # fails its assertion ("fileSystems does not specify your root file system").
  # The QEMU VM we actually run (build.vm) supplies its own disk, so this is only
  # a problem for bare toplevel evaluation — which `nix flake check` does for
  # every nixosConfiguration. Declare a nominal root FS so the VM config also
  # evaluates as a toplevel; the vmVariant overrides storage at run time anyway.
  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
}
