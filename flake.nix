{
  description = "NixOS Matrix Stack — mair.io";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Community MAS module — pin to a specific rev for reproducibility.
    # Find the latest commit at: https://github.com/D4ndellion/nixos-matrix-modules/commits
    # Replace <MAS_MODULE_REV> with the full 40-char commit hash before deploying.
    nixos-matrix-modules = {
      # Pinned 2025-12-08 — "Additional fixes for 25.11"
      # Update: nix flake lock --update-input nixos-matrix-modules
      url = "github:D4ndellion/nixos-matrix-modules?rev=82959f612ffd523a49c92f84358a9980a851747b";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # VPS bootstrapping — installs NixOS on any Linux host via SSH
    nixos-anywhere = {
      url = "github:numtide/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative disk partitioning (required by nixos-anywhere)
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, sops-nix, nixos-matrix-modules, disko, ... }@inputs:
    let
      system = "x86_64-linux";

      sharedModules = [
        sops-nix.nixosModules.sops
        nixos-matrix-modules.nixosModules.default
        disko.nixosModules.disko
        ./modules/default.nix
      ];
    in
    {
      nixosConfigurations = {

        # Production target — deploy with:
        #   nixos-rebuild switch --flake .#matrix-server --target-host root@<VPS_IP>
        # First deploy from scratch — bootstrap with nixos-anywhere:
        #   nix run github:numtide/nixos-anywhere -- --flake .#matrix-server root@<VPS_IP>
        matrix-server = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = sharedModules ++ [
            ./hosts/matrix-server.nix
            ./modules/disk.nix
          ];
        };

        # Local VM for testing — build and run with:
        #   cd nixmatrix && ./test/setup-test-secrets.sh   # one-time setup
        #   nixos-rebuild build-vm --flake .#matrix-server-vm
        #   ./result/bin/run-nixmatrix-vm
        #
        # Host ports forwarded: localhost:8080 → VM:80, localhost:8443 → VM:443
        # SSH into VM: ssh -p 2222 root@localhost  (password: root)
        matrix-server-vm = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = sharedModules ++ [
            ./hosts/matrix-server.nix
            ./test/test-overrides.nix  # dummy secrets + VM-friendly settings
          ];
        };
      };
    };
}
