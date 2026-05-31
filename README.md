# nixMatrix

A complete, self-hosted [Matrix](https://matrix.org) homeserver stack as a single
NixOS flake. Deploy a federated chat server — with modern OIDC login, web clients,
messaging bridges, video calls, and monitoring — to a fresh VPS in one command.

Everything is declarative and reproducible: the entire server is described in this
repo, secrets are encrypted with [sops-nix](https://github.com/Mic92/sops-nix), and
deployment is a single `nixos-anywhere` run.

> **Status:** boot-verified in CI, not yet battle-tested on real hardware — see
> [Project status](#project-status). If you run it, open an issue with how it went.

---

## What you get

| Area | Components |
|------|-----------|
| **Homeserver** | [Synapse](https://github.com/element-hq/synapse) with federation |
| **Authentication** | [Matrix Authentication Service (MAS)](https://github.com/element-hq/matrix-authentication-service) — modern OIDC/OAuth2 login (MSC3861) |
| **Web clients** | [Element Web](https://github.com/element-hq/element-web), [FluffyChat](https://fluffychat.im), and an admin panel |
| **Bridges** | mautrix [Telegram](https://github.com/mautrix/telegram), [WhatsApp](https://github.com/mautrix/whatsapp), [Signal](https://github.com/mautrix/signal), [Discord](https://github.com/mautrix/discord) |
| **Voice / video** | [Element Call](https://github.com/element-hq/element-call) backed by [LiveKit](https://livekit.io) |
| **SSO (optional)** | [Authelia](https://www.authelia.com) as an upstream identity provider |
| **TLS & routing** | [Caddy](https://caddyserver.com) with automatic Let's Encrypt certificates |
| **Data** | PostgreSQL 16 (per-service users, daily backups) + Redis |
| **Observability** | Prometheus, node/postgres exporters, and Grafana dashboards |

All secrets stay encrypted at rest and are only ever decrypted to `tmpfs` at runtime —
never written to the Nix store.

## Architecture

A single host runs everything behind Caddy, which terminates TLS and routes each
subdomain to the right service:

```
                          ┌──────────────────────── your-domain.com ────────────────────────┐
   Internet ──443──▶ Caddy │  matrix.*  → Synapse        auth.*    → MAS                       │
                          │  element.* → Element Web    chat.*    → FluffyChat               │
                          │  admin.*   → Admin panel    rtc.*     → LiveKit / Element Call   │
                          │  call.*    → Element Call   monitoring.* → Grafana               │
                          └──────────────────────────────────────────────────────────────────┘
                                   │              │               │
                              PostgreSQL        Redis        mautrix bridges
```

Every subdomain is derived automatically from the one `nixmatrix.domain` value you set.

## Prerequisites

- A server you can SSH into as root, running any Linux (it gets reinstalled with
  NixOS) — 2+ vCPU and 4+ GB RAM recommended.
- A domain you control, with DNS pointed at the server (see [DNS](#1-dns)).
- Locally: [Nix](https://nixos.org/download) with flakes enabled, plus `age` and
  `sops` (if missing, the bootstrap script prints the `nix shell` command to get them).

## Quick start (production)

```bash
git clone <this-repo> nixmatrix && cd nixmatrix

# 1. Guided setup: generates encryption keys, fills in secrets, sets your domain.
./scripts/bootstrap.sh

# 2. Review the generated config, then deploy to your server.
nix run github:numtide/nixos-anywhere -- --flake .#matrix-server root@<SERVER_IP>
```

The bootstrap script walks you through everything interactively. For the full
manual procedure, DNS records, and post-install steps, see
**[docs/DEPLOY.md](docs/DEPLOY.md)**.

After the first deploy, push config changes with:

```bash
nixos-rebuild switch --flake .#matrix-server --target-host root@<SERVER_IP>
```

## Try it locally first (no server needed)

You can build and boot the whole stack in a QEMU VM on your laptop to see it work
before touching a real server:

```bash
./test/setup-test-secrets.sh                       # one-time: dummy secrets
nixos-rebuild build-vm --flake .#matrix-server-vm
./result/bin/run-nixmatrix-vm
```

Then browse to `https://localhost:8443` (self-signed cert). See
[test/README.md](test/README.md) for details and known VM limitations.

## Configuration

The only value you **must** change is your domain, in
[hosts/matrix-server.nix](hosts/matrix-server.nix):

```nix
nixmatrix.domain = "your-domain.com";   # everything else is derived from this
```

You'll also set, in the same file:

- `users.users.root.openssh.authorizedKeys.keys` — your SSH public key (password
  login is disabled, so this is required or you'll be locked out).
- `disko.devices.disk.main.device` in [modules/disk.nix](modules/disk.nix) — the
  target disk (`/dev/sda`, `/dev/vda`, `/dev/nvme0n1`; check with `lsblk`).

**Messaging bridges are opt-in.** Enable only the networks you use:

```nix
nixmatrix.bridges.whatsapp.enable = true;
nixmatrix.bridges.signal.enable   = true;
# telegram also needs API credentials in secrets.yaml (see below)
```

A disabled bridge contributes nothing and can never prevent the homeserver from
starting; each enabled bridge registers itself with Synapse automatically.

Secrets live in `secrets/secrets.yaml` (encrypted with sops). The bootstrap script
generates them for you; the template is documented in
[secrets/secrets.yaml](secrets/secrets.yaml).

## Documentation

- **[docs/DEPLOY.md](docs/DEPLOY.md)** — full production deployment guide.
- **[test/README.md](test/README.md)** — local VM testing.
- **[NIXOS_PLAN.md](NIXOS_PLAN.md)** — design rationale, per-service deep dives, and a
  table of hard-won fixes (great if you want to understand or modify internals).

## Testing

```bash
./test/check-nix.sh    # static checks for known config pitfalls (no build)
nix flake check        # evaluates every config + runs the VM integration test (needs /dev/kvm)
./test/smoke-test.sh   # assertions against an already-running VM or host
```

The integration test ([test/integration.nix](test/integration.nix)) is what backs
the "boot-verified" claim below. CI runs the static checks on every push and the
full build + integration test on PRs and `main`
([.github/workflows/ci.yml](.github/workflows/ci.yml)).

## Project status

**Boot-verified:** the integration test boots Synapse, MAS, PostgreSQL, Caddy, and
Authelia from the real config and asserts every core service reaches `active` with
zero restarts, all databases exist, and the critical routes work (well-known
delegation, login → MAS, OIDC discovery, Element). It runs in CI.

What's still maturing:

- It has not yet been proven across many real-world production deployments (the VM
  test uses self-signed TLS and dummy secrets; real Let's Encrypt + federation are
  not exercised in CI).
- Messaging bridges are opt-in and not exercised end-to-end in CI (Telegram needs
  real API credentials); enable and verify them per-deployment.
- Bridge end-to-end encryption is intentionally disabled (MSC4190 is currently
  incompatible with MAS).
- Slack and IRC/Hookshot bridges are planned but not yet implemented.

Contributions, bug reports, and "it worked / it didn't" notes are very welcome.

## License

[MIT](LICENSE).
