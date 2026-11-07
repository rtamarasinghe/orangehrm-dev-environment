# SAML Test Container Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An opt-in SimpleSAMLphp container at `https://saml.test` that acts as both IdP and SP for any OrangeHRM tree, wired and unwired per tree by `ohrm saml link|unlink <tree>`.

**Architecture:** One locally built image (official `php:8.3-apache` + SimpleSAMLphp 2.4.1) runs as `dev_saml` on `10.5.2.7`. nginx terminates TLS for `saml.test` with an mkcert certificate. All per-machine state (keys, per-tree registrations, per-tree restore state) lives in gitignored folders under `custom-compose/config/saml/`. The container reads them at request time. A new `utils/ohrm-saml.sh` owns every host-side change: compose, certificates, nginx, `/etc/hosts`, the tree's database rows and files.

**Tech Stack:** Bash (host scripts, house style of `utils/ohrm-build.sh`), Docker Compose, nginx 1.14, PHP 8.3 + SimpleSAMLphp 2.4.1 (in the container only), MariaDB 10.11 (`dev_mariadb_101115`), Python 3.9 stdlib (host-side self-test only).

**Spec:** `docs/superpowers/specs/2026-11-07-saml-test-container-design.md`. Read it first. Section numbers below (§6.6 and so on) refer to it.

## Global Constraints

- Repo `~/web`, branch `ruchira-dev`. Stage by explicit path only. Never `git add -A`.
- Hostname `saml.test`. Compose service `saml`, container `dev_saml`, IP `10.5.2.7` on `ohrmdevnet`. No host port published. `restart: "no"`.
- Compose file `custom-compose/saml.yml`. Everything else for the service lives under `custom-compose/config/saml/`.
- SimpleSAMLphp `2.4.1`, from the release tarball `simplesamlphp-2.4.1-slim.tar.gz`, pinned by SHA-256.
- Container IdP entity ID `https://saml.test/idp`. Container SP entity ID `https://saml.test/sp`, auth source id `container-sp`. SimpleSAMLphp base URL `https://saml.test/simplesaml/`.
- Tree host `<tree>.test-webubuntu83.orangehrmdev.com`. Tree slug matches `^[a-z0-9]+$`.
- Tree IdP entity ID `https://<host>/saml/saml2/idp/metadata.php`. Tree IdP SSO URL `https://<host>/saml/saml2/idp/SSOService.php`.
- Tree SP entity ID `<host>/saml/module.php/saml/sp/metadata.php/orangehrm-sp` (no scheme). Tree SP ACS URL `https://<host>/saml/module.php/saml/sp/saml2-acs.php/orangehrm-sp`.
- Tree SP RelayState `https://<host>/openidauth/openIdCredentials?openIdProvider=saml_<IdP row id>`.
- Both provider rows are named exactly `SAML test container`. Types `IDP` and `SP`. `status` 1. The IdP row's `username_key` is `username`.
- SP-row attribute map, `ohrm_saml_provider_attribute (provider_id, token_id, claim_name)`: `(id,2,'username')`, `(id,3,'firstName')`, `(id,5,'email')`, `(id,6,'employeeId')`.
- Tree IdP files: `symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert/saml.prod.orangehrm-idp.pem` and `.crt`. Exclude lines are those two paths with a leading `/`.
- Database: container `dev_mariadb_101115`, user `root`, password from `OHRM_DB_PASS` (default `1234`), passed as `MYSQL_PWD`, never on the command line. Every string value written by a script goes through `FROM_BASE64('…')`.
- No generated key, certificate, salt, registration, state or log is committed. A tree's `git status` must not change because of `link`.
- The host has no PHP. Any SAML parsing runs in a container, except the stdlib-only self-test script, which runs as `python3 -I`.
- Never change a tree's tracked files. Never patch a tree to make a check pass (§6.3).
- Comments: current contract and invariants only (`~/.claude/rules/code-comments.md`).
- `docker-compose up -d` with no `-f` must never start `dev_saml`. nginx must start when `saml.test`'s certificate doesn't exist and when `dev_saml` is down.

## Review Focus

1. **A tree whose `domain.name` is not `localhost`.** rook still carries the SEC-134 throwaway's hostname. `unlink` must restore the recorded value byte for byte, not `localhost`. Test: Task 6, `unlink restores a non-localhost domain.name`.
2. **`link` while `dev_web_83_ubuntu` is down.** The database and file steps finish. The cache clear is skipped, and the output says how to run it. Test: Task 5, `link skips cache clear when web container is down`.
3. **Odd usernames typed at the test IdP**, such as spaces, quotes or HTML. The value is asserted verbatim after trimming, and no page renders it as HTML. Test: Task 3, self-test case `odd username asserted verbatim`.
4. **`unlink` run twice, or on a tree that was never linked.** The second run says "not linked" and changes nothing. Test: Task 6, `unlink without state changes nothing`.
5. **Two trees linked, one unlinked.** The other tree's state, registration, rows and exclude lines are untouched. Test: Task 6, `unlink king leaves queen alone`. Also live in Task 7.

---

## File Structure

| Path | Responsibility |
|---|---|
| `custom-compose/saml.yml` | The opt-in `saml` service. |
| `custom-compose/config/saml/Dockerfile` | `php:8.3-apache` + SimpleSAMLphp 2.4.1 tarball. |
| `custom-compose/config/saml/apache-site.conf` | Docroot `/var/www/site`, `Alias /simplesaml`, `SetEnv`s, ACS capture hook. |
| `custom-compose/config/saml/.gitignore` | `keys/`, `trees/`, `state/`, `generated/`, `data/`. |
| `custom-compose/config/saml/nginx/saml.conf` | nginx server block. `up` copies it into `config/nginx/virtual-servers/`. |
| `custom-compose/config/saml/simplesamlphp/config/config.php` | Loads `config.php.dist` from the image and overrides a fixed list of keys. |
| `custom-compose/config/saml/simplesamlphp/config/authsources.php` | `testidp-any` and `container-sp`. |
| `custom-compose/config/saml/simplesamlphp/metadata/saml20-idp-hosted.php` | The container IdP. |
| `custom-compose/config/saml/simplesamlphp/metadata/saml20-sp-remote.php` | Tree SPs from `trees/*.json`, plus the container's own SP. |
| `custom-compose/config/saml/simplesamlphp/metadata/saml20-idp-remote.php` | Tree IdPs from `trees/*.json`, plus the container's own IdP. |
| `custom-compose/config/saml/simplesamlphp/modules/testidp/src/Auth/Source/AnyUser.php` | Auth source that hands off to `/login.php`. |
| `custom-compose/config/saml/site/lib/trees.php` | Reads `/var/saml-trees/*.json`. Shared by metadata files and pages. |
| `custom-compose/config/saml/site/lib/capture.php` | Prepended on the SP ACS path. Logs the raw response's structure to `/var/saml-data/acs.log`. |
| `custom-compose/config/saml/site/index.php` | Apps page. |
| `custom-compose/config/saml/site/login.php` | Any-username sign-in page. |
| `custom-compose/config/saml/site/sp/index.php` | SP page: per-IdP login buttons, clear session. |
| `custom-compose/config/saml/site/sp/result.php` | Result page. |
| `utils/ohrm-saml.sh` | `up`, `down`, `status`, `link`, `unlink`. |
| `utils/ohrm-shell.sh` | Hands `saml` to `ohrm-saml.sh`. |
| `utils/tests/ohrm-saml-test.sh` | Dry-run tests for `ohrm-saml.sh`. |
| `utils/tests/saml-selftest.py` | Live round trips: container SP ↔ container IdP. |
| `.gitignore` | Adds `config/nginx/virtual-servers/saml.conf`. |
| `README.md` | Container table row and a "SAML test container" section. |

