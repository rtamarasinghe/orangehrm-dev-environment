# SAML test container: design

Status: **draft for approval**, 2026-11-07. It replaces the paused draft
`2026-11-03-saml-test-container-design-draft.md`, which can be deleted once this is approved.

Decisions are labelled. **User** means the user decided it. **Claude** means it is Claude's
call, open to change during review. Anything not labelled is a verified fact or a constraint.

## 1. Intent

Testing SAML against a local OrangeHRM tree today means hand-building an SP or an IdP each time.
The SEC-134 round trip (MR !4477) needed a throwaway SP built for the occasion.

The goal is a permanent, opt-in SAML service in the `~/web` compose setup. A developer starts it
on demand, links any tree to it with one command, tests SAML logins in both directions, and then
unlinks the tree so that it is exactly as it was before.

Trees: any working copy under the TEST source path, for example `trunk`, `ng`, `king`, `queen`,
`rook`, `bishop`, `knight`, `pawn`. A slug matches `^[a-z0-9]+$`.

## 2. Goals

1. **OrangeHRM as SP, container as IdP.** This is the usual customer setup, with Okta as the
   typical IdP. The tree's login page shows a SAML button. The user signs in at the container
   and lands back in the tree, logged in. **(User)**
2. **OrangeHRM as IdP, container as SP.** This is the SEC-134 path: `orangeauth` `External.php`,
   then `seamlessLogin?ReturnTo=<resume URL>`, then the tree's login, then
   `IDPUtil::initiateSMALIDPRedirect()`, then resume, then a `SAMLResponse` POST to the
   container. **(User)**
3. **SP-initiated and IdP-initiated** logins in both directions. **(User)**
4. **Cross-site, like a real Okta.** The container is on a different site from the trees, so
   the browser applies the same cookie rules as with a real external IdP. **(User)**
5. **Any username at the test IdP.** The container's IdP sign-in page asks for a username only,
   with no password, and asserts whatever is typed. This lets a developer sign in as any user of
   any tree, and test the failure path with a username the tree doesn't have. **(User)**
6. **Several trees linked at once**, each with its own entity IDs. **(Claude)**

## 3. Non-goals

- Single logout.
- Edge cases with signed or encrypted assertions. The container signs as a normal IdP would and
  offers no switches for unsigned, wrongly signed or encrypted messages.
- Anything that needs a public URL.
- Opensource trees (`*.os-webubuntu83…`). The SAML plugin is enterprise-only. **(Claude)**
- Removing the activity that test logins leave behind. `unlink` restores configuration, not
  activity. **(Claude)** The activity left behind in the tree is:
  - login history rows;
  - first-dashboard-load rows;
  - `SimpleSAMLphp_kvstore` rows;
  - one `ohrm_saml_user_identity` row per user who logged in through SAML. The foreign key is
    `ON DELETE SET NULL`, so after `unlink` these rows remain with `provider_id = NULL`.

## 4. Anti-goals

These would make the work a failure even if every flow works.

- `docker-compose up -d` starts the container. It must stay off unless asked for.
- nginx fails to start on a machine where SAML setup never ran, or while the container is down.
  nginx fronts every tree, so this would take every tree down.
- `unlink` leaves the tree different from how `link` found it, or deletes something that `link`
  did not create.
- A generated private key or certificate is committed to either repo, or shows up as an
  untracked file in a tree's `git status`.
- The container hides a real product problem by being more lenient than a real IdP. The
  same-site shortcut was rejected for this reason (goal 4).

## 5. Constraints

- **Host tooling.** The host has no PHP. Host Python is 3.9 without `lxml`. Any SAML processing,
  signing or metadata work runs in a container. The host has `openssl`, `mkcert`
  (`/opt/homebrew/bin/mkcert`, CA already created) and Docker.
- **Host architecture.** The host is Apple Silicon. The container image must run natively on
  arm64 and also build on amd64 Linux.
- **Compose layout.** Opt-in services live in `custom-compose/<name>.yml` with config under
  `custom-compose/config/<name>/` (`ldap.yml`, `xhgui.yml`). `docker-compose.override.yml` is
  local and parks unused services under a `disabled` profile.
