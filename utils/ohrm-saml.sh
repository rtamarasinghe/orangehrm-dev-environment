#!/usr/bin/env bash
#
# Run the opt-in SAML test container, dev_saml at https://saml.test (SimpleSAMLphp
# as both IdP and SP), and link OrangeHRM trees to it. Normally reached as
# `ohrm saml` (see utils/ohrm-shell.sh).
#
# Usage:
#   ohrm saml <command> [tree] [--yes]
#
#   ohrm saml up              # set up whatever is missing, then build and start dev_saml
#   ohrm saml down            # stop and remove dev_saml; keys, certificate, nginx
#                             # block and linked trees stay
#   ohrm saml status          # whether dev_saml runs, what https://saml.test/ answers,
#                             # and one line per linked tree
#   ohrm saml link <tree>     # wire a TEST tree to dev_saml
#   ohrm saml unlink <tree>   # put the tree back as link found it
#
# up creates only what is missing, so running it again changes nothing:
#   1. custom-compose/config/saml/keys/container.{key,crt}, the container's own
#      signing pair, and keys/secretsalt
#   2. config/nginx/cert/saml/{cert,key}.pem, issued by mkcert for saml.test
#   3. config/nginx/virtual-servers/saml.conf, copied from
#      custom-compose/config/saml/nginx/saml.conf when missing or different, then
#      `nginx -t` and a reload. If `nginx -t` fails, the copy is removed again.
#   4. the /etc/hosts line `127.0.0.1 saml.test`. With a terminal it asks before
#      running sudo (--yes, -y answers yes); without one it prints the line to add.
#   5. the trees, state, generated and data folders. data/ is made writable by
#      everyone, since the container's Apache (www-data) appends acs.log to it.
# Then it starts the saml service alone, never its dependencies, and waits up to
# 30 s for SimpleSAMLphp to answer inside the container. Every run then rewrites
# custom-compose/config/saml/generated/idp-metadata.xml and sp-metadata.xml, the
# container IdP's and SP's metadata, which link puts into a tree's database.
#
# status prints one line per linked tree: "<tree>  ok", or "<tree>  missing: "
# and which of these are gone: rows (the two provider rows link added),
# registration (trees/<tree>.json), domain.name (no longer the tree's host) and
# files (the tree's IdP key or certificate of link step 4, in the tree folder link
# recorded). It only reads.
#
# link wires one enterprise tree under the TEST source path to the container. It
# needs `up` to have run once; dev_saml itself may be down. Before each change it
# records what unlink needs to undo it, in custom-compose/config/saml/state/<tree>/.
#   1. checks the tree: a name matching ^[a-z0-9]+$, symfony/config/databases.yml,
#      its own .git folder (worktree trees are refused) and the SAML plugin's cert
#      folder. A tree that is already linked is left as it is, and one that holds
#      only one of the two files of step 4 is refused.
#   2. records the tree's folder (physical path), its database and its
#      ohrm_config domain.name
#   3. sets domain.name to <tree>.test-webubuntu83.orangehrmdev.com
#   4. generates the tree's IdP key and certificate, saml.prod.orangehrm-idp.pem
#      and .crt, when both are missing
#   5. adds each of the two to .git/info/exclude when it is not listed there
#   6. warns when the tree already has an active IdP row
#   7. adds an IdP and an SP row named 'SAML test container' to ohrm_saml_provider,
#      holding the container's metadata
#   8. writes custom-compose/config/saml/trees/<tree>.json, which the container
#      reads to know the tree's IdP and SP
#   9. clears the tree's symfony cache in the web container. When that container
#      is down, it prints the command to run later.
#  10. prints the tree's login URL and the apps page
# If any of steps 2 to 9 fails, link prints "rolling back <tree>", undoes what it
# did as unlink does, and exits 1.
#
# unlink puts a tree back as link found it, from its state folder alone, so
# dev_saml may be down. A tree with no state folder is not linked: unlink says so,
# changes nothing and exits 1. Otherwise it
#   1. puts back the recorded domain.name, only while the value is still the
#      tree's host; a value changed since link is left as it is
#   2. deletes the recorded provider rows, attribute rows first, and only while
#      they are still named 'SAML test container'. When an ohrm_external_service
#      row points at one of them, it deletes none, since that row would go too.
#   3. deletes the files link created, and no others
#   4. removes from .git/info/exclude only the lines link added
#   Steps 3 and 4 work in the tree folder link recorded, and only while the TEST
#   source path still resolves the tree to it. Otherwise they are skipped with a
#   message, so a same-named tree of another checkout is never touched.
#   5. removes trees/<tree>.json
#   6. clears the tree's symfony cache, as link does
#   7. removes the state folder
# A step with nothing recorded is skipped, which covers a link that stopped part
# way and a database reloaded since link. When a step fails, or its state file
# holds something unusable, the other steps still run, the state folder is kept
# so unlink can be run again, and unlink exits 1. Activity stays: login history,
# SimpleSAMLphp_kvstore rows, and ohrm_saml_user_identity rows, whose provider_id
# becomes NULL.
#
# Environment overrides: OHRM_TEST_SRC_PATH (else the value in .env, else
# html/OHRMStandalone/TEST), OHRM_WEB_CONTAINER (default dev_web_83_ubuntu),
# OHRM_DB_PASS (MySQL root password, default 1234), and OHRM_WEB_RUNNING=true/false,
# which stands in for asking docker whether the web container is running.
# OHRM_TTY=1/0 forces the /etc/hosts prompt on or off. OHRM_DRY_RUN=1 prints each
# change instead of making it (used by utils/tests/ohrm-saml-test.sh). OHRM_SAML_DIR,
# OHRM_NGINX_DIR and OHRM_HOSTS_FILE stand in for custom-compose/config/saml,
# config/nginx and /etc/hosts. OHRM_SAML_FAIL_AT=<n> is a test hook: link step n
# (2 to 9) fails before it changes anything, so the rollback runs.
set -euo pipefail