Folders created at run time under `custom-compose/config/saml/`, all gitignored:

- `keys/`: `container.key`, `container.crt`, `secretsalt`.
- `generated/`: `idp-metadata.xml`, `sp-metadata.xml`.
- `trees/<tree>.json`: the tree's registration for the container.
- `state/<tree>/`: restore state for `unlink`.
- `data/acs.log`: one JSON line per ACS hit.

Container mounts, all read-only except `data`:

| Host (under `custom-compose/config/saml/`) | Container |
|---|---|
| `simplesamlphp/config` | `/etc/simplesamlphp/config` |
| `simplesamlphp/metadata` | `/etc/simplesamlphp/metadata` |
| `simplesamlphp/modules/testidp` | `/var/simplesamlphp/modules/testidp` |
| `keys` | `/etc/simplesamlphp/cert` |
| `site` | `/var/www/site` |
| `trees` | `/var/saml-trees` |
| `data` | `/var/saml-data` (read-write) |

### Per-tree file formats (used by Tasks 3 to 7)

`trees/<tree>.json`, written with `jq -n --arg`:

```json
{"tree": "king", "host": "king.test-webubuntu83.orangehrmdev.com",
 "idpEntityId": "https://king…/saml/saml2/idp/metadata.php",
 "idpSsoUrl": "https://king…/saml/saml2/idp/SSOService.php",
 "idpCert": "<tree IdP certificate as one-line base64 DER>",
 "spEntityId": "king…/saml/module.php/saml/sp/metadata.php/orangehrm-sp",
 "spAcsUrl": "https://king…/saml/module.php/saml/sp/saml2-acs.php/orangehrm-sp",
 "spRelayState": "https://king…/openidauth/openIdCredentials?openIdProvider=saml_<idp row id>"}
```

`state/<tree>/` holds one fact per file. No file is ever sourced as shell.

| File | Content |
|---|---|
| `app_db` | The tree's app database name. |
| `domain_name.b64` | One line: the earlier `domain.name` value, base64, without newlines. |
| `created_files` | Tree-relative paths that `link` created, one per line. |
| `exclude_added` | Exact lines that `link` appended to `.git/info/exclude`, one per line. |
| `idp_row_id`, `sp_row_id` | The provider row ids that `link` inserted. |

---

### Task 1: Container image and opt-in compose service

**Files:**
- Create: `custom-compose/saml.yml`, `custom-compose/config/saml/Dockerfile`, `custom-compose/config/saml/apache-site.conf`, `custom-compose/config/saml/.gitignore`, `custom-compose/config/saml/simplesamlphp/config/config.php`
- Modify: `README.md` (container table, after the `dev_rabbitmq` row)

**Interfaces:**
- Produces:
  - image tag `ohrm-dev/saml-test:2.4.1`;
  - SimpleSAMLphp installed at `/var/simplesamlphp`;
  - `SIMPLESAMLPHP_CONFIG_DIR=/etc/simplesamlphp/config`;
  - the mount table above;
  - Apache `DocumentRoot /var/www/site` and `Alias /simplesaml /var/simplesamlphp/public`.

- [ ] **Step 1: Commit the spec and this plan first**

```bash
cd ~/web
rm docs/superpowers/specs/2026-11-03-saml-test-container-design-draft.md
git add docs/superpowers/specs/2026-11-07-saml-test-container-design.md docs/superpowers/plans/2026-11-07-saml-test-container.md
git commit -m "docs: SAML test container design and plan"
```

**Destructive:** the `rm` deletes the paused draft, which was never committed. The approved design replaces it (spec header).

- [ ] **Step 2: Pin the tarball checksum**

Run: `curl -fsSL -o /tmp/ssp.tgz https://github.com/simplesamlphp/simplesamlphp/releases/download/v2.4.1/simplesamlphp-2.4.1-slim.tar.gz && shasum -a 256 /tmp/ssp.tgz`
Expected: one 64-hex digest. It goes into `ARG SSP_SHA256` in the Dockerfile.

- [ ] **Step 3: Write the Dockerfile, the Apache site, the compose file and the minimal `config.php`**

- **Dockerfile:**
  - `FROM php:8.3-apache`, with `ARG SSP_VERSION=2.4.1` and `ARG SSP_SHA256`.
  - Download, `sha256sum -c`, and extract with `--strip-components=1` into `/var/simplesamlphp`.
  - Copy `apache-site.conf` over `/etc/apache2/sites-available/000-default.conf`.
  - No extra PHP extensions. The official image already has everything 2.4.1 requires.
- **`apache-site.conf`:**
  - `DocumentRoot /var/www/site`;
  - `Alias /simplesaml /var/simplesamlphp/public`, with its `<Directory>` granted;
  - `<Directory /var/www/site/lib> Require all denied`;
  - `SetEnv SIMPLESAMLPHP_CONFIG_DIR /etc/simplesamlphp/config`;
  - `SetEnv HTTPS on`. All traffic arrives through nginx TLS, and SimpleSAMLphp refuses to set a `Secure` cookie on plain HTTP (`Utils/HTTP.php:1106`).
- **`saml.yml`:** service `saml` with:
  - `build: ./custom-compose/config/saml` and `image: ohrm-dev/saml-test:2.4.1`;
  - `container_name: dev_saml` and `restart: "no"`;
  - `networks: ohrmdevnet: ipv4_address: 10.5.2.7`;
  - the mounts from the table above. Paths are relative to the repo root, as in `ldap.yml`.
- **`config.php`:** `require '/var/simplesamlphp/config/config.php.dist';` then override these keys only:

| Key | Value |
|---|---|
| `baseurlpath` | `'https://saml.test/simplesaml/'` |
| `certdir` | `'/etc/simplesamlphp/cert/'` |
| `metadata.sources` | `[['type' => 'flatfile', 'directory' => '/etc/simplesamlphp/metadata']]` |
| `secretsalt` | `trim(file_get_contents('/etc/simplesamlphp/cert/secretsalt'))` when that file exists, else `'not-yet-set'` |
| `enable.saml20-idp` | `true` |
| `module.enable` | `['testidp' => true, 'exampleauth' => false]` |
| `session.cookie.secure` | `true` |
| `session.cookie.samesite` | `'None'` |
| `trusted.url.domains` | `['saml.test']` |
| `showerrors` | `true` |
| `logging.handler` | `'stderr'` |
| `logging.level` | `\SimpleSAML\Logger::INFO` |
| `timezone` | `'UTC'` |

- `.gitignore`: `keys/`, `trees/`, `state/`, `generated/`, `data/`.
- README table row: `| dev_saml | saml | SimpleSAMLphp 2.4.1 | 10.5.2.7 | 80 | - |`.

- [ ] **Step 4: Build and start it by hand, and check that it serves**

Run:
```bash
cd ~/web && mkdir -p custom-compose/config/saml/{keys,trees,data}
docker-compose -f docker-compose.yml -f docker-compose.override.yml -f custom-compose/saml.yml up -d --build --no-deps saml
docker exec dev_saml php -r 'require "/var/simplesamlphp/vendor/autoload.php"; echo \SimpleSAML\Configuration::VERSION, "\n";'
docker exec dev_saml curl -s -o /dev/null -w '%{http_code}\n' http://localhost/simplesaml/
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dev_saml
```
Expected: `2.4.1`, then `200` or `302`, then `10.5.2.7`.