- **IP address.** The service needs a fixed address in `ohrmdevnet` (`10.5.0.0/16`). In use in
  `10.5.2.x`: `.1` nginx, `.2` phpMyAdmin, `.3` RabbitMQ, `.4` and `.5` LDAP, `.6` RabbitMQ RHEL.
  `10.5.2.7` is free in every compose file. **(Claude: use `10.5.2.7`, and add it to the README
  container table.)**
- **nginx.**
  - nginx 1.14 terminates TLS on host port 443.
  - `nginx.conf` includes `conf.d/virtual-servers/*.conf`. That folder is bind-mounted from
    `config/nginx/virtual-servers/`.
  - Certificates live in `config/nginx/cert/<vhost>/` (bind-mounted at `/etc/nginx/cert`).
    `*.pem` is gitignored there. `config/nginx/cert/README.md` describes the mkcert recipe.
  - nginx refuses to start if any included server block names a missing certificate file.
  - `nginx.conf` sets `Strict-Transport-Security`, `Content-Security-Policy` and other headers at
    the `http` level. A new server block that adds no headers of its own inherits them.
- **Name resolution.** Hostnames resolve only through `/etc/hosts`. `utils/sync-dev-hosts.sh`
  shows the house style for adding lines: list what is missing, ask, then `sudo tee -a`.
- **`ohrm` command.** `utils/ohrm-shell.sh` hands `build` to `utils/ohrm-build.sh` (line ~243).
  Both scripts have a header comment that doubles as `--help`, environment overrides
  (`OHRM_WEB_CONTAINER`, `OHRM_TEST_SRC_PATH`, `OHRM_DB_PASS`), an `OHRM_DRY_RUN=1` mode, and a
  test script in `utils/tests/`.
- **Tree databases.** The database server is `dev_mariadb_101115` (root password `1234`). A
  tree's app database name is in the `dsn` of its `symfony/config/databases.yml`. The passwords
  in that file are encrypted, so scripts connect as root through the DB container, as
  `utils/ohrm-tree.sh` does.
- **Comments** in new code follow the user's rule (`~/.claude/rules/code-comments.md`): current
  contract and invariants only, no history.

## 6. Design

### 6.1 Address and TLS

- **Hostname:** `saml.test`. It is on a different site from `orangehrmdev.com`, and `.test` is
  reserved, so it never clashes with a real site. **(User: separate site. Claude: the name.)**
- **Certificate:** mkcert, kept in `config/nginx/cert/saml/` (gitignored by the existing `*.pem`
  rule). The browser used for testing must trust the mkcert CA. Playwright runs use
  `ignoreHTTPSErrors`.
- **nginx:** one server block for `saml.test` proxies to `http://10.5.2.7`. It sets
  `X-Forwarded-Proto` and `Host` so SimpleSAMLphp builds `https://saml.test/…` URLs.
- **The block must not break nginx** (anti-goal). On a machine where the certificate doesn't
  exist, the block must not be included. **(Claude: commit the block outside
  `virtual-servers/`, and have the one-time setup copy it in, after the certificate exists,
  under a gitignored name. The builder may choose another mechanism that meets the
  constraint.)**
- **While the container is down,** requests to `saml.test` get a 502 and nginx keeps running.
  A literal IP in `proxy_pass` is not resolved at start.
- **`/etc/hosts`:** one line, `127.0.0.1 saml.test`, added once with sudo after a confirmation
  prompt, in the style of `sync-dev-hosts.sh`.
- **No nginx network alias for `saml.test`.** Neither direction makes a server-to-server call:
  metadata travels through files and database rows, and every SAML message goes through the
  browser. **(Claude)**

### 6.2 The container

- **Software:** SimpleSAMLphp **2.4.x**, the version the trees use (`simplesamlphp/simplesamlphp`
  `2.4.1` in `symfony/composer.json`). The image is built locally from the official multi-arch
  PHP image, with the SimpleSAMLphp version pinned. No third-party SAML image. **(Claude)**
- **One install, both roles:** a hosted IdP and an SP auth source.
- **Compose:** `custom-compose/saml.yml`, config under `custom-compose/config/saml/`, container
  name `dev_saml`, IP `10.5.2.7`. No host port is published; all traffic comes through nginx.
  **(Claude)**
