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
mkcert -key-file key.pem -cert-file cert.pem trunk.test-webubuntu83.orangehrmdev.com
```

The `webubuntu83.conf` virtual server references
`/etc/nginx/cert/webubuntu83/{cert,key}.pem` (the `config/nginx/cert` dir is bind-mounted
into the nginx container at `/etc/nginx/cert`).
