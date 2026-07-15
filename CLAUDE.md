# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is **not** the OrangeHRM application. It is a Dockerized development/test environment that provisions the web servers, databases, message queues, and proxy needed to run OrangeHRM locally. Application source code is mounted into containers from `./html/OHRMStandalone/{OPENSOURCE,TEST,VAS}` (all gitignored — that directory only tracks its own `.gitignore` and the `OHRMStandalone` placeholder).

Architecture (see `./utils/doc-helpers/architecture_diagram.png`):
- **Proxy layer**: `nginx` container, terminates TLS on host port 443, reverse-proxies to web containers by virtual host (configs in `config/nginx/virtual-servers/*.conf`).
- **Web layer**: one container per PHP version/OS combo (e.g. `web56`, `web71`...`web82rh`, `ubuntuweb83`), each on a fixed static IP in the `10.5.0.0/16` `ohrmdevnet` bridge network. Each mounts the shared `./html` tree plus its own PHP/Apache config from `config/<name>/`.
- **Database layer**: MySQL/MariaDB/Oracle/MongoDB/MSSQL containers on `10.5.1.x`, phpMyAdmin at `10.5.2.2`.
- **Messaging**: RabbitMQ containers on `10.5.4.x`.

## Common commands

Start the default/basic environment (PHP 5.6/7.1/7.2, nginx, phpMyAdmin, RabbitMQ, MySQL 5.5, MariaDB 10.2):
```
docker-compose up -d
```

Start a custom combination of containers interactively (menu-driven picker over `custom-compose/*.yml`):
```
php env-start.php
```
This requires the `docker` service to be active on the host and drives selection via the CLImate library vendored under `utils/climate/`.

Start specific custom containers directly (equivalent to what `env-start.php` generates):
```
docker-compose -f docker-compose.yml -f ./custom-compose/<file>.yml up -d
```
Available custom compose files live in `custom-compose/` (e.g. `web71.yml`, `mariadb103.yml`, `db55.yml`, `ldap.yml`, `mongodb.yml`, `oracle11.yml`, `mssql-2017.yml`, `xhgui.yml`, `rabbitmq*.yml`, `db*.yml`).

Revert from a custom environment back to the basic one:
```
docker-compose up -d --remove-orphans
```

Install PHP dependencies inside a web container (containers don't have `allow_url_fopen` enabled by default):
```
docker exec -it <container_name> php -d allow_url_fopen=on /usr/local/bin/composer install
```

### Tests (Codeception)

Tests in this repo verify the *environment itself* (e.g. "is the right PHP/Node/git version installed in container X", "is Apache running") — they are not application tests.

```
composer install                        # installs codeception
php vendor/bin/codecept run unit        # container/tooling checks, e.g. tests/unit/WebContainer71Cest.php
php vendor/bin/codecept run functional
php vendor/bin/codecept run acceptance
```
Run a single test/Cest:
```
php vendor/bin/codecept run unit WebContainer71Cest
php vendor/bin/codecept run unit WebContainer71Cest:checkPHPVersion
```
Unit tests generally shell out to `docker inspect`/`docker exec` against already-running containers (see `tests/unit/*Cest.php`), so the relevant containers must be up first (`docker-compose up -d`) before running them.

## Working with container configs

- Per-web-container Apache/PHP config lives under `config/<container>/` (basic containers) or `custom-compose/config/<container>/` (custom containers) — e.g. `config/web82rhel8/apache2/sites-available`, `config/web82rhel8/php/custom_php.ini`.
- To change PHP settings for a running basic container, edit `./config/<WEB_CONTAINER>/php/custom_php.ini` then reload Apache inside that container — no rebuild needed since these are bind-mounted.
- nginx virtual host routing rules are in `config/nginx/virtual-servers/*.conf`; each maps a hostname (e.g. `*.test-web71.orangehrmdev.com`) to the corresponding web container's static IP.
- Container static IPs, host-exposed ports, and PHP versions are documented in the container table in `README.md` — check it before adding a new service to avoid IP/port collisions.
- Enterprise vs opensource vs VAS instances are distinguished only by document root inside `html/OHRMStandalone/{TEST,OPENSOURCE,VAS}` and by hostname pattern (`*.test-web*` vs `*.os-web*`), not by separate containers.

## Adding a new container version

New DB/web/queue versions are typically added as a service block appended directly to `docker-compose.yml` (for versions meant to be part of the default/basic stack) or as a new file under `custom-compose/` (for opt-in versions), each needing: a fixed IP in `ohrmdevnet`, a unique `container_name`, and any config bind-mounts under `config/` or `custom-compose/config/`. Check recent commits (`git log`) for examples of this pattern when adding one — it's a frequent kind of change in this repo.

## Branches build the actual Docker images (separate from `master`)

`master` (this checkout) only orchestrates *pre-built* images — e.g. `orangehrm/orangehrm-environment-images:dev-7.1-centos-orange`, `orangehrm/dev-environment:rhel8-php8.2-latest` — referenced in `docker-compose.yml`/`custom-compose/*.yml`. The Dockerfiles that build those images live on **separate, long-lived branches**, one per image variant: `php-7.1-centos-orange`, `php-8.2-rhel-8`, `php-8.2-rhel-9`, `php-7.4-ubuntu-20.04`, `php-8.3-ubuntu-24.04`, etc. (`git branch -a` for the full list). Each such branch has its own unrelated file layout centered on `docker-image/Dockerfile` (plus `docker-image/supervisord.conf`, `docker-image/config/...`) rather than the compose-orchestration layout on `master`.

This is a legacy pattern from Docker Hub's old "Automated Builds" feature, which mapped one source branch to one image tag (Hub couldn't build multiple Dockerfiles from subdirectories of a single branch well at the time). Consequences worth knowing:
- These image-build branches never merge back into `master` — don't expect `git log master..origin/php-7.1-centos-orange` to be mergeable/relevant to compose work, and don't treat them as stale feature branches to clean up.
- A fix needed across multiple image variants (e.g. an OS package fix) has to be repeated/cherry-picked onto each affected branch individually — there's no shared base to patch once.
- If a task is actually about changing what's *inside* an image (not which image is referenced/how it's composed), the work happens on the corresponding `php-*` branch, not on `master`.
