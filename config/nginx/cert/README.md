# Creating Keys

Per-vhost SSL certificates for the nginx proxy are generated locally with
[mkcert](https://github.com/FiloSottile/mkcert) and are **not** committed
(`*.pem` is gitignored).

1. Install mkcert
2. Create a local CA (if not already created)
```shell
mkcert -install
```
3. Generate SSL certificates for a vhost, e.g. `webubuntu83`
```shell
cd config/nginx/cert/webubuntu83
mkcert -key-file key.pem -cert-file cert.pem \
  "*.test-webubuntu83.orangehrmdev.com" "*.os-webubuntu83.orangehrmdev.com"
```
Use wildcards covering both the `test-` (enterprise) and `os-` (opensource) patterns so
any working-copy subdomain works without regenerating. X.509 wildcards match only one
label, hence the two entries — and `a.b.test-webubuntu83...` is not covered.

4. Reload nginx to pick up the new certificate (no rebuild needed, the dir is bind-mounted)
```shell
docker exec dev_nginx nginx -t && docker exec dev_nginx nginx -s reload
```

## Using this checkout on another machine

The `*.pem` files are gitignored, so a fresh clone has no certificates at all — and the
mkcert CA that signs them is per-machine. On a new machine either:

- **Generate fresh** — install mkcert, run `mkcert -install` (creates *that* machine's CA
  and adds it to its system/browser trust stores), then repeat step 3. Simplest option.
- **Reuse this machine's CA** — copy `rootCA.pem` *and* `rootCA-key.pem` from
  `$(mkcert -CAROOT)` into the same dir on the new machine, then run `mkcert -install`
  there. Certificates already issued by this CA are then trusted on both machines.
  `rootCA-key.pem` can mint a trusted certificate for *any* domain, so treat it as a
  secret: never commit it, and only move it between machines you control.

Firefox keeps its own trust store; `mkcert -install` handles it only if `certutil`
(`brew install nss`) is present.

The `webubuntu83.conf` virtual server references
`/etc/nginx/cert/webubuntu83/{cert,key}.pem` (the `config/nginx/cert` dir is bind-mounted
into the nginx container at `/etc/nginx/cert`).