SAML_CONTAINER=dev_saml
NGINX_CONTAINER=dev_nginx
DB_CONTAINER=dev_mariadb_101115
WEB_CONTAINER="${OHRM_WEB_CONTAINER:-dev_web_83_ubuntu}"
DB_PASS="${OHRM_DB_PASS:-1234}"
SAML_URL="https://saml.test/"
HOSTS_LINE="127.0.0.1 saml.test"

# Where the TEST source path is mounted inside the web container.
CONTAINER_TEST_ROOT=/var/www/html/OHRMStandalone/TEST
TREE_DOMAIN=test-webubuntu83.orangehrmdev.com
# Tree-relative. The file names are IDPUtil::IDP_PRIVATE_KEY and IDP_CERTIFICATE.
IDP_CERT_DIR=symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert
IDP_KEY_FILE=saml.prod.orangehrm-idp.pem
IDP_CRT_FILE=saml.prod.orangehrm-idp.crt
# What a usable state file tree_dir holds: an absolute path on one line.
TREE_DIR_RE='^/[^[:cntrl:]]*$'

case "${OHRM_TTY:-auto}" in
  1)  interactive=1 ;;
  0)  interactive=0 ;;
  *)  [[ -t 0 ]] && interactive=1 || interactive=0 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SAML_DIR="${OHRM_SAML_DIR:-$repo_root/custom-compose/config/saml}"
NGINX_DIR="${OHRM_NGINX_DIR:-$repo_root/config/nginx}"
HOSTS_FILE="${OHRM_HOSTS_FILE:-/etc/hosts}"

# Dry-run traces go to fd 3, a copy of the original stderr, so they still show
# when a helper's output is captured or piped, or its stderr is silenced.
exec 3>&2

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'ohrm saml: %s\n' "$1" >&2; }
die()  { warn "$1"; exit "${2:-1}"; }

# The long help is the comment header above, from "Usage:" to the end of the
# block, so there is only one copy of it to keep correct.
help_text() {
  awk '/^# Usage:/{f=1} f{ if ($0 !~ /^#/) exit; sub(/^#[ ]?/, ""); print }' "${BASH_SOURCE[0]}"
}

usage() {
  printf 'usage: ohrm saml up|down|status [--yes]\n' >&2
  printf '       ohrm saml link|unlink <tree>\n' >&2
  printf "run 'ohrm saml --help' for the full description\n" >&2
  exit 2
}

## ---------------------------------------------------------------------------
## Helpers. Under OHRM_DRY_RUN each one prints `+ ...` instead of acting; the
## tests match on those formats.
## ---------------------------------------------------------------------------

dry_run() { [[ -n "${OHRM_DRY_RUN:-}" ]]; }

trace() { printf '+ %s\n' "$*" >&3; }

run() { # run <command...>
  if dry_run; then trace "$*"; return 0; fi
  "$@"
}

# SQL on stdin, run as root against <database> through the DB container. The
# password travels in MYSQL_PWD, never on a command line. Prints the result rows
# tab-separated without a header; in dry-run, prints DRYRUN in their place.
db_sql() { # db_sql <database>
  if dry_run; then
    { printf '+ sql[%s]:\n' "$1"; cat; } >&3
    printf 'DRYRUN\n'
    return 0
  fi
  MYSQL_PWD="$DB_PASS" docker exec -i -e MYSQL_PWD "$DB_CONTAINER" mysql -uroot -N -B --raw "$1"
}

# docker-compose for the saml service, run from the repo root. saml.yml joins the
# ohrmdevnet network that docker-compose.yml defines, so the base files come first.
compose() { # compose <docker-compose arguments...>
  local files=(-f docker-compose.yml)
  if [[ -f "$repo_root/docker-compose.override.yml" ]]; then
    files+=(-f docker-compose.override.yml)
  fi
  files+=(-f custom-compose/saml.yml)
  ( cd "$repo_root" && run docker-compose "${files[@]}" "$@" )
}

