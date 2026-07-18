# Building the native arm64 OrangeHRM dev image (Apple Silicon)

Rebuild runbook for the `ubuntuweb83` container's image
(`orangehrm/dev-environment:ubuntu24.04-php8.3-latest`) as a **native arm64** image, so it
runs natively on Apple Silicon instead of under Docker Desktop's amd64 emulation.

The official `-latest` tag is published **amd64-only**. We build a native arm64 image under a
distinct **`-arm64`** tag and point the `ubuntuweb83` service at it via a gitignored compose
override, so the two coexist (no shadowing) and `docker-compose up -d` works unchanged.

> The arm64 fixes are **already committed** to the forks below, so a rebuild needs **no manual
> Dockerfile edits and no ioncube download** — just clone and build.

---

## TL;DR — fast rebuild (after a Docker reset)

If the three fork repos are already cloned (see paths under [Layout](#layout)), just run the
builds and bring it up. **Never pass `--pull`** (it would fetch the official amd64 base over the
local arm64 one).

```bash
PROD=~/src/orangehrm-prod-environment
TEST=~/src/orangehrm-test-environment
DEV=~/src/orangehrm-dev-environment          # image-build checkout (NOT the compose repo)
TAG=ubuntu24.04-php8.3-latest-arm64

# 1) prod  (adds the aarch64 ioncube loader)
docker build -t orangehrm/prod-environment:$TAG "$PROD/docker-image"

# 2) test  (drops the dead WANdisco SVN repo; FROM via ARG BASE_IMAGE)
docker build --build-arg BASE_IMAGE=orangehrm/prod-environment:$TAG \
  -t orangehrm/test-environment:$TAG "$TEST/docker-image"

# 3) dev   (arch-clean; FROM via ARG BASE_IMAGE)
docker build --build-arg BASE_IMAGE=orangehrm/test-environment:$TAG \
  -t orangehrm/dev-environment:$TAG "$DEV/docker-image"

# 4) run (from the compose repo, ~/web) — override auto-loads
cd ~/web && docker-compose up -d ubuntuweb83
```

First build of `prod` takes ~8–10 min (compiles PHP extensions from source); `test` a few
minutes; `dev` is quick. Rebuilds reuse cached layers.

---

## Background — why 3 repos

The dev image is a thin wrapper over a **3-repo inheritance chain** (all on branch
`php-8.3-ubuntu-24.04`). Two layers had arm64 blockers, both fixed on the forks:

| # | Repo (fork: `rtamarasinghe/…`) | Adds | arm64 fix (committed) |
|---|---|---|---|
| 1 | `orangehrm-prod-environment` | `FROM ubuntu:24.04`, PHP 8.3, MariaDB client, pecl exts, **ioncube** | aarch64 ioncube loader + arch-aware `COPY` (by `TARGETARCH`) |
| 2 | `orangehrm-test-environment` | SVN, nvm/Node, wkhtmltopdf, composer, phpunit, phan | dropped defunct **WANdisco SVN** apt repo → stock Ubuntu `subversion`; `FROM` via `ARG BASE_IMAGE` |
| 3 | `orangehrm-dev-environment` | xdebug, infection, supervisor, memcached | arch-clean; `FROM` via `ARG BASE_IMAGE` only |

Everything else was already arm64-capable (`ubuntu:24.04`, stock `php8.3-*`, MariaDB
`mariadb_repo_setup`, `apt install wkhtmltopdf`, nvm Node, source-compiled pecl exts).

Each child's `FROM` is `ARG BASE_IMAGE`-parametrized: the **default** stays the official tag
(so amd64/upstream CI is unaffected), and the local build passes `--build-arg BASE_IMAGE=…-arm64`
to chain onto the arm64 parent. Build order matters — **prod → test → dev** — because each build
resolves `FROM` from the locally-built parent.

<a name="layout"></a>
## Layout

| Role | Path | Branch |
|---|---|---|
| prod image source | `~/src/orangehrm-prod-environment` | `php-8.3-ubuntu-24.04` |
| test image source | `~/src/orangehrm-test-environment` | `php-8.3-ubuntu-24.04` |
| dev image source | `~/src/orangehrm-dev-environment` | `php-8.3-ubuntu-24.04` |
| **compose repo** (run + override) | `~/web` | `ruchira-dev` |

The compose repo (`~/web`) and the dev **image** source are checkouts of the *same* fork on
*different branches* — keep them in separate directories.

---

## From a clean machine (repos not cloned yet)

```bash
mkdir -p ~/src && cd ~/src
for r in orangehrm-prod-environment orangehrm-test-environment orangehrm-dev-environment; do
  git clone -b php-8.3-ubuntu-24.04 git@github.com:rtamarasinghe/$r.git
  git -C $r remote add upstream git@github.com:orangehrm/$r.git
  git -C $r remote set-url --push upstream no_push   # fetch-only upstream
done
```

Then run the four steps in the [TL;DR](#tldr--fast-rebuild-after-a-docker-reset).

---

## Step 4 detail — the compose override

`~/web/docker-compose.override.yml` (Compose auto-loads it; it's gitignored) already exists and
carries other local tweaks (parks unused services under a `disabled` profile; overrides
`db101115` to multi-arch `mariadb:10.11.15` for arm64). **Merge** the `ubuntuweb83` image stanza
into it — do **not** overwrite the file — so `docker-compose up -d` runs the arm64 image unchanged:

```yaml
services:
  # ...existing profile/db101115 overrides stay as-is...

  # run ubuntuweb83 as the locally-built native arm64 image (else it uses the
  # official amd64 tag and runs under emulation)
  ubuntuweb83:
    image: orangehrm/dev-environment:ubuntu24.04-php8.3-latest-arm64
```

Without this stanza the base `docker-compose.yml`'s `ubuntuweb83.image`
(`…-php8.3-latest`, amd64-only) is used → emulation.

---

## Verify

```bash
# image is arm64
docker image inspect orangehrm/dev-environment:ubuntu24.04-php8.3-latest-arm64 \
  --format '{{.Architecture}}'                       # -> arm64

# no emulation errors in the running container
docker logs dev_web_83_ubuntu 2>&1 | grep -iE "exec format|qemu|rosetta"   # -> (nothing)

# runtime toolchain
docker exec dev_web_83_ubuntu bash -c '
  uname -m                                   # aarch64
  php -v | head -1                           # PHP 8.3.6
  php -m | grep -iE "ioncube|xdebug"         # both present, ioncube loads w/o error
  svn --version --quiet                      # 1.14.x (stock Ubuntu)
  wkhtmltopdf --version                      # 0.12.6
  apachectl -M | grep -iE "ssl|rewrite|headers|vhost_alias"
'
```

End-to-end: host an OrangeHRM instance under `~/web/html/OHRMStandalone/…`, load it via the
`ubuntuweb83` vhost, and confirm login + a PDF-generating page (exercises wkhtmltopdf).

---

## Gotchas / footguns

- **No `--pull`** on any of the three `docker build`s — it would refetch the amd64 base.
- The **`-arm64` suffix** means the local image and the official amd64 tag coexist, so a stray
  `docker pull` / `docker compose pull` / `--pull always` only touches the official tag, not your
  arm64 one. (A `docker system prune` can still evict any *unused* image by age — if that happens,
  just re-run the builds.)
- **ioncube RUN step** (prod Dockerfile): the loader dir `/usr/lib/php/20190902` must be
  `mkdir -p`'d and the steps `&&`-chained — a `;`-separated list masks a failed `cp` (exit status
  is the last command) and would build green with **no loader**. Always confirm with
  `php -m | grep -i ionCube`, not just a green build. (This is already fixed in the fork.)
- `TARGETARCH` is auto-set by BuildKit (`arm64` on the Mac); the Dockerfile's `*)` case fails the
  build if it's ever empty.
- These are all **local-only** images (no registry push). Publishing proper multi-arch manifest
  lists upstream (buildx + QEMU in CI) is a separate, later phase.
```