- **Container keys:** the container's own IdP and SP signing key pair is generated on first
  setup and kept in a gitignored folder under `custom-compose/config/saml/`. The keys are reused
  across restarts, so linked trees stay valid. **(Claude)**
- **The container's own session cookie** is `SameSite=None; Secure`. The container receives a
  cross-site POST from the tree in goal 2, and it must not fail for reasons of its own.
  **(Claude)**
- **Per-tree registration is files on a bind mount,** for example
  `custom-compose/config/saml/trees/<tree>/` (gitignored). `link` and `unlink` work while the
  container is down, and the container reads the current set at request time. **(Claude)**

### 6.3 Container as IdP (tree is SP)

- **Sign-in page:** one text field for the username and no password field. It lists the last
  few usernames used, as one-click buttons. Recent usernames are kept in a cookie or browser
  storage on `saml.test`. **(User: any username. Claude: the recent list.)**
- **What it asserts:** NameID = the username typed. One attribute, named `username`, with the
  same value. `link` sets the tree's IdP-type provider row `username_key` to `username` to match.
  **(Claude)**
- **The tree matches users by the asserted username only.** The stored SAML identity is never
  compared (security memory `sso-identity-binding-check-is-dead`). An unknown username takes the
  tree's own failure path. That is the failure test, not a container fault.
- **IdP-initiated:** an apps page at `https://saml.test/` lists each linked tree with a
  "Sign in to <tree>" link. The unsolicited response carries the `RelayState` the tree's SP
  expects: `https://<tree host>/openidauth/openIdCredentials?openIdProvider=saml_<IdP row id>`
  (from `authsources.php`). `link` records the row id for this.
- **Expected to work, unverified end to end.** In SimpleSAMLphp 2.4.1, `enable_unsolicited`
  defaults to true. With exactly one active IdP-type row, the SP's configured `RelayState`
  overrides the one in the response. That URL passes `checkURLAllowed` once `domain.name`
  equals the tree's host.
- **Build order:** confirm this flow early, with the first working IdP. If it fails, report the
  failure, leave this one flow out, and build the rest. Never patch the tree to make it pass.
  **(Claude)**

### 6.4 Container as SP (tree is IdP)

- **SP page** at `https://saml.test/sp/`: one "Log in at <tree>" button per linked tree
  (SP-initiated).
- **IdP-initiated:** the apps page also shows, for each tree, the tree's IdP-initiated URL:
  `https://<tree host>/saml/saml2/idp/SSOService.php?spentityid=<urlencoded container SP entity
  ID>`.
- **Result page:** after the ACS checks, it shows the flow (SP- or IdP-initiated), the tree, the
  NameID, the issuer, which parts were signed, and every attribute received. A failed check
  shows which check failed and why. **(Claude)**
- **ACS checks:** reuse the throwaway SP's list: status; `Destination` and `Issuer`; exactly one
  unencrypted Assertion; the XML signature on the Response and/or Assertion against the tree's
  certificate; `InResponseTo` against the SP's own pending requests; Audience, Recipient and
  expiry. SimpleSAMLphp's SP does most of this itself. Whatever it doesn't do, the result page
  must still report.

### 6.5 Commands

All commands go through `ohrm saml …`. `ohrm-shell.sh` hands `saml` to a new
`utils/ohrm-saml.sh`, as it does for `build`. The script follows the house style: header comment
as `--help`, environment overrides, `OHRM_DRY_RUN=1`, and `utils/tests/ohrm-saml-test.sh`.
`ohrm --help` and the usage line list `saml`.

| Command | What it does |
|---|---|
| `ohrm saml up` | First run only: generates the mkcert certificate, installs the nginx block and reloads nginx, adds the `/etc/hosts` line (asks before sudo), and generates the container keys. Every run: builds the image if needed and starts the container. Never starts any other service. |
| `ohrm saml down` | Stops and removes the container. Leaves linked trees, certificates and keys in place. |
| `ohrm saml status` | Shows whether the container is running, whether `https://saml.test/` answers, and each linked tree with a check that its rows and files are still present. |
| `ohrm saml link <tree>` | See 6.6. |
| `ohrm saml unlink <tree>` | See 6.7. |