append_line() { # append_line <file> <line>
  if dry_run; then trace "append $1: $2"; return 0; fi
  # A last line without its newline would otherwise run into <line>.
  if [[ -s "$1" && -n "$(tail -c 1 "$1")" ]]; then printf '\n' >> "$1"; fi
  printf '%s\n' "$2" >> "$1"
}

# Content on stdin. Dry-run still reads stdin, so the command feeding it never
# fails on a closed pipe.
write_file() { # write_file <file>
  if dry_run; then trace "write $1"; cat > /dev/null; return 0; fi
  cat > "$1"
}

# Without -r, <path> gets rm -rf only when it is a folder at call time. With -r it
# always does, so a dry run prints the same command whether or not it exists.
remove_path() { # remove_path [-r] <path>
  local flag=-f
  if [[ "$1" == -r ]]; then flag=-rf; shift
  elif [[ -d "$1" ]]; then flag=-rf; fi
  if dry_run; then trace "rm $flag $1"; return 0; fi
  rm "$flag" "$1"
}

# Removes from <file> every line equal to a line of <linesfile>. The file keeps
# its mode and is replaced in one step. Returns non-zero on any failure, also
# when called where set -e is off.
remove_lines() { # remove_lines <file> <linesfile>
  if dry_run; then trace "remove-lines $1"; return 0; fi
  local tmp rc=0
  tmp="$(mktemp "$1.XXXXXX")" || return
  if ! cp -p "$1" "$tmp"; then rm -f "$tmp"; return 1; fi
  grep -vxF -f "$2" "$1" > "$tmp" || rc=$?
  # grep exits 1 when every line was removed.
  if [[ $rc -gt 1 ]]; then rm -f "$tmp"; return "$rc"; fi
  mv "$tmp" "$1"
}

## ---------------------------------------------------------------------------
## up
## ---------------------------------------------------------------------------

ensure_container_keys() {
  local keys="$SAML_DIR/keys"
  if [[ ! -d "$keys" ]]; then run mkdir -p "$keys"; fi
  if [[ ! -f "$keys/container.key" || ! -f "$keys/container.crt" ]]; then
    log "generating the container's signing key pair"
    run openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=saml.test \
      -keyout "$keys/container.key" -out "$keys/container.crt"
    # A dev-only key: the container's Apache reads it through the bind mount.
    run chmod 644 "$keys/container.key" "$keys/container.crt"
  fi
  # An empty salt counts as missing.
  if [[ ! -s "$keys/secretsalt" ]]; then
    log "generating the SimpleSAMLphp secret salt"
    run openssl rand -hex 32 | write_file "$keys/secretsalt"
  fi
}

ensure_tls_cert() {
  local dir="$NGINX_DIR/cert/saml"
  if [[ -f "$dir/cert.pem" && -f "$dir/key.pem" ]]; then return 0; fi
  log "issuing the saml.test certificate"
  if [[ ! -d "$dir" ]]; then run mkdir -p "$dir"; fi
  run mkcert -key-file "$dir/key.pem" -cert-file "$dir/cert.pem" saml.test
}

# Must run after ensure_tls_cert: nginx refuses to start on a block whose
# certificate is missing, and nginx fronts every tree.
install_nginx_block() {
  local src="$repo_root/custom-compose/config/saml/nginx/saml.conf"
  local dst="$NGINX_DIR/virtual-servers/saml.conf" cert="$NGINX_DIR/cert/saml"
  if cmp -s "$src" "$dst"; then return 0; fi
  if ! dry_run && [[ ! -f "$cert/cert.pem" || ! -f "$cert/key.pem" ]]; then
    die "no certificate in $cert, so the nginx block was not installed"
  fi
  log "installing the nginx block for saml.test"
  run cp "$src" "$dst"
  if ! run docker exec "$NGINX_CONTAINER" nginx -t; then
    remove_path "$dst"
    die "nginx -t failed with $dst in place, so it was removed again"
  fi
  run docker exec "$NGINX_CONTAINER" nginx -s reload
}

ensure_hosts_line() {
  local reply=""
  if grep -qE '[[:space:]]saml\.test([[:space:]]|$)' "$HOSTS_FILE"; then return 0; fi
  if [[ $interactive -eq 0 ]]; then
    printf '%s has no saml.test line. Add this one, with sudo:\n  %s\n' "$HOSTS_FILE" "$HOSTS_LINE"
    return 0
  fi
  if [[ $assume_yes -eq 0 ]]; then
    printf '%s has no saml.test line.\n' "$HOSTS_FILE"
    read -r -p "Add '$HOSTS_LINE' now (runs sudo)? [y/N] " reply || true
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
      printf 'Skipped. Add it yourself:\n  %s\n' "$HOSTS_LINE"
      return 0
    fi
  fi
  run sudo tee -a "$HOSTS_FILE" <<< "$HOSTS_LINE" > /dev/null
}

wait_for_saml() {
  local deadline=$((SECONDS + 30))
  until run docker exec "$SAML_CONTAINER" curl -fsS -o /dev/null http://localhost/simplesaml/ 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      die "SimpleSAMLphp did not answer in $SAML_CONTAINER within 30 s; see: docker logs $SAML_CONTAINER"
    fi
    sleep 1
  done
}