- [ ] **Step 5: Check that a plain `up` never starts it**

Run: `cd ~/web && docker-compose config --services | grep -x saml; echo "exit=$?"`
Expected: no service name printed, `exit=1`.

- [ ] **Step 6: Commit**

```bash
git add custom-compose/saml.yml custom-compose/config/saml/Dockerfile custom-compose/config/saml/apache-site.conf custom-compose/config/saml/.gitignore custom-compose/config/saml/simplesamlphp/config/config.php README.md
git commit -m "Add opt-in SimpleSAMLphp 2.4.1 container (dev_saml, 10.5.2.7)"
```

---

### Task 2: `ohrm saml up | down | status`, with TLS, nginx and `/etc/hosts`

**Files:**
- Create: `utils/ohrm-saml.sh`, `utils/tests/ohrm-saml-test.sh`, `custom-compose/config/saml/nginx/saml.conf`
- Modify: `utils/ohrm-shell.sh` (header usage lines, `usage()` destinations, a dispatch block after the `build` block at line ~243), `utils/tests/ohrm-shell-test.sh`, `.gitignore`

**Interfaces:**
- Consumes: Task 1's compose service.
- Produces these `ohrm-saml.sh` helpers, which Tasks 4 to 6 use:
  - `run CMD…`: runs the command, or in dry-run prints `+ CMD…`.
  - `db_sql DB`: SQL on stdin. Runs `docker exec -i -e MYSQL_PWD dev_mariadb_101115 mysql -uroot -N -B --raw DB`. In dry-run it prints `+ sql[DB]:` and the SQL, then echoes `DRYRUN`.
  - `compose ARGS…`: runs `docker-compose -f docker-compose.yml [-f docker-compose.override.yml if present] -f custom-compose/saml.yml ARGS…` from the repo root.
  - File helpers. Each one only prints in dry-run, in exactly the format shown, because the tests match on it:
    - `append_line FILE LINE` prints `+ append FILE: LINE`;
    - `write_file FILE` (content on stdin) prints `+ write FILE`;
    - `remove_path PATH` prints `+ rm -f PATH`, or `+ rm -rf PATH` for a folder;
    - `remove_lines FILE LINESFILE` prints `+ remove-lines FILE`.
  - Variables: `SAML_DIR="${OHRM_SAML_DIR:-$repo_root/custom-compose/config/saml}"`, `NGINX_DIR="${OHRM_NGINX_DIR:-$repo_root/config/nginx}"`, `HOSTS_FILE="${OHRM_HOSTS_FILE:-/etc/hosts}"`.
  - Environment overrides, documented in the header: `OHRM_TEST_SRC_PATH`, `OHRM_DB_PASS`, `OHRM_WEB_CONTAINER`, `OHRM_DRY_RUN`, `OHRM_TTY`, `OHRM_WEB_RUNNING` (stands in for `docker inspect`).
  - `--yes`/`-y` answers the `/etc/hosts` prompt.

- [ ] **Step 1: Write the failing tests**

Follow `utils/tests/ohrm-build-test.sh`:
- same `check` / `check_not` / `check_before` helpers, plus `fail_rc`, which counts a failure for an unexpected exit code;
- a `mktemp -d` fixture `$fx`, laid out as `$fx/saml` (`OHRM_SAML_DIR`), `$fx/nginx` (`OHRM_NGINX_DIR`), `$fx/hosts` (`OHRM_HOSTS_FILE`, an empty file) and `$fx/test` (`OHRM_TEST_SRC_PATH`);
- `run` invokes `utils/ohrm-saml.sh` with `OHRM_DRY_RUN=1 OHRM_TTY=0` and those variables set.

```bash
out=$(run --help);                 check "help shows usage"            "ohrm saml up" "$out"
out=$(run bogus); rc=$?;           check "unknown command is an error" "usage: ohrm saml" "$out"; [[ $rc -eq 2 ]] || fail_rc
out=$(run up)
check "up generates container keys"     "openssl req -x509" "$out"
check "up generates the salt"           "openssl rand -hex 32" "$out"
check "up asks mkcert for saml.test"    "mkcert -key-file $fx/nginx/cert/saml/key.pem -cert-file $fx/nginx/cert/saml/cert.pem saml.test" "$out"
check_before "cert before nginx block"  "mkcert" "virtual-servers/saml.conf" "$out"
check "up tests nginx before reload"    "docker exec dev_nginx nginx -t" "$out"
check "no TTY: hosts line printed"      "127.0.0.1 saml.test" "$out"
check_not "no TTY: no sudo"             "sudo tee" "$out"
check "up starts only saml"             "-f custom-compose/saml.yml up -d --build --no-deps saml" "$out"
touch "$fx/saml/keys/container.key" "$fx/saml/keys/container.crt" "$fx/saml/keys/secretsalt" "$fx/nginx/cert/saml/cert.pem" "$fx/nginx/cert/saml/key.pem"
echo "127.0.0.1 saml.test" >> "$fx/hosts"
out=$(run up)
check_not "second up: no new keys"      "openssl req -x509" "$out"
check_not "second up: no new cert"      "mkcert" "$out"
check_not "second up: no hosts prompt"  "127.0.0.1 saml.test" "$out"
out=$(run down);                   check "down removes the container" "-f custom-compose/saml.yml rm -sf saml" "$out"
```

In `utils/tests/ohrm-shell-test.sh`, add: `OHRM_DRY_RUN=1 ohrm-shell.sh saml --help` output contains `ohrm saml up`.

- [ ] **Step 2: Run the tests and see them fail**

Run: `utils/tests/ohrm-saml-test.sh; utils/tests/ohrm-shell-test.sh`
Expected: FAIL. `ohrm-saml.sh` doesn't exist yet.

- [ ] **Step 3: Implement `utils/ohrm-saml.sh` with `up`, `down` and `status`, and the dispatch**

- **Header comment = `--help`**, extracted as in `ohrm-shell.sh` `help_text()`. It lists every command, including `link` and `unlink` (marked "see below" until Tasks 5 and 6), plus the environment overrides.
- **`up`, in this order:**
  1. Container key pair `keys/container.{key,crt}`, if missing: `openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=saml.test`. Then `chmod 644` both files. This is a dev-only key, and the container's Apache must read it through the bind mount.
  2. `keys/secretsalt`, if missing: `openssl rand -hex 32`.
  3. `$NGINX_DIR/cert/saml/{cert,key}.pem`, if missing, via the mkcert command in the test.
  4. Copy `custom-compose/config/saml/nginx/saml.conf` to `$NGINX_DIR/virtual-servers/saml.conf` if missing or different. Then `docker exec dev_nginx nginx -t`. If that fails, remove the copy and exit 1. Otherwise `nginx -s reload`. **Never copy the block before the certificate exists.**
  5. The `/etc/hosts` line. Match `[[:space:]]saml.test([[:space:]]|$)` as `sync-dev-hosts.sh` does. With a TTY, prompt y/N, or take `--yes`, then `sudo tee -a`. Without a TTY, print the line to add.
  6. `mkdir -p` the `trees`, `state`, `generated` and `data` folders.
  7. `compose up -d --build --no-deps saml`.
  8. Wait up to 30 s for `docker exec dev_saml curl -fsS -o /dev/null http://localhost/simplesaml/`.