**(Claude: first-time setup folded into `up` instead of a separate `setup` command.)**

### 6.6 `ohrm saml link <tree>`

**(User: the agreed behaviour. Claude: the details.)**

1. Checks that the tree exists, its database is reachable, and the tree is not already linked.
   Linking an already linked tree changes nothing and says so. **(Claude)**
   - **Git worktree trees are refused.** Their `info/exclude` is shared with the main checkout,
     so `unlink` could not restore it per tree. Every current tree has its own `.git`
     (checked 2026-11-07).
   - **A tree that already has an active IdP-type row** is linked anyway, with a warning. The
     login page then offers more than one SAML provider.
2. Records the starting state in a state file for the tree, before changing anything:
   - the current `domain.name` value in `ohrm_config`;
   - whether `saml.prod.orangehrm-idp.pem` and `.crt` exist in
     `symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert/`;
   - which of the needed `.git/info/exclude` lines already exist.
3. Sets `domain.name` to `<tree>.test-webubuntu83.orangehrmdev.com`.
4. Generates the tree's IdP key and self-signed certificate, only if they are missing, and
   adds the exclude lines, only if they are missing.
5. Adds two `ohrm_saml_provider` rows, both named **`SAML test container`**, both active:
   - **IdP-type row:** `metadata` = the container's IdP metadata; `username_key` = `username`.
     This row makes the SAML button appear on the tree's login page.
   - **SP-type row:** `metadata` = the container's SP metadata. Four
     `ohrm_saml_provider_attribute` rows map tokens 2, 3, 5 and 6 to `username`, `firstName`,
     `email` and `employeeId`, as the throwaway SP did.
   - The new row ids go into the state file.
6. Writes the tree's registration for the container: the tree's IdP metadata (entity ID, SSO
   URL, certificate) and the tree's SP metadata (entity ID, ACS URL).
   - Tree IdP entity ID: `https://<tree host>/saml/saml2/idp/metadata.php`.
   - Tree SP entity ID: `<tree host>/saml/module.php/saml/sp/metadata.php/orangehrm-sp`. It
     has **no scheme**, as `authsources.php` builds it.
7. Clears whatever cache would otherwise keep the old `domain.name`. **(Unverified: whether one
   applies.)**

If any step fails, `link` undoes the steps already done, using the same rules as `unlink`, and
exits non-zero. **(Claude)**

### 6.7 `ohrm saml unlink <tree>`

**(User: full restore. Claude: the edge cases.)**

- Puts back the recorded `domain.name`.
- Deletes the tree's IdP key and certificate only if `link` created them. Removes only the
  exclude lines that `link` added.
- Deletes only the provider rows whose ids are in the state file, and their attribute rows.
- Removes the tree's registration from the container, then deletes the state file.
- **Database reloaded since `link`:** skips whatever is already gone, and still cleans up the
  files and the registration.
- **No state file:** stops with a message and changes nothing.
- **Container down:** works anyway. The container is file-driven.

### 6.8 What shows that it works

Run on **king**, then on **king and queen** linked at the same time. **(User)** Both are on
`develop` and include the SEC-134 merge (`0c2582a3e7e`). The activity listed in section 3 stays
in both trees afterwards. That is accepted.

1. `docker-compose up -d` does not start `dev_saml`.
2. nginx starts and serves trees on a clean checkout where `ohrm saml up` has never run, and
   also while `dev_saml` is stopped.
3. **Container as IdP, SP-initiated:** the tree's login page shows the SAML button. Typing
   `admin` at `saml.test` lands on the tree's dashboard as admin.
4. **Same, unknown username:** the tree refuses the login and nobody is logged in.
5. **Container as IdP, IdP-initiated:** from the apps page, you land logged in to the tree.
6. **Container as SP, SP-initiated:** you log in at the tree and land on the result page, which
   shows the expected NameID, issuer and attributes.
7. **Container as SP, IdP-initiated:** the tree's `SSOService.php` URL lands on the result page.
8. **`unlink`:**
   - `domain.name`, the provider rows and the attribute rows match their state before `link`;
   - the tree's `git status` matches its state before `link`;
   - `.git/info/exclude` matches its state before `link`.