# Fetches <url> inside the running container and writes it to <file>. A failed
# fetch stops `up` and leaves the earlier <file> as it was.
export_metadata() { # export_metadata <url> <file>
  local xml
  xml="$(run docker exec "$SAML_CONTAINER" curl -fsS "$1")" \
    || die "could not fetch $1 inside $SAML_CONTAINER; see: docker logs $SAML_CONTAINER"
  printf '%s\n' "$xml" | write_file "$2"
}

cmd_up() {
  ensure_container_keys
  ensure_tls_cert
  install_nginx_block
  ensure_hosts_line
  # trees and data are bind-mount sources. Docker would create a missing one
  # itself, owned by root on Linux.
  run mkdir -p "$SAML_DIR/trees" "$SAML_DIR/state" "$SAML_DIR/generated" "$SAML_DIR/data"
  # The container's Apache runs as www-data, which on native Linux is not the
  # host user that owns data/. Dev-only and gitignored.
  run chmod a+rwx "$SAML_DIR/data"
  log "building and starting $SAML_CONTAINER"
  compose up -d --build --no-deps saml
  wait_for_saml
  log "exporting the container's IdP and SP metadata to $SAML_DIR/generated"
  export_metadata http://localhost/simplesaml/module.php/saml/idp/metadata "$SAML_DIR/generated/idp-metadata.xml"
  export_metadata http://localhost/simplesaml/module.php/saml/sp/metadata/container-sp "$SAML_DIR/generated/sp-metadata.xml"
  log "$SAML_CONTAINER is up: $SAML_URL"
}

## ---------------------------------------------------------------------------
## down, status
## ---------------------------------------------------------------------------

cmd_down() {
  log "stopping and removing $SAML_CONTAINER; keys, certificate, nginx block and linked trees stay"
  compose rm -sf saml
}

cmd_status() {
  local state=stopped code d
  if [[ "$(run docker inspect -f '{{.State.Running}}' "$SAML_CONTAINER" 2>/dev/null)" == true ]]; then
    state=running
  fi
  printf 'container: %s\n' "$state"
  code="$(run curl --cacert "$(mkcert -CAROOT)/rootCA.pem" -s -o /dev/null -w '%{http_code}' "$SAML_URL" || true)"
  printf '%s: %s\n' "$SAML_URL" "${code:-000}"
  for d in "$SAML_DIR"/state/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    tree_status "${d##*/}"
  done
}

# Prints "<tree>  ok", or "<tree>  missing: " and which of rows, registration,
# domain.name and files are gone. A database that cannot be read counts its
# checks as missing, and an unusable tree_dir counts the files as missing. Only
# reads.
tree_status() { # tree_status <tree>
  local tree="$1" state app_db idp sp rows_sql=0 res="" missing="" dir rc f files=0
  state="$(state_dir "$tree")"
  rc=0; dir="$(state_value "$state/tree_dir" "$TREE_DIR_RE")" || rc=$?
  if [[ $rc -eq 1 ]]; then dir="$(test_root)/$tree"; fi
  if [[ $rc -ne 2 ]]; then
    for f in "$IDP_KEY_FILE" "$IDP_CRT_FILE"; do
      if [[ -f "$dir/$IDP_CERT_DIR/$f" ]]; then files=$((files + 1)); fi
    done
  fi
  app_db="$(state_value "$state/app_db" '^[A-Za-z0-9_]+$')" || app_db=""
  idp="$(state_value "$state/idp_row_id" '^[0-9]+$')" || idp=""
  sp="$(state_value "$state/sp_row_id" '^[0-9]+$')" || sp=""
  if [[ -n "$idp" && -n "$sp" ]]; then
    rows_sql="(SELECT COUNT(*) FROM ohrm_saml_provider WHERE id IN ($idp, $sp) AND name = 'SAML test container')"
  fi
  if [[ -n "$app_db" ]]; then
    res="$(db_sql "$app_db" <<< "SELECT $rows_sql, (SELECT COUNT(*) FROM ohrm_config WHERE property = 'domain.name' AND CAST(value AS BINARY) = FROM_BASE64('$(tree_host "$tree" | tr -d '\n' | to_b64)'));")" || res=""
  fi
  if [[ "${res%%$'\t'*}" != 2 ]]; then missing+="rows, "; fi
  if [[ ! -f "$SAML_DIR/trees/$tree.json" ]]; then missing+="registration, "; fi
  if [[ "${res#*$'\t'}" != 1 ]]; then missing+="domain.name, "; fi
  if [[ $files -ne 2 ]]; then missing+="files, "; fi
  if [[ -z "$missing" ]]; then
    printf '%s  ok\n' "$tree"
  else
    printf '%s  missing: %s\n' "$tree" "${missing%, }"
  fi
}

## ---------------------------------------------------------------------------
## Trees
## ---------------------------------------------------------------------------