- **`down`:** `compose rm -sf saml`.
- **`status`:**
  - prints `container: running|stopped`;
  - prints `https://saml.test/: <code>` from `curl --cacert "$(mkcert -CAROOT)/rootCA.pem" -s -o /dev/null -w '%{http_code}'`;
  - then one line per `state/*/` folder. Task 6 fills that part in.
- **`nginx/saml.conf`:**
  - `listen 443 ssl http2; server_name saml.test;`
  - `ssl_certificate /etc/nginx/cert/saml/cert.pem; ssl_certificate_key /etc/nginx/cert/saml/key.pem;`
  - `location / { proxy_pass http://10.5.2.7; proxy_set_header Host $host; proxy_set_header X-Forwarded-Proto https; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; }`
  - No `add_header` lines. One would drop every `http`-level header that the block inherits.
- **`.gitignore`:** add `config/nginx/virtual-servers/saml.conf`.
- **`ohrm-shell.sh`:**
  - header line `#   ohrm saml <command> [tree]   # SAML test container — see 'ohrm saml --help'`;
  - add `saml` to the destinations in `usage()`;
  - add `if [[ "${ohrm_args[0]:-}" == "saml" ]]; then exec "$repo_root/utils/ohrm-saml.sh" "${ohrm_args[@]:1}"; fi` after the `build` block.

- [ ] **Step 4: Run the tests and see them pass**

Run: `utils/tests/ohrm-saml-test.sh && utils/tests/ohrm-shell-test.sh`
Expected: every line `ok`, exit 0.

- [ ] **Step 5: Live check**

Run, in a terminal, so the hosts prompt can take sudo: `ohrm saml up`, then:
```bash
curl --cacert "$(mkcert -CAROOT)/rootCA.pem" -s -D - -o /dev/null https://saml.test/simplesaml/module.php/core/welcome | grep -i -E '^HTTP|set-cookie'
ohrm saml down; curl --cacert "$(mkcert -CAROOT)/rootCA.pem" -s -o /dev/null -w '%{http_code}\n' https://saml.test/
docker restart dev_nginx && sleep 2 && curl -sk -o /dev/null -w '%{http_code}\n' https://king.test-webubuntu83.orangehrmdev.com/
```
Expected:
- an `HTTP/2 200` or a redirect, with every `Set-Cookie` carrying `Secure` and `SameSite=None`;
- then `502`;
- then `200` or `302` from king. nginx survives with `dev_saml` down.

Run `ohrm saml up` again at the end, and confirm it creates nothing new.

- [ ] **Step 6: Commit**

```bash
git add utils/ohrm-saml.sh utils/tests/ohrm-saml-test.sh custom-compose/config/saml/nginx/saml.conf utils/ohrm-shell.sh utils/tests/ohrm-shell-test.sh .gitignore
git commit -m "ohrm saml up/down/status: TLS, nginx block and hosts line for saml.test"
```

---

### Task 3: Container as IdP, with any-username sign-in

**Files:**
- Create:
  - `custom-compose/config/saml/simplesamlphp/modules/testidp/src/Auth/Source/AnyUser.php`
  - `custom-compose/config/saml/simplesamlphp/config/authsources.php`
  - `custom-compose/config/saml/simplesamlphp/metadata/saml20-idp-hosted.php`
  - `custom-compose/config/saml/simplesamlphp/metadata/saml20-sp-remote.php`
  - `custom-compose/config/saml/site/lib/trees.php`
  - `custom-compose/config/saml/site/login.php`
  - `custom-compose/config/saml/site/index.php`
  - `utils/tests/saml-selftest.py`

**Interfaces:**
- Consumes: `keys/container.{key,crt}` (Task 2) and the `trees/<tree>.json` format (File Structure).
- Produces:
  - `linkedTrees(): array` in `site/lib/trees.php`. It returns the decoded `/var/saml-trees/*.json` sorted by `tree`, and skips files that fail to decode.
  - `const SAML_TEST_ORIGIN = 'https://saml.test';`
  - auth source id `testidp-any`, class `SimpleSAML\Module\testidp\Auth\Source\AnyUser`, config key `loginUrl`.
  - the self-test CLI: `python3 -I utils/tests/saml-selftest.py --cafile <rootCA.pem> idp|sp`.

- [ ] **Step 1: Write the failing self-test (`idp` mode)**

stdlib only. `ssl.create_default_context(cafile=…)`, a `http.cookiejar` opener, and `html.parser` for forms. The form parsing ports from `html/OHRMStandalone/TEST/_work/saml-sp-throwaway/roundtrip.py`. Each case starts IdP-initiated at `https://saml.test/simplesaml/module.php/saml/idp/singleSignOnService?spentityid=https%3A%2F%2Fsaml.test%2Fsp`, follows redirects to `/login.php?AuthState=…`, posts `username`, and decodes the `SAMLResponse` in the returned auto-submit form.

```python
def case_admin_asserted():
    r = idp_login("admin")
    assert r.form_action == "https://saml.test/simplesaml/module.php/saml/sp/saml2-acs.php/container-sp"
    assert r.issuer == "https://saml.test/idp"
    assert r.name_id == "admin"
    assert r.name_id_format == "urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified"
    assert r.attributes == {"username": ["admin"]}
    assert r.response_signed or r.assertion_signed

def case_odd_username_asserted_verbatim():
    odd = "  <b>o'neil</b> x  "
    r = idp_login(odd)
    assert r.name_id == "<b>o'neil</b> x"
    assert "<b>o'neil</b>" not in r.login_page_html   # login page never echoes input as HTML

def case_empty_username_refused():
    page = idp_login_raw("   ")
    assert "Enter a username" in page and "SAMLResponse" not in page
```

- [ ] **Step 2: Run it and see it fail**

Run: `python3 -I utils/tests/saml-selftest.py --cafile "$(mkcert -CAROOT)/rootCA.pem" idp`
Expected: FAIL. The SSO endpoint has no hosted IdP yet, so the error names `singleSignOnService`.

- [ ] **Step 3: Implement the IdP**

- **`AnyUser`** extends `\SimpleSAML\Auth\Source`. Model it on `modules/exampleauth/src/Auth/Source/External.php` in SimpleSAMLphp 2.4.1.
  - `authenticate(array &$state): void` saves the state with `Auth\State::saveState($state, 'testidp:AnyUser')`.
  - It then calls `(new Utils\HTTP())->redirectTrustedURL($this->loginUrl, ['AuthState' => $id])`.
- **`login.php`:**
  - **GET** renders a form with one `username` field, and a "Recent" list built by JavaScript from `localStorage['samlTestRecentUsernames']`. The list keeps the last 5, rendered with `textContent`, one button each.
  - **POST:** trims the username. If it is empty, the form is shown again with `Enter a username`. Otherwise it saves the username to the recent list on the client side before submitting, calls `Auth\State::loadState($_REQUEST['AuthState'], 'testidp:AnyUser')`, sets `$state['Attributes'] = ['username' => [$u]]`, and calls `\SimpleSAML\Auth\Source::completeAuth($state)`.
  - Every value echoed into HTML goes through `htmlspecialchars`.
- **`authsources.php`:** `'testidp-any' => ['testidp:AnyUser', 'loginUrl' => 'https://saml.test/login.php']`.
- **`saml20-idp-hosted.php`:** `$metadata['https://saml.test/idp']` with:
  - `host` `__DEFAULT__`, `privatekey` `container.key`, `certificate` `container.crt`, `auth` `testidp-any`;
  - `authproc` `[10 => ['class' => 'saml:AttributeNameID', 'identifyingAttribute' => 'username', 'Format' => 'urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified']]`.