9. `utils/tests/ohrm-saml-test.sh` passes in dry-run mode.

**Check 3 can pass while hiding a cookie problem.**

- The trees' SimpleSAMLphp config sets `session.cookie.samesite` to `null`
  (`config/saml/config/config.php`). Browsers then treat the cookie as `Lax`, so the
  cross-site `SAMLResponse` POST from `saml.test` to the tree may arrive without it. Chrome
  still sends such a cookie within two minutes of it being set.
- When the tree's SP can't load the request state named by `InResponseTo`, SimpleSAMLphp 2.4.1
  logs a warning and processes the response as unsolicited. The login still succeeds. The
  `InResponseTo` binding is lost silently.
- **So check 3 also reads the tree's SimpleSAMLphp log** for the "processing response as
  unsolicited" warning. If it appears in an SP-initiated login, that is a product finding to
  report. It is not a container fault to work around. **(Claude)**
- Check 6 doesn't depend on the tree's cookies. Its only cross-site POST goes to `saml.test`.

## 7. Prior art to reuse

The SEC-134 throwaway SP is in `html/OHRMStandalone/TEST/_work/saml-sp-throwaway/`:

- `index.php`: the ACS checks and the result page;
- `register-sp.sql`: the provider and attribute row shapes;
- `README.md`: what it changed on rook, and the teardown.

Reuse its code and lessons. Don't extend it in place.

The throwaway's changes are still on rook. Its own teardown removes them. Whether to run that
before linking rook is the user's call, and is outside this work.

## 8. Left to the builder

- File layout inside `custom-compose/config/saml/`, the image's Dockerfile, and how
  SimpleSAMLphp is configured (module versus plain PHP pages for the sign-in page and the result
  page).
- The container's own entity IDs and URL paths, apart from the pages named above.
- How tree and container metadata are produced: generated from a template, or fetched from a
  running tree from inside a container.
- The state file format and location, provided it is gitignored and per tree.
- How the nginx block is kept out of nginx until its certificate exists, within the constraint
  in 6.1.
- Whether the inherited `http`-level nginx headers (CSP in particular) need overriding in the
  `saml.test` block for the auto-submitted POST forms to work.

## 9. Verified facts (trunk and `~/web`, 2026-11-07)

- `getSAMLProviderCount()` and `getFirstEnabledSAMLProvider()` default to the IdP type. An
  SP-type row doesn't change the login button or the `authsources.php` single-provider fallback.
- `authsources.php` picks the remote IdP from `$_SESSION['providerid']`. If that is not set and
  exactly one active IdP-type row exists, it uses that row. `RelayState` is built from
  `domain.name`.
- `saml20-idp-remote.php` loads every active IdP-type row's `metadata`.
- `saml20-idp-hosted.php` builds the tree's IdP entity ID from `domain.name` and loads the key and
  certificate named by `IDPUtil::IDP_PRIVATE_KEY` / `IDP_CERTIFICATE`.
- `config.php`: `trusted.url.domains` is `[]`; `session.cookie.secure` is `true`;
  `session.cookie.samesite` is `null`; `store.type` is `sql`.
- `ohrm_saml_provider` columns: `id, name, type, metadata, username_key, status, file_name,
  file_type, file_size, provider_logo`. Attribute mapping is in `ohrm_saml_provider_attribute`
  (`provider_id, token_id, claim_name`).
- `domain.name` is `localhost` on a fresh tree. Other readers of it are mostly links in outgoing
  emails, so setting it to the tree's hostname is safe on a dev tree.
- The tree's IdP cert folder holds only `.htaccess`, and git does not ignore it.
- `sfWebRequest::getUriPrefix()` trusts `X-Forwarded-Host` and `-Proto`. SimpleSAMLphp builds
  its base URL from `HTTP_HOST`, `SERVER_PORT` and `$_SERVER['HTTPS']`.
- Loading the SimpleSAMLphp configuration from sf1 CLI code needs `sfContext::createInstance()`
  first, because it reads `saml_secret` from the database.
- The SAML admin UI is HR Administration → Configurations → Authentication → SAML. It is
  read-only for Global Admin, and ConfigAdmin can edit.