# The TEST source path on the host. Mirrors docker-compose's
# ${OHRM_TEST_SRC_PATH:-./html/OHRMStandalone/TEST}, including reading .env.
# Relative paths resolve against the repo root, as compose does.
test_root() {
  local path="${OHRM_TEST_SRC_PATH:-}"
  if [[ -z "$path" && -f "$repo_root/.env" ]]; then
    path="$(grep -E '^OHRM_TEST_SRC_PATH=' "$repo_root/.env" | tail -n1 | cut -d= -f2- || true)"
  fi
  path="${path:-./html/OHRMStandalone/TEST}"
  [[ "$path" == /* ]] || path="$repo_root/${path#./}"
  printf '%s\n' "$path"
}

tree_host() { printf '%s.%s\n' "$1" "$TREE_DOMAIN"; }

# The physical path of <tree>'s folder under the TEST source path, as link
# records it in tree_dir. Fails when there is no such folder.
tree_path() { # tree_path <tree>
  local d
  d="$(test_root)/$1"
  [[ -d "$d" ]] || return 1
  (cd "$d" && pwd -P)
}

state_dir() { printf '%s/state/%s\n' "$SAML_DIR" "$1"; }

# The dbname= of the first dsn: in the tree's databases.yml. Fails unless it is a
# plain identifier, since it is used unquoted as the mysql database argument.
tree_app_db() { # tree_app_db <tree>
  local yml db
  yml="$(test_root)/$1/symfony/config/databases.yml"
  db="$(awk '/dsn:/ { if (match($0, /dbname=[^;'\''" ]*/)) print substr($0, RSTART + 7, RLENGTH - 7); exit }' "$yml")"
  [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || die "no usable dbname= in the first dsn: of $yml"
  printf '%s\n' "$db"
}

# The name becomes a path, so it is checked before anything else uses it.
check_slug() { # check_slug <tree>
  [[ "$1" =~ ^[a-z0-9]+$ ]] || die "tree '$1' must match ^[a-z0-9]+\$"
}

# Exits 1 after printing one message per failed check.
check_tree() { # check_tree <tree>
  local root dir failed=0
  check_slug "$1"
  root="$(test_root)"
  dir="$root/$1"
  [[ -d "$dir" ]] || die "no working copy '$1' under $root"
  if [[ ! -f "$dir/symfony/config/databases.yml" ]]; then
    warn "$1 has no symfony/config/databases.yml"; failed=1
  fi
  # A worktree's info/exclude is shared with its main checkout, so unlink could
  # not restore it for this tree alone.
  if [[ ! -d "$dir/.git" ]]; then
    warn "$1/.git is not a folder: worktree trees are not supported"; failed=1
  fi
  if [[ ! -d "$dir/$IDP_CERT_DIR" ]]; then
    warn "$1 has no $IDP_CERT_DIR: not an enterprise tree"; failed=1
  fi
  if [[ $failed -ne 0 ]]; then exit 1; fi
}

web_running() {
  [[ "${OHRM_WEB_RUNNING:-$(docker inspect -f '{{.State.Running}}' "$WEB_CONTAINER" 2>/dev/null || true)}" == true ]]
}

# Returns the status of the cache clear; a web container that is down is not a
# failure.
clear_tree_cache() { # clear_tree_cache <tree>
  if web_running; then
    log "clearing $1's symfony cache"
    run docker exec -w "$CONTAINER_TEST_ROOT/$1/symfony" "$WEB_CONTAINER" php symfony cc
  else
    printf 'web container is down; later run: ohrm sf %s -- php symfony cc\n' "$1"
  fi
}

# Prints the content of state file <file>, less its trailing newline, when all of
# it matches <regex>. Returns 1 when the file is absent or empty, and 2 after
# reporting content that does not match. Every state value that reaches SQL is
# read through here.
state_value() { # state_value <file> <regex>
  local v
  [[ -s "$1" ]] || return 1
  v="$(< "$1")"
  if [[ ! "$v" =~ $2 ]]; then
    warn "ignoring $1: unexpected content"
    return 2
  fi
  printf '%s\n' "$v"
}

to_b64() { base64 | tr -d '\n'; }

# A row id read back from the database. Under OHRM_DRY_RUN, db_sql answers DRYRUN.
check_row_id() { # check_row_id <what> <value>
  if [[ "$2" =~ ^[0-9]+$ ]] || { dry_run && [[ "$2" == DRYRUN ]]; }; then return 0; fi
  die "expected the new $1 row's id from the database, got: $2"
}

## ---------------------------------------------------------------------------
## link
## ---------------------------------------------------------------------------

# Test hook: OHRM_SAML_FAIL_AT=<n> makes link step <n> fail before it changes
# anything, so the rollback can be tried live and in a dry run.
fail_step() { # fail_step <link step>
  if [[ "${OHRM_SAML_FAIL_AT:-}" == "$1" ]]; then
    die "link step $1 failed (OHRM_SAML_FAIL_AT=$1)"
  fi
}

