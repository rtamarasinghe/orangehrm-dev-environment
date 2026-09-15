#!/usr/bin/env bash
#
# ohrm-tree.sh — provision an independent OrangeHRM working tree under
# html/OHRMStandalone/TEST/<slug>, so several bug fixes can run in parallel.
#
# A tree is a reusable SLOT, not a branch: it gets its own checkout, its own app
# and test databases, its own hostname, and its own frontend build artifacts.
# Branch inside it as often as you like.
#
#   ohrm-tree.sh new amber                 # provision (clone develop from trunk)
#   ohrm-tree.sh new amber --from 8.2.x    # provision off another ref
#   ohrm-tree.sh new amber --lean          # same, but skip node_modules
#   ohrm-tree.sh list                      # what exists, and is it wired up
#   ohrm-tree.sh build-vue amber           # rebuild symfony/web/vue-app  -> dist/
#   ohrm-tree.sh build-client amber        # rebuild symfony/web/client   -> build/
#   ohrm-tree.sh remove amber [--yes]      # DESTRUCTIVE: drops both DBs + the tree
#
# Routing needs no per-tree work: nginx's server_name regex and Apache's
# VirtualDocumentRoot already map <slug>.test-webubuntu83.orangehrmdev.com to
# TEST/<slug>/symfony/web, and the wildcard cert already covers it. Only DNS
# (/etc/hosts + the nginx container alias) is per-tree, and `new` does both.
#
# Everything that compiles runs in a container, never on the host:
#   composer      -> dev_web_83_ubuntu           (the host has no matching PHP)
#   vue-app build -> dev_web_83_ubuntu, Node 14  (native arm64)
#   client build  -> web83_client_build, Node 6  (emulated amd64; gulp 3.9 and
#                                                 node-sass have no arm64 build)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB_CTR="${OHRM_WEB_CONTAINER:-dev_web_83_ubuntu}"
DB_CTR="${OHRM_DB_CONTAINER:-dev_mariadb_101115}"
DB_USER="${OHRM_DB_USER:-root}"
DB_PASS="${OHRM_DB_PASS:-1234}"
DOMAIN="test-webubuntu83.orangehrmdev.com"
CTR_TEST_ROOT="/var/www/html/OHRMStandalone/TEST"
OVERRIDE="$REPO_ROOT/docker-compose.override.yml"
SOURCE_WC_DEFAULT="${OHRM_SOURCE_WC:-trunk}"

# Paths that are git-ignored in the source tree but are NOT app runtime state.
# Everything else that git ignores gets mirrored, because "ignored" is exactly the
# set of files the app needs and the clone does not bring: the generated Doctrine
# model classes alone live under a dozen separate gitignore rules
# (/symfony/lib/model/doctrine plus /symfony/plugins/*/lib/model/doctrine/Plugin*),
# and a tree missing any of them dies in sfContext::createInstance with an empty
# DaoException — web and phpunit alike. Curating that list by hand is how you get
# a tree that provisions cleanly and cannot boot.
MIRROR_SKIP=(
  'symfony/cache/*' 'symfony/log/*' 'upgrader/log/*' '.git/*'
  'symfony/_output/*' 'symfony/.phpunit.cache/*' '.playwright-mcp/*' '.review/*'
  'devTools/citra-cowork/_output/*' 'devTools/citra-cowork/.feedback-repo/*'
  'phpcs_report.xml'
)

