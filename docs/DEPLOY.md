# Production Deployment Guide

This walks you through deploying nixMatrix to a real server, from a blank VPS to a
working federated Matrix homeserver.

> ⚠️ **The deploy reinstalls the target machine with NixOS, wiping its disk.** Use a
> fresh server, or one whose contents you are happy to destroy.

---

## Overview

```
  bootstrap.sh ──▶ set domain/keys/secrets ──▶ point DNS ──▶ nixos-anywhere ──▶ verify
```

1. [Prerequisites](#1-prerequisites)
2. [DNS](#2-dns)
3. [Bootstrap](#3-bootstrap-keys-secrets-config)
4. [Review the config](#4-review-the-config)
5. [Deploy](#5-deploy)
6. [Post-install](#6-post-install)
7. [Day-2: updates, secrets, backups](#7-day-2-operations)
8. [Troubleshooting](#8-troubleshooting)
9. [Known limitations & caveats](#9-known-limitations--caveats)
10. [Running behind an existing reverse proxy](#10-running-behind-an-existing-reverse-proxy)

---

## 1. Prerequisites

**On the server:**
- A Linux host you can reach as `root@<SERVER_IP>` over SSH (it will be reinstalled).
- 2+ vCPU, 4+ GB RAM, 40+ GB disk recommended.
- A static public IPv4 (and ideally IPv6).

**On your workstation:**
- [Nix with flakes](https://nixos.org/download) enabled.
- `age`, `sops`, `openssl`. If missing:
  `nix shell nixpkgs#age nixpkgs#sops nixpkgs#openssl`
- An SSH keypair (`ssh-keygen -t ed25519` if you don't have one).

---

## 2. DNS

Point these records at your server's IP. Replace `example.com` with your domain.

| Record | Type | Purpose |
|--------|------|---------|
| `example.com` | A / AAAA | Root — serves `.well-known` delegation |
| `matrix.example.com` | A / AAAA | Synapse homeserver + federation |
| `auth.example.com` | A / AAAA | Matrix Authentication Service (login) |
| `element.example.com` | A / AAAA | Element Web client |
| `chat.example.com` | A / AAAA | FluffyChat client |
| `admin.example.com` | A / AAAA | Admin panel |
| `rtc.example.com` | A / AAAA | LiveKit / Element Call signalling |
| `call.example.com` | A / AAAA | Element Call frontend |
| `monitoring.example.com` | A / AAAA | Grafana |
| `authelia.example.com` | A / AAAA | Authelia SSO (only if you enable it) |

The simplest setup is a wildcard `*.example.com` plus the apex `example.com`.

Your Matrix IDs will be `@you:example.com` (the apex), even though Synapse itself
runs at `matrix.example.com` — the apex's `.well-known/matrix/*` files delegate to
it. Use the apex as your `nixmatrix.domain`, not the `matrix.` subdomain.

> **Already host a website on `example.com`?** Pointing the apex's DNS at this
> server would replace that site. Instead, leave the apex where it is and serve
> just these two paths from your existing site:
> - `https://example.com/.well-known/matrix/client`
>   → `{"m.homeserver":{"base_url":"https://matrix.example.com"},"m.authentication":{"issuer":"https://auth.example.com/"}}`
> - `https://example.com/.well-known/matrix/server`
>   → `{"m.server":"matrix.example.com:443"}`
>
> Both must be served with `Content-Type: application/json` and
> `Access-Control-Allow-Origin: *`. You then don't need an A record for the apex
> pointing here — only the subdomains. (The apex vhost in `modules/caddy.nix`
> can be removed in that case.)

Caddy obtains Let's Encrypt certificates automatically on first boot, so DNS must
resolve **before** you deploy. Ports 80 and 443 must be reachable for the ACME
HTTP challenge.

---

## 3. Bootstrap (keys, secrets, config)

The guided script handles encryption keys, secrets, and the config values for you:

```bash
./scripts/bootstrap.sh
```

It will:
- ask for your domain, ACME email, SSH public key, and target disk, and write them
  into [hosts/matrix-server.nix](../hosts/matrix-server.nix) and
  [modules/disk.nix](../modules/disk.nix);
- create an **admin age key** (`~/.config/sops/age/keys.txt`) so you can edit secrets;
- create a **host age key**, staged at `.bootstrap/extra-files/etc/age/key.txt`, which
  nixos-anywhere copies to the server so it can decrypt secrets at boot;
- write `.sops.yaml` with both recipients;
- generate every service secret and write the encrypted `secrets/secrets.yaml`.

> **Telegram bridge:** the script prompts for `telegram_api_id` / `telegram_api_hash`
> from <https://my.telegram.org>. You can leave them blank and fill them in later
> with `sops secrets/secrets.yaml` — only the Telegram bridge is affected.

<details>
<summary>Manual alternative (no bootstrap script)</summary>

1. Set `nixmatrix.domain`, `users.users.root.openssh.authorizedKeys.keys`, and
   (optionally) `nixmatrix.acmeEmail` in `hosts/matrix-server.nix`; set the disk in
   `modules/disk.nix`.
2. Generate an admin key: `age-keygen -o ~/.config/sops/age/keys.txt`
3. Generate a host key: `age-keygen -o .bootstrap/extra-files/etc/age/key.txt`
4. Put both public keys (`age-keygen -y <file>`) into `.sops.yaml` as `host`/`admin`.
5. Fill in `secrets/secrets.yaml` from the template, then encrypt:
   `sops -e -i secrets/secrets.yaml`
   (generation commands are documented inline in that file).
</details>

---

## 4. Review the config

Run the static checks — they catch known configuration pitfalls without building:

```bash
./test/check-nix.sh
```

Confirm your values landed:

```bash
grep nixmatrix hosts/matrix-server.nix
grep device   modules/disk.nix
sops -d secrets/secrets.yaml | head   # should print decrypted YAML
```

Optionally, prove the whole stack boots locally first — either the hand-driven VM
in [test/README.md](../test/README.md), or the automated integration test (boots
the stack headless and asserts services + routing; needs `/dev/kvm`):

```bash
nix build .#checks.x86_64-linux.integration -L
```

---

## 5. Deploy

```bash
nix run github:numtide/nixos-anywhere -- \
  --flake .#matrix-server \
  --extra-files .bootstrap/extra-files \
  root@<SERVER_IP>
```

`--extra-files` seeds the host age key at `/etc/age/key.txt` so sops-nix can decrypt
secrets on the very first boot. nixos-anywhere partitions the disk (via disko),
installs NixOS, and reboots into the running stack.

First boot downloads packages and requests TLS certificates — give it a few minutes.

---

## 6. Post-install

**Check services are up:**

```bash
ssh root@<SERVER_IP> 'systemctl status matrix-synapse mas postgresql caddy'
```

**Run the smoke test against the live host** (from the repo, it SSHes in):

```bash
./test/smoke-test.sh root@<SERVER_IP>
```

**Verify federation:** open
`https://federationtester.matrix.org/#example.com` — it should report success.

**Create your first user.** By default registration is admin-only, so create
accounts on the server with the MAS CLI (`register-user` is interactive and
prompts for username, password, email, and admin flag):

```bash
ssh root@<SERVER_IP>
mas-cli manage register-user
```

To reset a password later: `mas-cli manage set-password <username>`.

> **Want public self-signup instead?** Set `nixmatrix.openRegistration = true;`
> in `hosts/matrix-server.nix` and redeploy — users then get a "Create account"
> flow at `auth.example.com`. Only do this on a server you intend to be public.

**Log in:** browse to `https://element.example.com` and sign in with that account.

---

## 7. Day-2 operations

**Push config changes** (after editing any `.nix` file):

```bash
nixos-rebuild switch --flake .#matrix-server --target-host root@<SERVER_IP>
```

**Edit secrets** (re-encrypts automatically on save):

```bash
sops secrets/secrets.yaml
nixos-rebuild switch --flake .#matrix-server --target-host root@<SERVER_IP>
```

**Add another admin who can edit secrets:** add their age public key to `.sops.yaml`,
then `sops updatekeys secrets/secrets.yaml`.

**Update package versions:**

```bash
nix flake update          # or: nix flake lock --update-input nixpkgs
nixos-rebuild switch --flake .#matrix-server --target-host root@<SERVER_IP>
```

**Backups:** PostgreSQL is dumped daily (zstd) to `/var/backup/postgresql` on the
server. This is **on-host only** — copy it off-server regularly, e.g.:

```bash
rsync -a root@<SERVER_IP>:/var/backup/postgresql/ ./backups/
```

Test a restore before you rely on it. Also back up `secrets/secrets.yaml` and your
admin age key — losing the key means losing access to the secrets.

---

## 8. Troubleshooting

| Symptom | Where to look |
|---------|---------------|
| Service won't start | `journalctl -u <service> -e` on the host |
| TLS cert errors | `journalctl -u caddy -e`; confirm DNS resolves and 80/443 are open |
| Secrets missing at boot | confirm `/etc/age/key.txt` exists on host; check `journalctl -u sops-nix` |
| Login fails | `journalctl -u mas -e`; check `auth.example.com/.well-known/openid-configuration` |
| Federation fails | federationtester.matrix.org; check `matrix.example.com/.well-known/matrix/server` |
| Bridge won't connect | `journalctl -u mautrix-<network> -e`; verify its secrets/credentials |

Locked out over SSH? Password auth is disabled by design — you must have set
`users.users.root.openssh.authorizedKeys.keys` before deploying. If you missed it,
use your provider's console/recovery to add a key, or re-run the deploy.

## 9. Known limitations & caveats

Read these before relying on the deployment — they cover things the automated VM
test does not (and cannot) exercise:

- **Voice/video calls (Element Call / LiveKit) need a reachable media path.**
  The UDP range `50100–50200` and TCP `7881` must be open end-to-end. On a public
  VPS with those open, direct connectivity usually works. For users behind strict
  NAT or CGNAT (often the case on home connections), turn on the built-in TURN
  fallback:

  ```nix
  # hosts/matrix-server.nix
  nixmatrix.turn.enable = true;          # opens UDP 3478 + a relay range
  # nixmatrix.turn.udpPort   = 3478;     # set to 443 (external-proxy mode only) for the
  #                                      # best chance through restrictive firewalls
  # nixmatrix.turn.relayRange = "30000-31000";
  ```

  This uses LiveKit's own TURN server — no extra service to run. The TURN UDP
  port and relay range are opened in the firewall automatically. (Setting
  `udpPort = 443` only works when Caddy isn't using 443, i.e. external-proxy mode.)
- **Federation.** Caddy serves Matrix on `:443` and `.well-known` delegation
  points peers there; port `8448` is also opened for servers that connect
  directly. After deploying, confirm with
  `https://federationtester.matrix.org/#example.com`. If it fails, the usual
  cause is DNS or the `.well-known/matrix/server` response.
- **SSO (Authelia) is off by default** (`nixmatrix.sso.enable`). When you turn it
  on, it ships a single example account `admin` / `changeme` in
  `/var/lib/authelia-main/users.yaml`. **Change that password immediately**
  (`authelia crypto hash generate argon2 --password '…'`) and add real users.
- **Bridges are opt-in** (`nixmatrix.bridges.<net>.enable`) and bridge E2E
  encryption is intentionally disabled (MSC4190 is incompatible with MAS today).
- **First real deploy is your acceptance test.** The VM test uses self-signed
  TLS and dummy secrets; it does not prove real Let's Encrypt issuance, real
  federation, or real client login. Treat your first VPS deploy as a smoke test:
  run `./test/smoke-test.sh root@<SERVER_IP>`, create a user, log in via Element,
  and check the federation tester before inviting anyone else.

## 10. Running behind an existing reverse proxy

Already running nginx, Apache, or another web server that handles HTTPS for your
other sites? You have two choices:

**Simplest — give Matrix its own machine.** Let its built-in Caddy handle HTTPS,
point the Matrix subdomains' DNS at it, and you're done. This is the default;
skip the rest of this section.

**Or put it behind your existing proxy.** Turn on external-proxy mode:

```nix
# hosts/matrix-server.nix
nixmatrix.externalProxy.enable = true;
```

Now the built-in Caddy serves plain HTTP on `127.0.0.1:8080` and leaves
certificates to your proxy — while still doing all the Matrix routing (login,
`.well-known`, CORS) for you. Point your proxy's HTTPS sites for the Matrix
subdomains at `127.0.0.1:8080`.

**Drop-in configs are provided** — copy the one for your proxy, replace
`example.com`, set your certificate paths, and reload:

- nginx → [`examples/reverse-proxy/nginx.conf`](../examples/reverse-proxy/nginx.conf)
- Apache → [`examples/reverse-proxy/apache.conf`](../examples/reverse-proxy/apache.conf)
- details → [`examples/reverse-proxy/README.md`](../examples/reverse-proxy/README.md)

One thing the configs handle that's easy to miss if you write your own: the
original `Host` header and `X-Forwarded-Proto: https` must be passed through, or
login fails. Calls also need UDP `50100–50200` / TCP `7881` reachable to the
Matrix host directly — that media traffic doesn't go through your proxy.

For how each piece is wired internally, see [NIXOS_PLAN.md](../NIXOS_PLAN.md).