# EXIT trap while link runs steps 2 to 9, which also catches set -e and die.
rollback_link() { # rollback_link <exit status>
  trap - EXIT
  if [[ $1 -eq 0 ]]; then return 0; fi
  warn "rolling back $linking_tree"
  if restore_tree "$linking_tree"; then warn "rolled back $linking_tree"; fi
  exit 1
}

# Each fact goes into the state folder before the change it covers, so a rollback
# or unlink can undo a run that stopped part way. No state file is ever sourced
# as shell. The step numbers are those in the header.
cmd_link() { # cmd_link <tree>
  local tree="$1" dir state host app_db idp_meta sp_meta raw b64 f line count active idp_id sp_id cert
  check_tree "$tree"
  state="$(state_dir "$tree")"
  if [[ -d "$state" ]]; then printf '%s is already linked\n' "$tree"; return 0; fi
  for f in idp-metadata.xml sp-metadata.xml; do
    [[ -s "$SAML_DIR/generated/$f" ]] || die "no $SAML_DIR/generated/$f; run 'ohrm saml up' first"
  done
  dir="$(tree_path "$tree")"
  host="$(tree_host "$tree")"
  app_db="$(tree_app_db "$tree")"
  idp_meta="$(to_b64 < "$SAML_DIR/generated/idp-metadata.xml")"
  sp_meta="$(to_b64 < "$SAML_DIR/generated/sp-metadata.xml")"
  # link makes the key and certificate as a pair, so it would overwrite a lone
  # one that it did not create.
  count=0
  for f in "$IDP_KEY_FILE" "$IDP_CRT_FILE"; do
    if [[ -e "$dir/$IDP_CERT_DIR/$f" ]]; then count=$((count + 1)); fi
  done
  if [[ $count -eq 1 ]]; then
    die "$tree has only one of $IDP_KEY_FILE and $IDP_CRT_FILE in $IDP_CERT_DIR; remove it or add the other"
  fi

  linking_tree="$tree"
  trap 'rollback_link $?' EXIT

  fail_step 2
  log "recording $tree's starting state in $state"
  run mkdir -p "$state"
  printf '%s\n' "$dir" | write_file "$state/tree_dir"
  printf '%s\n' "$app_db" | write_file "$state/app_db"
  # The x keeps a row holding an empty value apart from no row at all.
  raw="$(db_sql "$app_db" <<< "SELECT REPLACE(TO_BASE64(value), CHAR(10), '') FROM ohrm_config WHERE property = 'domain.name';" && printf x)"
  raw="${raw%x}"
  if [[ -z "$raw" ]]; then
    die "$tree has no domain.name row in ohrm_config of database $app_db"
  fi
  b64="${raw%$'\n'}"
  printf '%s\n' "$b64" | write_file "$state/domain_name.b64"

  fail_step 3
  log "setting $tree's domain.name to $host"
  db_sql "$app_db" > /dev/null <<< "UPDATE ohrm_config SET value = FROM_BASE64('$(printf %s "$host" | to_b64)') WHERE property = 'domain.name';"

  fail_step 4
  if [[ $count -eq 0 ]]; then
    log "generating $tree's IdP key and certificate"
    for f in "$IDP_KEY_FILE" "$IDP_CRT_FILE"; do
      append_line "$state/created_files" "$IDP_CERT_DIR/$f"
    done
    run openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$host" \
      -keyout "$dir/$IDP_CERT_DIR/$IDP_KEY_FILE" -out "$dir/$IDP_CERT_DIR/$IDP_CRT_FILE"
    # Dev-only key: the web container's Apache reads it through the bind mount.
    run chmod 644 "$dir/$IDP_CERT_DIR/$IDP_KEY_FILE" "$dir/$IDP_CERT_DIR/$IDP_CRT_FILE"
  fi

  fail_step 5
  for f in "$IDP_KEY_FILE" "$IDP_CRT_FILE"; do
    line="/$IDP_CERT_DIR/$f"
    if ! grep -qxF -- "$line" "$dir/.git/info/exclude" 2>/dev/null; then
      append_line "$state/exclude_added" "$line"
      append_line "$dir/.git/info/exclude" "$line"
    fi
  done

  fail_step 6
  active="$(db_sql "$app_db" <<< "SELECT COUNT(*) FROM ohrm_saml_provider WHERE type = 'IDP' AND status = 1;")"
  if [[ "$active" =~ ^[0-9]+$ ]] && (( active > 0 )); then
    warn "warning: $tree already has $active active IdP provider row(s), so its login page will offer more than one SAML provider"
  fi

  fail_step 7
  log "adding the 'SAML test container' IdP and SP rows to $app_db.ohrm_saml_provider"
  idp_id="$(db_sql "$app_db" <<< "INSERT INTO ohrm_saml_provider (name, type, metadata, username_key, status) VALUES ('SAML test container', 'IDP', FROM_BASE64('$idp_meta'), 'username', 1); SELECT LAST_INSERT_ID();")"
  check_row_id IdP "$idp_id"
  printf '%s\n' "$idp_id" | write_file "$state/idp_row_id"
  # One transaction, so a failed attribute insert leaves no SP row unrecorded.
  sp_id="$(db_sql "$app_db" <<< "START TRANSACTION; INSERT INTO ohrm_saml_provider (name, type, metadata, username_key, status) VALUES ('SAML test container', 'SP', FROM_BASE64('$sp_meta'), NULL, 1); SET @sp = LAST_INSERT_ID(); INSERT INTO ohrm_saml_provider_attribute (provider_id, token_id, claim_name) VALUES (@sp, 2, 'username'), (@sp, 3, 'firstName'), (@sp, 5, 'email'), (@sp, 6, 'employeeId'); COMMIT; SELECT @sp;")"
  check_row_id SP "$sp_id"
  printf '%s\n' "$sp_id" | write_file "$state/sp_row_id"

  fail_step 8
  # Under OHRM_DRY_RUN the certificate may exist only in the trace.
  if dry_run; then
    cert=DRYRUN
  else
    cert="$(openssl x509 -in "$dir/$IDP_CERT_DIR/$IDP_CRT_FILE" -outform DER | to_b64)"
  fi
  log "registering $tree with the container in $SAML_DIR/trees/$tree.json"
  run jq -n \
    --arg tree "$tree" \
    --arg host "$host" \
    --arg idpEntityId "https://$host/saml/saml2/idp/metadata.php" \
    --arg idpSsoUrl "https://$host/saml/saml2/idp/SSOService.php" \
    --arg idpCert "$cert" \
    --arg spEntityId "$host/saml/module.php/saml/sp/metadata.php/orangehrm-sp" \
    --arg spAcsUrl "https://$host/saml/module.php/saml/sp/saml2-acs.php/orangehrm-sp" \
    --arg spRelayState "https://$host/openidauth/openIdCredentials?openIdProvider=saml_$idp_id" \
    '$ARGS.named' | write_file "$SAML_DIR/trees/$tree.json"

  fail_step 9
  clear_tree_cache "$tree"
  trap - EXIT

  log "$tree is linked"
  printf '  tree login: https://%s/auth/login\n' "$host"
  printf '  apps page:  %s\n' "$SAML_URL"
}