- **`saml20-sp-remote.php`:** one entry per `linkedTrees()` item, keyed by `spEntityId`, plus `https://saml.test/sp` itself, with:
  - `AssertionConsumerService` HTTP-POST at `spAcsUrl` (for itself: the `container-sp` ACS URL above);
  - `NameIDFormat` unspecified;
  - `saml20.sign.assertion` true.
- **`index.php` (apps page):** for each linked tree, two links. If no trees are linked, it shows `No trees linked. Run: ohrm saml link <tree>`.
  - **"Sign in to <tree>"** goes to `…/simplesaml/module.php/saml/idp/singleSignOnService?spentityid=<urlenc spEntityId>&RelayState=<urlenc spRelayState>`.
  - **"Start at <tree>'s IdP"** goes to `https://<host>/saml/saml2/idp/SSOService.php?spentityid=https%3A%2F%2Fsaml.test%2Fsp`.

- [ ] **Step 4: Run it and see it pass**

Run: `python3 -I utils/tests/saml-selftest.py --cafile "$(mkcert -CAROOT)/rootCA.pem" idp`
Expected: three `ok` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add custom-compose/config/saml/simplesamlphp/modules/testidp/src/Auth/Source/AnyUser.php custom-compose/config/saml/simplesamlphp/config/authsources.php custom-compose/config/saml/simplesamlphp/metadata/saml20-idp-hosted.php custom-compose/config/saml/simplesamlphp/metadata/saml20-sp-remote.php custom-compose/config/saml/site/lib/trees.php custom-compose/config/saml/site/login.php custom-compose/config/saml/site/index.php utils/tests/saml-selftest.py
git commit -m "SAML container IdP: any-username sign-in and apps page"
```

---

### Task 4: Container as SP, with the result page and metadata export

**Files:**
- Create: `custom-compose/config/saml/simplesamlphp/metadata/saml20-idp-remote.php`, `custom-compose/config/saml/site/lib/capture.php`, `custom-compose/config/saml/site/sp/index.php`, `custom-compose/config/saml/site/sp/result.php`
- Modify: `custom-compose/config/saml/simplesamlphp/config/authsources.php`, `custom-compose/config/saml/apache-site.conf`, `utils/ohrm-saml.sh` (`up` exports metadata), `utils/tests/ohrm-saml-test.sh`, `utils/tests/saml-selftest.py`

**Interfaces:**
- Consumes: `linkedTrees()` and `SAML_TEST_ORIGIN` (Task 3), and `run` / `compose` (Task 2).
- Produces:
  - `generated/idp-metadata.xml` and `generated/sp-metadata.xml`, refreshed by every `up`. Task 5 reads them.
  - `/var/saml-data/acs.log` JSON lines with these keys: `time, issuer, inResponseTo, destination, responseSigned, assertionSigned, assertionCount, encrypted, nameId, error`.

- [ ] **Step 1: Write the failing tests**

In `saml-selftest.py`, add `sp` mode:

```python
def case_sp_initiated_self():
    page = sp_login(idp="https://saml.test/idp", username="alice")   # starts at /sp/?idp=…
    assert "Flow: SP-initiated" in page
    assert "Issuer: https://saml.test/idp" in page
    assert "NameID: alice" in page and "username: alice" in page
    assert "Signed: yes" in page

def case_idp_initiated_self():
    page = idp_initiated_to_sp(username="bob")   # singleSignOnService?spentityid=https://saml.test/sp, then on to the ACS
    assert "Flow: IdP-initiated" in page and "NameID: bob" in page
```

In `ohrm-saml-test.sh`, add:

```bash
out=$(run up)
check "up exports IdP metadata" "curl -fsS http://localhost/simplesaml/module.php/saml/idp/metadata" "$out"
check "up exports SP metadata"  "curl -fsS http://localhost/simplesaml/module.php/saml/sp/metadata/container-sp" "$out"
```

- [ ] **Step 2: Run them and see them fail**

Run: `utils/tests/ohrm-saml-test.sh; python3 -I utils/tests/saml-selftest.py --cafile "$(mkcert -CAROOT)/rootCA.pem" sp`
Expected: the two new `check` lines FAIL, and the `sp` cases FAIL on `/sp/` with 404.

- [ ] **Step 3: Implement the SP**

- **`authsources.php`:** add `'container-sp' => ['saml:SP', 'entityID' => 'https://saml.test/sp', 'idp' => null, 'privatekey' => 'container.key', 'certificate' => 'container.crt', 'RelayState' => 'https://saml.test/sp/result.php']`. A configured `RelayState` wins for unsolicited responses (`ServiceProvider.php:370`), so IdP-initiated logins land on the result page.
- **`saml20-idp-remote.php`:** one entry per tree, keyed `idpEntityId`, with `SingleSignOnService` HTTP-Redirect at `idpSsoUrl` and `certData` `idpCert`. Add one more entry for `https://saml.test/idp` itself, with the SSO URL `https://saml.test/simplesaml/module.php/saml/idp/singleSignOnService` and `certData` taken from `container.crt`.
- **`sp/index.php`:**
  - one "Log in at <tree>" button per tree, plus "Log in at saml.test (self-test)";
  - `GET ?idp=<entityId>` calls `(new \SimpleSAML\Auth\Simple('container-sp'))->login(['saml:idp' => $idp, 'ReturnTo' => 'https://saml.test/sp/result.php'])`;
  - "Clear SP session" calls `\SimpleSAML\Session::getSessionFromRequest()->doLogout('container-sp')`. This is local only, with no SLO.
- **`capture.php`:** in Apache, `<Location /simplesaml/module.php/saml/sp/saml2-acs.php>` with `php_value auto_prepend_file /var/www/site/lib/capture.php`.
  - It runs only when `$_POST['SAMLResponse']` is set.
  - It base64-decodes the response and loads it with `LIBXML_NONET` and no entity loading.
  - It appends one JSON line with the keys listed above. `responseSigned` / `assertionSigned` mean a `ds:Signature` element is a direct child of `samlp:Response` / `saml:Assertion`.
  - It never stops the request. A parse failure is logged with the `error` key set.
  - Port the element lookups from the throwaway's `index.php` `acs()`.
- **`result.php`:**
  - If not authenticated: `Not logged in` and a link to `/sp/`.
  - Otherwise it prints these lines, each `htmlspecialchars`'d:
    - `Flow: SP-initiated|IdP-initiated`, from whether the latest log line has `inResponseTo`;
    - `Tree: <tree or self>`;
    - `Issuer: …` and `NameID: …`, from `getAuthData('saml:sp:NameID')->getValue()`;
    - `Signed: yes|no`, with `(response: …, assertion: …)`;
    - one `name: value` line per attribute.
  - The latest log line is matched by `issuer`.
  - A failed check never reaches this page. SimpleSAMLphp's error page shows the exception (`showerrors` true), and `acs.log` still holds the raw structure.
- **`up`:** after the wait in Task 2, run `docker exec dev_saml curl -fsS <url>` for both metadata URLs, and write the output to `generated/idp-metadata.xml` and `generated/sp-metadata.xml`.

- [ ] **Step 4: Run them and see them pass**

