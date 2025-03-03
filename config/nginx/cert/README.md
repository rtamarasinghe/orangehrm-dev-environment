#Creating Keys

1. Install mkcert
2. Create a local CA (if not already created)
```shell
mkcert -install
```
3. Generate SSL Certificates
```shell
mkcert -key-file key.pem -cert-file cert.pem trunk.test-web82rh.orangehrmdev.com
```