log()  { printf '>> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

compose() {
  if docker compose version >/dev/null 2>&1; then (cd "$REPO_ROOT" && docker compose "$@")
  else (cd "$REPO_ROOT" && docker-compose "$@"); fi
}

# GNU sed and BSD sed spell -i differently and this machine has GNU sed ahead of
# /usr/bin on PATH, where `-i ''` reads '' as a filename and exits 2. Editing
# through a temp file works under either, and writing back with cat (not mv)
# keeps the target's ownership and mode — which matters for /etc/hosts.
edit_inplace() {
  local f="$1"; shift
  local t; t="$(mktemp)"
  sed "$@" "$f" > "$t" && cat "$t" > "$f"
  rm -f "$t"
}

# Mirrors docker-compose's ${OHRM_TEST_SRC_PATH:-./html/OHRMStandalone/TEST}.
test_src() {
  local v=""
  [[ -f "$REPO_ROOT/.env" ]] && v="$(grep -E '^OHRM_TEST_SRC_PATH=' "$REPO_ROOT/.env" | tail -n1 | cut -d= -f2- || true)"
  v="${OHRM_TEST_SRC_PATH:-${v:-$REPO_ROOT/html/OHRMStandalone/TEST}}"
  (cd "$REPO_ROOT" && cd "$v" && pwd)
}

require_slug() {
  [[ -n "${1:-}" ]] || die "no slug given"
  # nginx's server_name regex is [A-Za-z0-9]* — a hyphen or underscore produces a
  # tree that resolves to no vhost and 502s, with nothing else to show for it.
  [[ "$1" =~ ^[a-z0-9]+$ ]] || die "slug '$1' must match ^[a-z0-9]+\$ (no hyphen, underscore or dot)"
  (( ${#1} <= 20 )) || die "slug '$1' is too long (max 20)"
}

require_stack() {
  docker ps --format '{{.Names}}' | grep -qx "$WEB_CTR" || die "container $WEB_CTR is not running (docker-compose up -d)"
  docker ps --format '{{.Names}}' | grep -qx "$DB_CTR"  || die "container $DB_CTR is not running"
}

sql() { docker exec -e MYSQL_PWD="$DB_PASS" -i "$DB_CTR" mysql -u"$DB_USER" -N -B -e "$1"; }

db_exists() { [[ -n "$(sql "SHOW DATABASES LIKE '$1';")" ]]; }

# APFS clonefile: copy-on-write, so mirroring ~1.5GB of artifacts costs seconds
# and almost no disk. Falls back to a real copy on any filesystem without it.
mirror() {
  [[ -e "$1" ]] || { warn "source missing, skipped: $1"; return 0; }
  mkdir -p "$(dirname "$2")"
  if [[ -d "$1" ]]; then
    # `cp -R src dst` NESTS when dst already exists — a collapsed ignored
    # directory whose parent the clone already created lands as
    # lib/model/doctrine/doctrine/. Copying the contents merges instead.
    mkdir -p "$2"
    cp -c -R "$1/." "$2/" 2>/dev/null || cp -R "$1/." "$2/"
  else
    cp -c "$1" "$2" 2>/dev/null || cp "$1" "$2"
  fi
}

# Mirror every git-ignored path from the source tree except app runtime state.
# --directory collapses a wholly-ignored directory (node_modules, lib/model/doctrine)
# into one entry, so this is ~900 cp calls, not ~200k.
mirror_ignored() {
  local src="$1" dst="$2" lean="$3" p skip n=0
  while IFS= read -r p; do
    p="${p%/}"
    skip=0
    for pat in "${MIRROR_SKIP[@]}"; do
      # shellcheck disable=SC2053
      [[ "$p/" == $pat || "$p" == $pat ]] && { skip=1; break; }
    done
    (( skip )) && continue
    if (( lean )); then
      case "$p" in */node_modules) continue ;; esac
    fi
    mirror "$src/$p" "$dst/$p" && n=$((n+1))
  done < <(git -C "$src" ls-files --others --ignored --exclude-standard --directory)
  log "mirrored $n ignored path(s)"
}

# dbname= out of one top-level section of databases.yml.
yml_dbname() {
  awk -v want="$2" '
    /^[A-Za-z_]+:/ { sec=$0; sub(":.*","",sec) }
    sec==want && match($0, /dbname=[A-Za-z0-9_]+/) {
      print substr($0, RSTART+7, RLENGTH-7); exit
    }' "$1"
}

ctr_path() { printf '%s/%s\n' "$CTR_TEST_ROOT" "$1"; }
url()      { printf 'https://%s.%s\n' "$1" "$DOMAIN"; }

## ---------------------------------------------------------------------------
## new
## ---------------------------------------------------------------------------
cmd_new() {
  local slug="" from="develop" branch="" source_wc="$SOURCE_WC_DEFAULT" lean=0 do_db=1
  while (( $# )); do
    case "$1" in
      --from)   from="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --source) source_wc="$2"; shift 2 ;;
      --lean)   lean=1; shift ;;
      --no-db)  do_db=0; shift ;;
      -*)       die "unknown flag $1" ;;
      *)        slug="$1"; shift ;;
    esac
  done
  require_slug "$slug"; require_stack

  local root src dst
  root="$(test_src)"; src="$root/$source_wc"; dst="$root/$slug"
  [[ -d "$src/.git" ]] || die "source tree '$src' is not a git checkout"
  [[ -e "$dst" ]] && die "$dst already exists"

  local src_app src_test app_db test_db
  src_app="$(yml_dbname "$src/symfony/config/databases.yml" all)"
  src_test="$(yml_dbname "$src/symfony/config/databases.yml" test)"
  [[ -n "$src_app" && -n "$src_test" ]] || die "could not read dbname from $src/symfony/config/databases.yml"
  app_db="$slug"; test_db="test_$slug"

  # Never drop. This MariaDB holds long-lived databases with no tree behind them,
  # including restored customer datasets — a name collision is the caller's to resolve.
  if (( do_db )); then
    db_exists "$app_db"  && die "database '$app_db' already exists — pick another slug or pass --no-db"
    db_exists "$test_db" && die "database '$test_db' already exists — pick another slug or pass --no-db"
  fi

  log "source $source_wc ($src_app / $src_test) -> $slug ($app_db / $test_db)"

  # 1. Checkout. --local hardlinks the object store, so the 1GB .git is near-free
  #    while staying an independent repository.
  log "cloning checkout"
  local origin_url; origin_url="$(git -C "$src" remote get-url origin)"
  git clone --quiet --local "$src" "$dst"
  git -C "$dst" remote set-url origin "$origin_url"
  git -C "$dst" fetch --quiet origin --prune
  # git clone does not copy .git/info/exclude, so local-only ignore rules are lost
  # and files the source tree treats as ignored show up untracked in the clone.
  [[ -f "$src/.git/info/exclude" ]] && cp "$src/.git/info/exclude" "$dst/.git/info/exclude"
  if [[ -n "$branch" ]]; then
    git -C "$dst" checkout -q -B "$branch" "origin/$from" 2>/dev/null || git -C "$dst" checkout -q -B "$branch" "$from"
  else
    git -C "$dst" checkout -q -B "$from" "origin/$from" 2>/dev/null || git -C "$dst" checkout -q "$from"
  fi
  log "on branch $(git -C "$dst" rev-parse --abbrev-ref HEAD)"

  # 2. Gitignored runtime files.
  log "mirroring the source tree's git-ignored set (copy-on-write)"
  mirror_ignored "$src" "$dst" "$lean"

  # 3. Point this tree at its own databases, in every env block.
  edit_inplace "$dst/symfony/config/databases.yml" \
    -e "s/dbname=$src_test/dbname=$test_db/g" -e "s/dbname=$src_app/dbname=$app_db/g"
  log "databases.yml -> $(grep -c "dbname=$app_db\|dbname=$test_db" "$dst/symfony/config/databases.yml") dsn(s) rewritten"

  # 4. Databases. Dump and restore both stay inside the DB container, so ~500MB
  #    never crosses the docker boundary.
  if (( do_db )); then
    local charset cs coll
    charset="$(sql "SELECT CONCAT(DEFAULT_CHARACTER_SET_NAME,' ',DEFAULT_COLLATION_NAME) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$src_app';")"
    cs="${charset%% *}"; coll="${charset##* }"
    log "cloning database $src_app -> $app_db ($cs/$coll, a few minutes)"
    sql "CREATE DATABASE \`$app_db\` CHARACTER SET $cs COLLATE $coll;"
    # bash, not sh: dash has no pipefail, and without it a failed mysqldump is
    # masked by mysql's exit code and the clone silently lands half-empty.
    docker exec -e MYSQL_PWD="$DB_PASS" "$DB_CTR" bash -c \
      "set -o pipefail; mysqldump -u$DB_USER --single-transaction --routines --triggers --events '$src_app' | mysql -u$DB_USER '$app_db'"
    log "cloning database $src_test -> $test_db"
    sql "CREATE DATABASE \`$test_db\` CHARACTER SET $cs COLLATE $coll;"
    docker exec -e MYSQL_PWD="$DB_PASS" "$DB_CTR" bash -c \
      "set -o pipefail; mysqldump -u$DB_USER --single-transaction --routines --triggers --events '$src_test' | mysql -u$DB_USER '$test_db'"
  fi

  # 5. Composer runs in the container: the host has no matching PHP, and the
  #    tracked vendor autoloader is --no-dev and stale, so phpunit10 cannot even
  #    build a suite until this rewrites it.
  log "composer install (in $WEB_CTR)"
  docker exec -w "$(ctr_path "$slug")/symfony" "$WEB_CTR" \
    php -d allow_url_fopen=on /usr/local/bin/composer install --no-interaction --no-progress
  # autoload_files.php is tracked but inert; composer rewrites it every time and
  # the diff must never be committed.
  git -C "$dst" restore symfony/lib/vendor/composer/autoload_files.php 2>/dev/null || true

  # chmod the directories only: -R would mark the tracked .deleteme placeholders
  # executable and leave the tree permanently dirty.
  docker exec "$WEB_CTR" bash -c "mkdir -p '$(ctr_path "$slug")/symfony/'{cache,log} && chmod 0777 '$(ctr_path "$slug")/symfony/cache' '$(ctr_path "$slug")/symfony/log'"
  # composer marks vendor bin scripts executable; that is a mode-only diff on
  # tracked files and must not be left behind.
  git -C "$dst" diff --name-only --diff-filter=M | xargs -r git -C "$dst" checkout -- 2>/dev/null || true

  # 6. DNS, both sides.
  wire_dns "$slug"

  # 7. Smoke test. 401 is the login page, not a failure — but the status alone
  #    proves nothing: symfony serves its "Internal Error Occurred" page with a
  #    200, so the body has to be checked too.
  local body code
  body="$(curl -sk --max-time 30 -w '\n%{http_code}' "$(url "$slug")/" || true)"
  code="${body##*$'\n'}"
  if grep -qi "Internal Error Occurred" <<<"$body"; then
    warn "HTTP $code but the app returned its internal-error page — check $(ctr_path "$slug")/symfony/log/"
  else
    case "$code" in
      200|401|302) log "HTTP $code from $(url "$slug") — tree is serving" ;;
      *) warn "HTTP $code from $(url "$slug") — check the nginx alias and /etc/hosts" ;;
    esac
  fi

  printf '\n%s ready:\n  path %s\n  url  %s\n  dbs  %s, %s\n  test phpunit10 from %s/symfony inside %s\n\n' \
    "$slug" "$dst" "$(url "$slug")" "$app_db" "$test_db" "$(ctr_path "$slug")" "$WEB_CTR"
}