Run:
```bash
utils/tests/ohrm-saml-test.sh
ohrm saml up
python3 -I utils/tests/saml-selftest.py --cafile "$(mkcert -CAROOT)/rootCA.pem" idp
python3 -I utils/tests/saml-selftest.py --cafile "$(mkcert -CAROOT)/rootCA.pem" sp
grep -o 'entityID="[^"]*"' custom-compose/config/saml/generated/*.xml
```
Expected:
- all `ok`;
- `entityID="https://saml.test/idp"` in `idp-metadata.xml`;
- `entityID="https://saml.test/sp"` in `sp-metadata.xml`.

- [ ] **Step 5: Commit**

```bash
git add custom-compose/config/saml/simplesamlphp/metadata/saml20-idp-remote.php custom-compose/config/saml/site/lib/capture.php custom-compose/config/saml/site/sp/index.php custom-compose/config/saml/site/sp/result.php custom-compose/config/saml/simplesamlphp/config/authsources.php custom-compose/config/saml/apache-site.conf utils/ohrm-saml.sh utils/tests/ohrm-saml-test.sh utils/tests/saml-selftest.py
git commit -m "SAML container SP: per-IdP login, result page, ACS capture, metadata export"
```

---

### Task 5: `ohrm saml link <tree>`

**Files:**
- Modify: `utils/ohrm-saml.sh`, `utils/tests/ohrm-saml-test.sh`, `utils/tests/saml-selftest.py`

**Interfaces:**
- Consumes: `run`, `db_sql`, `append_line`, `write_file` (Task 2); `generated/*.xml` (Task 4); and the formats in File Structure.
- Produces, for Task 6:
  - `tree_host TREE`: prints `TREE.test-webubuntu83.orangehrmdev.com`.
  - `tree_app_db TREE`: prints the `dbname=` value of the first `dsn:` in `<test root>/TREE/symfony/config/databases.yml`, and fails unless it matches `^[A-Za-z0-9_]+$`.
  - `check_tree TREE`: exits 1 with one message per failure: slug not `^[a-z0-9]+$`; no tree folder; no `databases.yml`; `.git` is not a folder (`worktree trees are not supported`); no plugin cert folder (`not an enterprise tree`).
  - `web_running`: true when `${OHRM_WEB_RUNNING:-$(docker inspect -f '{{.State.Running}}' $OHRM_WEB_CONTAINER)}` is `true`. `OHRM_WEB_CONTAINER` defaults to `dev_web_83_ubuntu`.
  - `state_dir TREE`: prints `$SAML_DIR/state/TREE`.
  - Self-test mode `python3 -I utils/tests/saml-selftest.py --cafile <rootCA.pem> tree <tree>`.

- [ ] **Step 1: Write the failing tests**

The fixture gets a TEST root with trees `king` and `queen`. Each has `symfony/config/databases.yml` (dsn `dbname=king` / `dbname=queen`), a `.git/info/exclude` folder and file, and the plugin cert folder. It also gets a `wt` tree whose `.git` is a file, and `$fx/saml/generated/{idp,sp}-metadata.xml` holding `<x/>`.

```bash
out=$(run link 'Bad!');            check "bad slug refused"        "must match ^[a-z0-9]+\$" "$out"
out=$(run link nosuch);            check "unknown tree refused"    "no working copy 'nosuch'" "$out"
out=$(run link wt);                check "worktree refused"        "worktree trees are not supported" "$out"
mv "$fx/saml/generated" "$fx/saml/gen.off"; out=$(run link king); mv "$fx/saml/gen.off" "$fx/saml/generated"
check "needs up first" "run 'ohrm saml up' first" "$out"
out=$(OHRM_WEB_RUNNING=true run link king)
check "records domain.name first"       "SELECT REPLACE(TO_BASE64(value), CHAR(10), '') FROM ohrm_config WHERE property = 'domain.name'" "$out"
check_before "record before update"     "TO_BASE64(value)" "UPDATE ohrm_config" "$out"
check "sets domain.name via base64"     "UPDATE ohrm_config SET value = FROM_BASE64('$(printf %s king.test-webubuntu83.orangehrmdev.com | base64)') WHERE property = 'domain.name'" "$out"
check "generates tree IdP key"          "openssl req -x509" "$out"
check "appends pem exclude line"        "/symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert/saml.prod.orangehrm-idp.pem" "$out"
check "inserts IdP row"                 "'SAML test container', 'IDP'" "$out"
check "IdP row username_key"            "'username', 1" "$out"
check "inserts SP row"                  "'SAML test container', 'SP'" "$out"
check "maps four attributes"            "(@sp, 2, 'username'), (@sp, 3, 'firstName'), (@sp, 5, 'email'), (@sp, 6, 'employeeId')" "$out"
check "writes registration"             "$fx/saml/trees/king.json" "$out"
check "clears tree cache"               "php symfony cc" "$out"
out=$(OHRM_WEB_RUNNING=false run link king)
check_not "link skips cache clear when web container is down" "php symfony cc" "$out"
check     "says how to clear later"     "ohrm sf king -- php symfony cc" "$out"
touch "$fx/test/king/symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert/saml.prod.orangehrm-idp."{pem,crt}
printf '%s\n' /symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert/saml.prod.orangehrm-idp.{pem,crt} >> "$fx/test/king/.git/info/exclude"
out=$(run link king)
check_not "existing key kept"           "openssl req -x509" "$out"
check_not "existing exclude kept"       "append $fx/test/king/.git/info/exclude" "$out"
mkdir -p "$fx/saml/state/king"; out=$(run link king)
check "already linked is a no-op"       "king is already linked" "$out"
check_not "no-op touches nothing"       "UPDATE" "$out"
```

- [ ] **Step 2: Run them and see them fail**

Run: `utils/tests/ohrm-saml-test.sh`
Expected: the `link` cases FAIL with `unknown command link`.

- [ ] **Step 3: Implement `link`, following §6.6**

Order is fixed. Each state fact is written **before** the change it covers, so a partial run can always be restored.

1. Run `check_tree`. Stop if the tree is already linked (state folder exists), or if `generated/*.xml` is missing.
2. Write `app_db`. Read `domain.name` with the `TO_BASE64` query from the test and write the result to `domain_name.b64`. If the query returns no row, stop with `king has no domain.name row` and remove the state folder.
3. Run `UPDATE ohrm_config …` (the exact SQL in the test).
4. For each of the `.pem` and `.crt` files that is missing: append its tree-relative path to `created_files`. Once both are listed, generate them together with `openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=<host>`, then `chmod 644`.
5. For each exclude line missing from `.git/info/exclude` (`grep -qxF`): append the line to `exclude_added`, then to the exclude file.
6. Warn if there is already an active IdP row: `SELECT COUNT(*) FROM ohrm_saml_provider WHERE type = 'IDP' AND status = 1`.
7. Insert the IdP row, write `idp_row_id`, then insert the SP row and its attribute rows, and write `sp_row_id`. One `db_sql` call per row, SQL on stdin:
   - IdP row: `INSERT INTO ohrm_saml_provider (name, type, metadata, username_key, status) VALUES ('SAML test container', 'IDP', FROM_BASE64('<idp-metadata.xml as base64>'), 'username', 1); SELECT LAST_INSERT_ID();`
   - SP row: the same with `'SP'` and `NULL` for `username_key`, then `SET @sp = LAST_INSERT_ID();`, the attribute insert from the test, and `SELECT @sp;`
8. Write `trees/<tree>.json` with `jq -n --arg`. `idpCert` is `openssl x509 -in <crt> -outform DER | base64 | tr -d '\n'`.
9. If `web_running`: `docker exec -w /var/www/html/OHRMStandalone/TEST/<tree>/symfony $OHRM_WEB_CONTAINER php symfony cc`. Otherwise print `web container is down; later run: ohrm sf <tree> -- php symfony cc`.
10. Print the tree's login URL and `https://saml.test/`.

