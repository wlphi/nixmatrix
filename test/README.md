# Local VM Testing

Tests the full NixOS stack in a QEMU VM on your laptop.
KVM is available on this machine (i5-8365U) — the VM runs at near-native speed.

## One-time setup (10–15 minutes)

### 1. Install Nix

```bash
sh <(curl -L https://nixos.org/nix/install) --daemon
# Follow the prompts, then restart your shell or:
source /etc/profile.d/nix.sh
```

Enable flakes (required):
```bash
mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
```

### 2. Install QEMU

```bash
sudo apt install qemu-system-x86 ovmf
```

(`ovmf` provides the UEFI firmware the VM needs.)

### 3. Install sops + age (for test secrets generation)

```bash
sudo apt install age
# sops is not in Debian repos yet — install from GitHub release or via Nix:
nix profile install nixpkgs#sops
# or: curl -Lo /tmp/sops.deb https://github.com/getsops/sops/releases/latest/download/sops_*.amd64.deb && sudo dpkg -i /tmp/sops.deb
```

### 4. Generate test secrets

```bash
cd /path/to/nixmatrix
./test/setup-test-secrets.sh
```

This creates:
- `test/test-age-key.txt` — local age key (gitignored, don't share)
- `test/test-secrets.yaml` — sops-encrypted dummy secrets (gitignored)
- `test/test-sops.yaml` — sops config pointing to test key (gitignored)

---

## Build and run the VM

```bash
cd /path/to/nixmatrix

# Build (first time: 10–30 min downloading packages)
nixos-rebuild build-vm --flake .#matrix-server-vm

# Run
./result/bin/run-nixmatrix-vm
```

The VM opens a QEMU window. To run headless:
```bash
./result/bin/run-nixmatrix-vm -nographic
```

### Port forwarding (active while VM runs)

| Host port | VM port | Service |
|-----------|---------|---------|
| 8080 | 80 | Caddy HTTP |
| 8443 | 443 | Caddy HTTPS (self-signed in VM) |
| 2222 | 22 | SSH |

### SSH into VM

```bash
ssh -p 2222 -o StrictHostKeyChecking=no root@localhost
# Password: root
```

---

## Verify services inside VM

```bash
# Check all services
systemctl status matrix-synapse mas postgresql caddy redis-authelia

# Well-known (from inside the VM)
curl -s http://localhost/.well-known/matrix/client | jq

# MAS health
curl -s http://localhost:8081/health

# Synapse health
curl -s http://localhost:8008/_matrix/client/versions | jq .versions[0]

# PostgreSQL
sudo -u postgres psql -c '\l'

# Check logs for a specific service
journalctl -u matrix-synapse -f
journalctl -u mas -f
```

---

## Rebuilding after config changes

While the VM is running, you can push changes without restarting:

```bash
# On host machine:
nixos-rebuild switch --flake .#matrix-server-vm \
  --target-host root@localhost \
  --target-port 2222 \
  --build-host localhost
```

---

## Known VM limitations

- **TLS is disabled** (`auto_https off` in Caddy) — no ACME in VM
- **Secrets are dummy values** — services start but bridges won't connect to real networks
- **OCI containers (LiveKit, FluffyChat) may not start** — Podman needs extra nested virt setup in some VMs
- **example.com domains don't resolve inside VM** — use `localhost:8080` instead, or add `/etc/hosts` entries in the VM