wire_dns() {
  local slug="$1" host="$1.$DOMAIN"
  if grep -qE "[[:space:]]${host//./\\.}([[:space:]]|\$)" /etc/hosts; then
    log "/etc/hosts already has $host"
  elif echo "127.0.0.1 $host" | sudo tee -a /etc/hosts >/dev/null 2>&1; then
    log "added $host to /etc/hosts"
  else
    # Non-interactive shells have no tty for the sudo prompt. Everything else
    # about the tree is finished and usable, so warn rather than abort — only
    # host-side name resolution is missing, and curl --resolve works without it.
    warn "could not add $host to /etc/hosts (sudo needs a terminal). Run:"
    warn "    echo '127.0.0.1 $host' | sudo tee -a /etc/hosts"
  fi
  # The nginx container alias is what lets OTHER containers resolve the host —
  # the Codeception api suite runs inside the web container and needs it.
  if grep -qF -- "- $host" "$OVERRIDE"; then
    log "docker-compose.override.yml already aliases $host"
  else
    log "adding nginx alias for $host and restarting nginx"
    local t; t="$(mktemp)"
    awk -v anchor="- trunk.$DOMAIN" -v new="          - $host" '
      { print }
      index($0, anchor) && !done { print new; done=1 }
    ' "$OVERRIDE" > "$t" && cat "$t" > "$OVERRIDE"
    rm -f "$t"
    grep -qF -- "- $host" "$OVERRIDE" \
      || die "could not insert the nginx alias — add '- $host' under nginx.networks.ohrmdevnet.aliases by hand"
    compose up -d nginx >/dev/null
  fi
}