- [ ] **Step 4: Run them and see them pass**

Run: `utils/tests/ohrm-saml-test.sh`
Expected: all `ok`.

- [ ] **Step 5: Take king's "before" snapshot**

Task 6 compares against this snapshot.

```bash
snap=~/web/custom-compose/config/saml/data/king-before; mkdir -p "$snap"
docker exec -e MYSQL_PWD=1234 dev_mariadb_101115 mysql -uroot -N -B king -e "SELECT * FROM ohrm_saml_provider ORDER BY id; SELECT * FROM ohrm_saml_provider_attribute ORDER BY provider_id, token_id; SELECT value FROM ohrm_config WHERE property='domain.name'; SELECT COUNT(*) FROM ohrm_saml_user_identity;" > "$snap/db.txt"
git -C ~/web/html/OHRMStandalone/TEST/king status --porcelain > "$snap/git-status.txt"
cp ~/web/html/OHRMStandalone/TEST/king/.git/info/exclude "$snap/exclude"
ls -la ~/web/html/OHRMStandalone/TEST/king/symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert/ > "$snap/certdir.txt"
```

- [ ] **Step 6: Live check on king**

Run:
```bash
ohrm saml link king
curl -sk https://king.test-webubuntu83.orangehrmdev.com/saml/saml2/idp/metadata.php | grep -o 'entityID="[^"]*"'
git -C ~/web/html/OHRMStandalone/TEST/king status --porcelain | diff - custom-compose/config/saml/data/king-before/git-status.txt && echo "git status unchanged"
ohrm saml link king
```
Expected:
- `entityID="https://king.test-webubuntu83.orangehrmdev.com/saml/saml2/idp/metadata.php"`;
- `git status unchanged`;
- the second `link` prints `king is already linked`.

If the entity ID still names `localhost`, the cache clear didn't reach the config cache (`sfContext::getOhrmConfigCache()`, used by `ConfigService::getValue($p, true)`). Find which cache backs it, make step 9 clear that one, and re-run.

- [ ] **Step 7: Confirm IdP-initiated sign-in into king now, not at the end (§6.3)**

Add the `tree <tree>` mode to `saml-selftest.py`:
1. Read `custom-compose/config/saml/trees/<tree>.json`.
2. Start at `https://saml.test/simplesaml/module.php/saml/idp/singleSignOnService?spentityid=<urlenc spEntityId>&RelayState=<urlenc spRelayState>`.
3. Post `admin` at `/login.php`.
4. Submit the auto-POST form to the tree's ACS, and follow the redirects.

```python
def case_tree_idp_initiated(tree):
    final_url, html = tree_idp_initiated(tree, username="admin")
    assert urlparse(final_url).hostname == f"{tree}.test-webubuntu83.orangehrmdev.com"
    assert "auth/login" not in final_url
    assert "SimpleSAMLphp" not in html or "error" not in html.lower()
```

Run: `python3 -I utils/tests/saml-selftest.py --cafile "$(mkcert -CAROOT)/rootCA.pem" tree king`
Expected: `ok`.

If it fails, check in a browser that it really fails. Then record it for the final report, leave this flow out, and carry on with Task 6. Never patch the tree.

This login adds one `ohrm_saml_user_identity` row for admin on king. Task 6 allows for that row.

Leave king linked. Task 6 unlinks it.

- [ ] **Step 8: Commit**

```bash
git add utils/ohrm-saml.sh utils/tests/ohrm-saml-test.sh utils/tests/saml-selftest.py
git commit -m "ohrm saml link: record state, set domain.name, IdP key, provider rows, registration"
```

---

### Task 6: `ohrm saml unlink <tree>`, `link` rollback and `status` per tree

**Files:**
- Modify: `utils/ohrm-saml.sh`, `utils/tests/ohrm-saml-test.sh`

**Interfaces:**
- Consumes: Task 5's helpers and state format.
- Produces:
  - `restore_tree TREE`, used by `unlink` and by `link`'s failure path.
  - `OHRM_SAML_FAIL_AT=<link step number>` makes `link` fail at that step. It works live and in dry-run, and is documented in the header as a test hook.
  - Dry-run writes no state, so the dry-run test proves only that the rollback runs. The live run in Step 5 proves that it restores the tree.

- [ ] **Step 1: Write the failing tests**

Add a `knight` tree to the fixture, set up like `king`, with no state folder. The tests use hand-made state folders.

```bash
mkstate() { # mkstate <tree> <domain value>
  local d="$fx/saml/state/$1"; mkdir -p "$d"; echo "$1" > "$d/app_db"
  printf %s "$2" | base64 | tr -d '\n' > "$d/domain_name.b64"
  printf '%s\n' symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert/saml.prod.orangehrm-idp.pem > "$d/created_files"
  printf '%s\n' /symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert/saml.prod.orangehrm-idp.pem > "$d/exclude_added"
  echo 41 > "$d/idp_row_id"; echo 42 > "$d/sp_row_id"; echo '{}' > "$fx/saml/trees/$1.json"
}
mkstate king "rook-style.example.com"; mkstate queen "localhost"
out=$(run unlink king)
check "unlink restores a non-localhost domain.name" "SET value = FROM_BASE64('$(printf %s rook-style.example.com | base64)')" "$out"
check "deletes only created files"   "rm -f $fx/test/king/symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert/saml.prod.orangehrm-idp.pem" "$out"
check_not "keeps files it didn't make" "saml.prod.orangehrm-idp.crt" "$out"
check "removes only added exclude lines" "remove-lines $fx/test/king/.git/info/exclude" "$out"
check "deletes attribute rows by id" "DELETE FROM ohrm_saml_provider_attribute WHERE provider_id IN (41, 42)" "$out"
check "deletes provider rows by id"  "DELETE FROM ohrm_saml_provider WHERE id IN (41, 42) AND name = 'SAML test container'" "$out"
check "removes registration"         "rm -f $fx/saml/trees/king.json" "$out"
check "removes state last"           "rm -rf $fx/saml/state/king" "$out"
check_before "registration before state" "trees/king.json" "state/king" "$out"
check_not "unlink king leaves queen alone" "queen" "$out"
rm -rf "$fx/saml/state/king"; out=$(run unlink king); rc=$?
check "unlink without state changes nothing" "king is not linked" "$out"; check_not "no SQL" "sql[" "$out"; [[ $rc -eq 1 ]] || fail_rc
out=$(OHRM_SAML_FAIL_AT=7 OHRM_WEB_RUNNING=true run link knight); rc=$?
check "failed link rolls back" "rolling back knight" "$out"; [[ $rc -eq 1 ]] || fail_rc
check_before "rollback ends by removing state" "rolling back knight" "rm -rf $fx/saml/state/knight" "$out"
```

- [ ] **Step 2: Run them and see them fail**

Run: `utils/tests/ohrm-saml-test.sh`
Expected: the `unlink` and rollback cases FAIL.

- [ ] **Step 3: Implement `restore_tree`, `unlink`, the rollback and `status`, following §6.7**

