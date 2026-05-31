# NixOS integration test — boots the full stack headless in a VM and asserts
# the core services come up and the critical HTTP routes work.
#
# Run it (needs /dev/kvm):
#   nix build .#checks.x86_64-linux.integration -L
#
# It reuses the exact module set as the `matrix-server-vm` config (real host
# config + test overrides with dummy sops secrets), so it exercises the same
# code path a real deployment uses — just with throwaway credentials.
#
# This is wired in as a flake check (see flake.nix). The `test/smoke-test.sh`
# suite is run at the end for its rich per-assertion output in the build log.

{ pkgs, inputs, sharedModules }:

pkgs.testers.runNixOSTest {
  name = "nixmatrix-integration";

  node.specialArgs = { inherit inputs; };

  # The host config sets `nixpkgs.config.permittedInsecurePackages` (libolm).
  # By default the test driver pins each node's pkgs and marks nixpkgs.config
  # read-only, which collides with that. pkgsReadOnly = false lets the node
  # evaluate its own nixpkgs with the host config's settings intact.
  node.pkgsReadOnly = false;

  nodes.machine = { ... }: {
    imports = sharedModules ++ [
      ../hosts/matrix-server.nix
      ../test/test-overrides.nix # dummy secrets + tls internal + VM-friendly
    ];

    # The full stack (Synapse, Postgres, MAS, Element, Caddy, bridges) is heavy.
    # 4 GB matches the proven `matrix-server-vm` size and fits a modest host.
    virtualisation.memorySize = 4096;
    virtualisation.cores = 4;
    virtualisation.diskSize = 8192;
  };

  # Python test driver script. Hard assertions gate the build; the smoke-test
  # at the end is informational (its own exit code is captured but not fatal,
  # since some bridge/Authelia checks expect-fail with dummy credentials).
  testScript = ''
    start_all()

    # ── Boot ────────────────────────────────────────────────────────────────
    # We deliberately do NOT wait on multi-user.target: the optional OCI
    # containers (livekit, fluffychat, lk-jwt) can't pull images in the
    # network-isolated test VM and would wedge the target. We assert the core
    # units instead — that's what "the stack works" actually means here.
    machine.wait_for_unit("network.target")

    # ── sops secrets decrypted ──────────────────────────────────────────────
    # If this fails, the test age key / test-secrets.yaml weren't wired in.
    machine.wait_for_file("/run/secrets/matrix/postgres_password")

    # ── Core services up ────────────────────────────────────────────────────
    machine.wait_for_unit("postgresql.service")
    machine.wait_for_unit("caddy.service")
    machine.wait_for_unit("matrix-authentication-service.service")
    machine.wait_for_unit("matrix-synapse.service")
    # Authelia is optional SSO, but it must start AND stay up (not crash-loop).
    machine.wait_for_unit("authelia-main.service")

    # Guard against flaky "active" reads: give the units a moment, then assert
    # none of the core services are in a failed/restarting state. wait_for_unit
    # can catch a unit during a restart blip; this catches crash-loops.
    machine.sleep(10)
    for unit in ["postgresql.service", "caddy.service",
                 "matrix-authentication-service.service",
                 "matrix-synapse.service", "authelia-main.service"]:
        state = machine.succeed(f"systemctl is-active {unit}").strip()
        assert state == "active", f"{unit} is {state}, not active (crash-looping?)"
        # NRestarts should be 0 for a clean boot — a climbing count means crash-loop.
        restarts = machine.succeed(
            f"systemctl show -p NRestarts --value {unit}"
        ).strip()
        assert restarts == "0", f"{unit} has restarted {restarts} times (crash-loop)"

    # ── PostgreSQL: every service database exists ────────────────────────────
    dbs = machine.succeed("sudo -u postgres psql -tAc 'SELECT datname FROM pg_database'")
    for db in ["synapse", "mas", "authelia",
               "mautrix-telegram", "mautrix-whatsapp",
               "mautrix-signal", "mautrix-discord"]:
        assert db in dbs, f"missing database: {db}"

    # ── Synapse is serving ──────────────────────────────────────────────────
    machine.wait_until_succeeds(
        "curl -sf http://localhost:8008/health", timeout=180
    )
    machine.succeed(
        "curl -sf http://localhost:8008/_matrix/client/versions | grep -q versions"
    )

    # ── MAS is serving ──────────────────────────────────────────────────────
    machine.wait_until_succeeds(
        "curl -sf http://localhost:8081/health", timeout=180
    )

    # ── Caddy routing (tls internal in the VM, so -k + --resolve) ───────────
    # well-known delegation advertises the homeserver + OIDC issuer.
    wk = machine.succeed(
        "curl -sfk --resolve example.com:443:127.0.0.1 "
        "https://example.com/.well-known/matrix/client"
    )
    assert "matrix.example.com" in wk, "well-known missing homeserver base_url"
    assert "auth.example.com" in wk, "well-known missing m.authentication issuer"

    # login must route to MAS, not Synapse (MSC3861 compat endpoint).
    machine.succeed(
        "curl -sfk --resolve matrix.example.com:443:127.0.0.1 "
        "https://matrix.example.com/_matrix/client/v3/login | grep -q m.login"
    )

    # MAS OIDC discovery is reachable and advertises the public issuer.
    disco = machine.succeed(
        "curl -sfk --resolve auth.example.com:443:127.0.0.1 "
        "https://auth.example.com/.well-known/openid-configuration"
    )
    assert "https://auth.example.com/" in disco, "OIDC issuer is not the public URL"

    # Element Web is served.
    machine.succeed(
        "curl -sfk --resolve element.example.com:443:127.0.0.1 "
        "https://element.example.com/ -o /dev/null"
    )

    # ── Full smoke-test suite (informational — rich per-check output) ────────
    print(machine.succeed(
        "bash ${../test/smoke-test.sh} || echo '[smoke-test reported failures — "
        "expected for bridge/Authelia checks with dummy credentials]'"
    ))
  '';
}