## ---------------------------------------------------------------------------
## build-vue / build-client
## ---------------------------------------------------------------------------
require_tree() {
  require_slug "$1"
  local d; d="$(test_src)/$1"
  [[ -d "$d/.git" ]] || die "no tree at $d"
  printf '%s\n' "$d"
}

require_amd64() {
  docker run --rm --platform linux/amd64 busybox true 2>/dev/null \
    || die "amd64 emulation is not registered — run 'make amd64-enable-mac' first (needed after each Docker restart)"
}

# node_modules is gitignored, so a --lean tree has none. Mirroring from the
# source tree beats an npm install by minutes and gives the identical result.
ensure_node_modules() {
  local dst="$1" rel="$2" src; src="$(test_src)/$SOURCE_WC_DEFAULT"
  [[ -d "$dst/$rel" ]] && return 0
  [[ -d "$src/$rel" ]] || return 0
  log "mirroring $rel from $SOURCE_WC_DEFAULT"
  mirror "$src/$rel" "$dst/$rel"
}

cmd_build_vue() {
  local slug="${1:-}" dst; dst="$(require_tree "$slug")"; require_stack
  local wd; wd="$(ctr_path "$slug")/symfony/web/vue-app"
  ensure_node_modules "$dst" symfony/web/vue-app/node_modules
  # Native arm64. nvm's `latest` alias here is Node 14, which is what this build
  # wants; `default` is Node 6 and belongs to the legacy client.
  log "building vue-app in $WEB_CTR (Node 14, ~4 minutes)"
  docker exec -w "$wd" "$WEB_CTR" bash -lc 'source /root/.nvm/nvm.sh && nvm use latest && npm run build'
  log "done — dist/ is read at request time, so the change is live on the next request"
}