- **`restore_tree TREE`.** Each step skips cleanly when its state file is absent or empty. That covers a database reloaded since `link`, and a partial `link`.
  1. If `domain_name.b64` exists: `UPDATE ohrm_config SET value = FROM_BASE64('<b64>') WHERE property = 'domain.name'` on the recorded `app_db`.
  2. Delete the rows by the recorded ids. Delete attribute rows first, then provider rows, each guarded by `name = 'SAML test container'` as in the test.
  3. `rm -f` each path in `created_files`.
  4. Remove the lines in `exclude_added` from `.git/info/exclude`: `grep -vxF -f exclude_added`, written to a temp file in the same folder, then `mv`. Printed as `remove-lines <file>` in dry-run.
  5. `rm -f trees/<tree>.json`.
  6. Clear the tree cache, as in `link` step 9.
  7. `rm -rf state/<tree>` last.
- **`unlink TREE`:** `check_tree` slug validation only. If there is no state folder, print `<tree> is not linked` and exit 1. Otherwise run `restore_tree`.
- **`link` failure path:** wrap steps 2 to 9. On any failure, including `OHRM_SAML_FAIL_AT`, print `rolling back <tree>`, run `restore_tree`, and exit 1.
- **`status` per tree:** one line `<tree>  ok`, or `<tree>  missing: <list>`. It checks:
  - `rows`: both recorded ids present;
  - `registration`: `trees/<tree>.json` present;
  - `domain.name`: equals `tree_host`.

- [ ] **Step 4: Run them and see them pass**

Run: `utils/tests/ohrm-saml-test.sh`
Expected: all `ok`.

- [ ] **Step 5: Live check: unlink king and compare with the snapshot**

Run:
```bash
ohrm saml status
ohrm saml unlink king
snap=custom-compose/config/saml/data/king-before
docker exec -e MYSQL_PWD=1234 dev_mariadb_101115 mysql -uroot -N -B king -e "SELECT * FROM ohrm_saml_provider ORDER BY id; SELECT * FROM ohrm_saml_provider_attribute ORDER BY provider_id, token_id; SELECT value FROM ohrm_config WHERE property='domain.name'; SELECT COUNT(*) FROM ohrm_saml_user_identity;" | diff - "$snap/db.txt" && echo db-same
git -C html/OHRMStandalone/TEST/king status --porcelain | diff - "$snap/git-status.txt" && echo git-same
diff html/OHRMStandalone/TEST/king/.git/info/exclude "$snap/exclude" && echo exclude-same
ls -la html/OHRMStandalone/TEST/king/symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert/ | diff - "$snap/certdir.txt" && echo certdir-same
ohrm saml unlink king; echo "exit=$?"
OHRM_SAML_FAIL_AT=7 ohrm saml link king; echo "exit=$?"
# then repeat the four diffs above
```
Expected:
- `status` shows `king  ok`.
- Then `git-same`, `exclude-same` and `certdir-same`. Only the folder's own timestamp may differ in the `ls` output. If it does, compare the file names only.
- `db.txt` matches except the last line. The `ohrm_saml_user_identity` count is one higher if Task 5 Step 7 logged admin in. That row is activity, which spec §3 leaves behind.
- Then `king is not linked` and `exit=1`.
- Then the forced failure prints `rolling back king` and `exit=1`, and the four diffs come out the same again.

- [ ] **Step 6: Commit**

```bash
git add utils/ohrm-saml.sh utils/tests/ohrm-saml-test.sh
git commit -m "ohrm saml unlink: full restore from recorded state; link rolls back on failure"
```

---

### Task 7: Documentation and end-to-end checks on king and queen

**Files:**
- Modify: `README.md` (a new "SAML test container" section), `config/nginx/cert/README.md` (one line: `saml/` is generated by `ohrm saml up`)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Write the README section**

The section covers:
- what the container is for;
- the five commands;
- the one-time sudo prompt;
- trusting the mkcert CA (`mkcert -install`; Firefox needs `nss`);
- the URLs `https://saml.test/` and `https://saml.test/sp/`;
- that test logins leave activity behind, with the list in spec §3;
- how to read `custom-compose/config/saml/data/acs.log`.

- [ ] **Step 2: Snapshot king and queen, then link both**

Take the Task 5 Step 5 snapshot for both `king` and `queen`, into `data/<tree>-before`. Then run `ohrm saml link king && ohrm saml link queen && ohrm saml status`.
Expected: `king  ok` and `queen  ok`.

- [ ] **Step 3: Run spec §6.8 checks 3 to 7 in a browser, on each tree**

Use the Playwright MCP, with a context that has `ignoreHTTPSErrors`. Tree admin credentials are in `<tree>/devTools/citra-cowork/.instance.json`. Never print the password. Read it from the file inside the browser context. Record pass or fail per check per tree.

| # | Start | Action | Pass when |
|---|---|---|---|
| 3 | `https://<tree host>/` | Click the SAML button, type `admin` at `saml.test` | You land on the tree's dashboard as admin. Then grep the tree's SimpleSAMLphp log (location from `logging.handler` / `loggingdir` in the tree's `config/saml/config/config.php`) for `Processing response as unsolicited`. Any hit during this SP-initiated login is a **product finding**, recorded, not fixed. |
| 4 | same | Type `no-such-user-zz` | The tree refuses the login, and nobody is logged in. |
| 5 | `https://saml.test/` | "Sign in to <tree>", type `admin` | You land logged in to the tree. **If this fails, record it, stop working on this flow and carry on** (§6.3). |
| 6 | `https://saml.test/sp/` | "Log in at <tree>", log in at the tree | The result page shows `Flow: SP-initiated`, `Issuer: https://<host>/saml/saml2/idp/metadata.php`, the username, and `Signed: yes`. |
| 7 | `https://saml.test/` | "Start at <tree>'s IdP" | The result page shows `Flow: IdP-initiated`. |

Clear the tree session (log out) and the SP session between checks.

- [ ] **Step 4: Check that unlinking one tree leaves the other working**

Run `ohrm saml unlink king`. Then confirm that `ohrm saml status` shows `queen  ok`, that `https://saml.test/` lists only queen, and repeat check 6 on queen.

- [ ] **Step 5: Unlink queen and compare both trees with their snapshots**

Run `ohrm saml unlink queen`. Then run the Task 6 Step 5 diffs for both trees.
Expected:
- `git-same`, `exclude-same` and `certdir-same` for both;
- `db.txt` the same, except the `ohrm_saml_user_identity` count. That count may grow by one row per user who logged in through SAML (spec §3).

- [ ] **Step 6: Check the opt-in and nginx guarantees (§6.8 checks 1 and 2)**

Run:
```bash
docker-compose config --services | grep -x saml; echo "exit=$?"
ohrm saml down && docker restart dev_nginx && sleep 2
curl -sk -o /dev/null -w '%{http_code}\n' https://queen.test-webubuntu83.orangehrmdev.com/
mv config/nginx/virtual-servers/saml.conf /tmp/saml.conf.off && docker exec dev_nginx nginx -t && docker exec dev_nginx nginx -s reload && mv /tmp/saml.conf.off config/nginx/virtual-servers/saml.conf && docker exec dev_nginx nginx -s reload
utils/tests/ohrm-saml-test.sh && utils/tests/ohrm-shell-test.sh && utils/tests/ohrm-build-test.sh
```
Expected:
- `exit=1`;
- `200` or `302` from queen;
- `nginx -t` passes without the block;
- every test suite passes.

- [ ] **Step 7: Commit, then report**

```bash
git add README.md config/nginx/cert/README.md
git commit -m "Document the SAML test container"
```

Report a table of checks 1 to 9 per tree, with pass or fail. List product findings separately: the unsolicited warning in check 3, and anything from check 5. Don't fix them.