## ---------------------------------------------------------------------------
## unlink
## ---------------------------------------------------------------------------

# Undoes link for <tree> from its state folder alone, in the header's unlink
# order. Every step can run again, so a run that returned 1 can be repeated. It
# never relies on set -e: it also runs from link's EXIT trap.
restore_tree() { # restore_tree <tree>
  local tree="$1" state dir="" recorded current app_db b64 host_b64 changed ids="" id f p rc refs failed=0 skip_rows=0
  state="$(state_dir "$tree")"
  rc=0; recorded="$(state_value "$state/tree_dir" "$TREE_DIR_RE")" || rc=$?
  current="$(tree_path "$tree")" || current=""
  if [[ $rc -eq 0 && "$recorded" == "$current" ]]; then dir="$recorded"; fi
  if [[ $rc -eq 2 ]]; then failed=1; fi
  if [[ -z "$dir" && $rc -ne 2 ]] && [[ -s "$state/created_files" || -s "$state/exclude_added" ]]; then
    if [[ $rc -eq 1 ]]; then
      warn "no tree folder recorded for $tree, so its IdP files and .git/info/exclude lines were left as they are"
    else
      warn "$tree was linked at $recorded, but the TEST source path now resolves it to ${current:-no folder}, so its IdP files and .git/info/exclude lines were left as they are; point OHRM_TEST_SRC_PATH back and run unlink again"
    fi
    failed=1
  fi

  rc=0; app_db="$(state_value "$state/app_db" '^[A-Za-z0-9_]+$')" || rc=$?
  if [[ $rc -ne 0 ]]; then app_db=""; fi
  if [[ $rc -eq 2 ]]; then failed=1; fi

  rc=0; b64="$(state_value "$state/domain_name.b64" '^[A-Za-z0-9+/=]*$')" || rc=$?
  if [[ $rc -eq 2 ]]; then
    failed=1
  elif [[ $rc -eq 0 && -z "$app_db" ]]; then
    warn "no usable app_db for $tree, so its domain.name was not put back"; failed=1
  elif [[ $rc -eq 0 ]]; then
    log "putting back $tree's domain.name"
    # Only while link's value is still there: a database reloaded since link keeps
    # its own value.
    host_b64="$(tree_host "$tree" | tr -d '\n' | to_b64)"
    if ! changed="$(db_sql "$app_db" <<< "UPDATE ohrm_config SET value = FROM_BASE64('$b64') WHERE property = 'domain.name' AND CAST(value AS BINARY) = FROM_BASE64('$host_b64'); SELECT ROW_COUNT();")"; then
      warn "could not put back $tree's domain.name"; failed=1
    elif [[ "$changed" == 0 && "$b64" != "$host_b64" ]]; then
      printf "left %s's domain.name as it is: it is no longer %s\n" "$tree" "$(tree_host "$tree")"
    fi
  fi

  for f in idp_row_id sp_row_id; do
    rc=0; id="$(state_value "$state/$f" '^[0-9]+$')" || rc=$?
    if [[ $rc -eq 0 ]]; then ids="${ids:+$ids, }$id"; fi
    if [[ $rc -eq 2 ]]; then skip_rows=1; fi
  done
  if [[ $skip_rows -eq 1 ]]; then
    failed=1
  elif [[ -n "$ids" && -z "$app_db" ]]; then
    warn "no usable app_db for $tree, so provider rows $ids were not deleted"; failed=1
  elif [[ -n "$ids" ]]; then
    # ohrm_external_service.idp_id cascades on delete, so a service someone set up
    # on one of these rows would go with it.
    refs="$(db_sql "$app_db" <<< "SELECT COUNT(*) FROM ohrm_external_service WHERE idp_id IN (SELECT id FROM ohrm_saml_provider WHERE id IN ($ids) AND name = 'SAML test container');")" || refs=failed
    if [[ "$refs" == failed ]]; then
      warn "could not check $app_db.ohrm_external_service, so provider rows $ids were not deleted"; failed=1
    elif [[ "$refs" =~ ^[0-9]+$ ]] && (( refs > 0 )); then
      warn "$refs ohrm_external_service row(s) in $app_db use provider rows $ids, so those were not deleted; remove or repoint the service(s), then run unlink again"
      failed=1
    else
      log "deleting $tree's 'SAML test container' provider rows $ids"
      if ! db_sql "$app_db" > /dev/null <<< "START TRANSACTION; DELETE FROM ohrm_saml_provider_attribute WHERE provider_id IN ($ids) AND provider_id IN (SELECT id FROM ohrm_saml_provider WHERE name = 'SAML test container'); DELETE FROM ohrm_saml_provider WHERE id IN ($ids) AND name = 'SAML test container'; COMMIT;"; then
        warn "could not delete $tree's provider rows $ids"; failed=1
      fi
    fi
  fi

  if [[ -n "$dir" && -s "$state/created_files" ]]; then
    log "deleting the files link created in $tree"
    while IFS= read -r p || [[ -n "$p" ]]; do
      if [[ -z "$p" ]]; then continue; fi
      # Only paths inside the tree: relative, with no .. segment.
      if [[ "$p" == /* || "/$p/" == */../* ]]; then
        warn "ignoring '$p' in $state/created_files: not a path inside the tree"; failed=1
        continue
      fi
      if ! run rm -f "$dir/$p"; then failed=1; fi
    done < "$state/created_files"
  fi

  if [[ -n "$dir" && -s "$state/exclude_added" && -f "$dir/.git/info/exclude" ]]; then
    log "removing the lines link added to $tree's .git/info/exclude"
    if ! remove_lines "$dir/.git/info/exclude" "$state/exclude_added"; then
      warn "could not remove link's lines from $dir/.git/info/exclude"; failed=1
    fi
  fi

  log "removing $tree's registration with the container"
  if ! run rm -f "$SAML_DIR/trees/$tree.json"; then failed=1; fi

  if ! clear_tree_cache "$tree"; then
    printf 'the cache clear failed; later run: ohrm sf %s -- php symfony cc\n' "$tree"
  fi

  if [[ $failed -ne 0 ]]; then
    warn "kept $state so that 'ohrm saml unlink $tree' can finish the job once the problems above are fixed"
    return 1
  fi
  remove_path -r "$state" || return 1
}

cmd_unlink() { # cmd_unlink <tree>
  local tree="$1"
  check_slug "$tree"
  if [[ ! -d "$(state_dir "$tree")" ]]; then die "$tree is not linked"; fi
  restore_tree "$tree" || exit 1
  log "$tree is unlinked"
}

## ---------------------------------------------------------------------------
## Arguments
## ---------------------------------------------------------------------------

subcmd=""; tree=""; assume_yes=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) help_text; exit 0 ;;
    -y|--yes)  assume_yes=1 ;;
    -*)        printf 'ohrm saml: unknown option %s\n\n' "$1" >&2; usage ;;
    *)         if [[ -z "$subcmd" ]]; then subcmd="$1"
               elif [[ -z "$tree" ]]; then tree="$1"
               else printf 'ohrm saml: too many arguments\n\n' >&2; usage
               fi ;;
  esac
  shift
done

case "$subcmd" in
  up|down|status)
    if [[ -n "$tree" ]]; then printf 'ohrm saml: %s takes no tree\n\n' "$subcmd" >&2; usage; fi
    "cmd_$subcmd" ;;
  "")
    usage ;;
  link|unlink)
    if [[ -z "$tree" ]]; then printf 'ohrm saml: %s needs a tree\n\n' "$subcmd" >&2; usage; fi
    "cmd_$subcmd" "$tree" ;;
  *)
    printf 'ohrm saml: unknown command %s\n\n' "$subcmd" >&2; usage ;;
esac