cmd_build_client() {
  local slug="${1:-}" dst; dst="$(require_tree "$slug")"; require_amd64
  local wd; wd="$(ctr_path "$slug")/symfony/web/client"
  # gulp CLEANS build/js, build/fonts and build/images before it builds, so a
  # failure part-way leaves this tree with no bundle at all. Do not start one
  # you cannot finish.
  log "building legacy client for $slug in the amd64 builder (Node 6, emulated)"
  log "NOTE: gulp deletes build/ first — $slug is un-servable until this finishes"
  compose run --rm -w "$wd" \
    -v "web83_client_node_modules_$slug:$wd/node_modules" \
    web83_client_build \
    'source /root/.nvm/nvm.sh && nvm use default && node -v && npm install && bower install --allow-root && gulp build'
  log "done — _index.php re-injected with the new bundle hash; reload with a cache buster"
}

## ---------------------------------------------------------------------------
## list / remove
## ---------------------------------------------------------------------------
cmd_list() {
  require_stack
  local root; root="$(test_src)"
  printf '%-18s %-30s %-7s %-8s %-6s %s\n' SLUG BRANCH APP_DB TEST_DB HOSTS URL
  for d in "$root"/*/; do
    local slug br a t h
    slug="$(basename "$d")"
    [[ -d "$d/.git" ]] || continue
    br="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
    a="-"; t="-"; h="-"
    db_exists "$slug" && a="yes"
    db_exists "test_$slug" && t="yes"
    grep -qE "[[:space:]]$slug\.${DOMAIN//./\\.}([[:space:]]|\$)" /etc/hosts && h="yes"
    printf '%-18s %-30s %-7s %-8s %-6s %s\n' "$slug" "$br" "$a" "$t" "$h" "$(url "$slug")"
  done
}

cmd_remove() {
  local slug="" force=0 assume_yes=0
  while (( $# )); do case "$1" in
    --force) force=1; shift ;;
    --yes) assume_yes=1; shift ;;
    -*) die "unknown flag $1" ;;
    *) slug="$1"; shift ;;
  esac; done
  require_slug "$slug"; require_stack
  local root dst; root="$(test_src)"; dst="$root/$slug"
  [[ "$slug" == "trunk" || "$slug" == "ng" ]] && die "refusing to remove the standing checkout '$slug'"
  [[ -d "$dst" ]] || die "no tree at $dst"
  # A worktree hub would take its dependants down with it.
  [[ -d "$dst/.git/worktrees" ]] && die "'$slug' is the hub for git worktrees — remove those first"

  if (( ! force )); then
    # Untracked files are build cruft and mirrored local state, which every tree
    # has by construction; only tracked modifications and unpushed commits are
    # work worth refusing over.
    [[ -z "$(git -C "$dst" status --porcelain --untracked-files=no)" ]] || die "'$slug' has uncommitted changes — commit, stash, or pass --force"
    local ahead; ahead="$(git -C "$dst" log --oneline '@{upstream}..HEAD' 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$ahead" == "0" ]] || die "'$slug' has $ahead unpushed commit(s) — push, or pass --force"
  fi

  printf 'DESTRUCTIVE. This will permanently delete:\n'
  printf '  tree      %s\n  databases %s, test_%s\n  DNS       %s\n' "$dst" "$slug" "$slug" "$(url "$slug")"
  if (( assume_yes )); then
    log "--yes given, proceeding without confirmation"
  else
    read -r -p "Type the slug to confirm: " reply
    [[ "$reply" == "$slug" ]] || die "aborted"
  fi

  db_exists "$slug"      && { log "dropping database $slug";      sql "DROP DATABASE \`$slug\`;"; }
  db_exists "test_$slug" && { log "dropping database test_$slug"; sql "DROP DATABASE \`test_$slug\`;"; }
  log "removing $dst"; chmod -R u+w "$dst" 2>/dev/null || true; rm -rf "$dst"

  log "removing DNS entries"
  local t; t="$(mktemp)"
  { grep -vE "[[:space:]]$slug\.${DOMAIN//./\\.}\$" /etc/hosts || true; } > "$t"
  sudo tee /etc/hosts < "$t" >/dev/null; rm -f "$t"
  t="$(mktemp)"
  { grep -vE "^[[:space:]]*- $slug\.${DOMAIN//./\\.}\$" "$OVERRIDE" || true; } > "$t"
  cat "$t" > "$OVERRIDE"; rm -f "$t"
  compose up -d nginx >/dev/null
  docker volume rm "web83_client_node_modules_$slug" >/dev/null 2>&1 || true
  log "$slug removed"
}

case "${1:-}" in
  new)          shift; cmd_new "$@" ;;
  list)         shift; cmd_list "$@" ;;
  build-vue)    shift; cmd_build_vue "$@" ;;
  build-client) shift; cmd_build_client "$@" ;;
  remove)       shift; cmd_remove "$@" ;;
  ''|-h|--help) awk '/^# /{sub(/^# ?/,"");print;next}/^[^#]/{exit}' "${BASH_SOURCE[0]}" ;;
  *)            die "unknown command '$1' (new|list|build-vue|build-client|remove)" ;;
esac
