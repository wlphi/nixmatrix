# Putting nixMatrix behind your own reverse proxy

Use these if you already run nginx, Apache, or another web server that handles
HTTPS for your other sites, and you want Matrix to live behind it rather than
giving the built-in Caddy its own public IP.

## How it works

1. Turn on external-proxy mode in `hosts/matrix-server.nix`:

   ```nix
   nixmatrix.externalProxy.enable = true;
   # nixmatrix.externalProxy.port = 8080;   # default; change if 8080 is taken
   ```

   The built-in Caddy now serves plain HTTP on `127.0.0.1:8080` and stops
   managing certificates. It still does all the Matrix-specific routing (sending
   login to MAS, serving the `.well-known` files, scoping CORS, and so on) — your
   proxy doesn't need to know any of that.

2. Point your proxy's HTTPS sites for each Matrix subdomain at `127.0.0.1:8080`,
   using the matching example file below. Get certificates however you already do
   (certbot, your proxy's ACME, etc.).

3. Deploy. Check login and https://federationtester.matrix.org/#YOUR_DOMAIN.

If the proxy runs on a **different machine** than Matrix, replace `127.0.0.1`
with the Matrix host's address and open the port between them.

## The one thing that matters

Your proxy **must** pass these through, or login silently breaks (the auth
service builds its redirect URLs from them):

- the original `Host` header, unchanged
- `X-Forwarded-Proto: https`
- `X-Forwarded-Host` = the original host

The example files already do this. If you adapt your own, don't drop them.

## Files

| File | For |
|------|-----|
| [`nginx.conf`](nginx.conf) | nginx |
| [`apache.conf`](apache.conf) | Apache httpd 2.4+ |

Both are templates — replace `example.com` with your domain and fill in your
certificate paths. They assume Matrix is reachable at `127.0.0.1:8080`.

## Subdomains

You need an HTTPS server block for each subdomain you use, plus the apex:

- `example.com` (apex — serves the `.well-known` delegation)
- `matrix.example.com`, `auth.example.com`, `element.example.com`
- `chat.example.com`, `admin.example.com` (if you use those clients)
- `rtc.example.com`, `call.example.com` (if Element Call is on)
- `monitoring.example.com` (Grafana), `authelia.example.com` (if SSO is on)

A wildcard cert for `*.example.com` plus the apex is the easy path. The examples
use one `server` / `VirtualHost` block with a wildcard `server_name` /
`ServerAlias` to cover them all.

> Note: calls (Element Call / LiveKit) also need UDP `50100–50200` and TCP `7881`
> reachable from the internet to the Matrix host. That media traffic does **not**
> go through your HTTP proxy — it's separate. See `docs/DEPLOY.md` §9.
