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
#   ohrm saml link <tree>     # see below
#   ohrm saml unlink <tree>   # see below
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
#   5. the trees, state, generated and data folders
# Then it starts the saml service alone, never its dependencies, and waits up to
# 30 s for SimpleSAMLphp to answer inside the container. Every run then rewrites
# custom-compose/config/saml/generated/idp-metadata.xml and sp-metadata.xml, the
# container IdP's and SP's metadata, which link puts into a tree's database.
#
# link wires one enterprise tree under the TEST source path to the container. It
# needs `up` to have run once; dev_saml itself may be down. Before each change it
# records what unlink needs to undo it, in custom-compose/config/saml/state/<tree>/.
#   1. checks the tree: a name matching ^[a-z0-9]+$, symfony/config/databases.yml,
#      its own .git folder (worktree trees are refused) and the SAML plugin's cert
#      folder. A tree that is already linked is left as it is.
#   2. sets ohrm_config domain.name to <tree>.test-webubuntu83.orangehrmdev.com
#   3. generates the tree's IdP key and certificate, saml.prod.orangehrm-idp.pem
#      and .crt, when both are missing, and adds them to .git/info/exclude. A
#      tree that holds only one of the two is refused before step 2.
#   4. adds an IdP and an SP row named 'SAML test container' to ohrm_saml_provider,
#      holding the container's metadata, and warns when the tree already had an
#      active IdP row
#   5. writes custom-compose/config/saml/trees/<tree>.json, which the container
#      reads to know the tree's IdP and SP
#   6. clears the tree's symfony cache in the web container. When that container
#      is down, it prints the command to run later.
#
# Environment overrides: OHRM_TEST_SRC_PATH (else the value in .env, else
# html/OHRMStandalone/TEST), OHRM_WEB_CONTAINER (default dev_web_83_ubuntu),
# OHRM_DB_PASS (MySQL root password, default 1234), and OHRM_WEB_RUNNING=true/false,
# which stands in for asking docker whether the web container is running.
# OHRM_TTY=1/0 forces the /etc/hosts prompt on or off. OHRM_DRY_RUN=1 prints each
# change instead of making it (used by utils/tests/ohrm-saml-test.sh). OHRM_SAML_DIR,
# OHRM_NGINX_DIR and OHRM_HOSTS_FILE stand in for custom-compose/config/saml,
# config/nginx and /etc/hosts.
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

remove_path() { # remove_path <file or folder>
  local flag=-f
  if [[ -d "$1" ]]; then flag=-rf; fi
  if dry_run; then trace "rm $flag $1"; return 0; fi
  rm "$flag" "$1"
}

# Removes from <file> every line equal to a line of <linesfile>. The file keeps
# its mode and is replaced in one step.
remove_lines() { # remove_lines <file> <linesfile>
  if dry_run; then trace "remove-lines $1"; return 0; fi
  local tmp rc=0
  tmp="$(mktemp "$1.XXXXXX")"
  cp -p "$1" "$tmp"
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
    printf '%s  linked\n' "${d##*/}"
  done
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

# Exits 1 after printing one message per failed check. The name is checked first
# because it becomes a path.
check_tree() { # check_tree <tree>
  local root dir failed=0
  [[ "$1" =~ ^[a-z0-9]+$ ]] || die "tree '$1' must match ^[a-z0-9]+\$"
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

to_b64() { base64 | tr -d '\n'; }

# A row id read back from the database. Under OHRM_DRY_RUN, db_sql answers DRYRUN.
check_row_id() { # check_row_id <what> <value>
  if [[ "$2" =~ ^[0-9]+$ ]] || { dry_run && [[ "$2" == DRYRUN ]]; }; then return 0; fi
  die "expected the new $1 row's id from the database, got: $2"
}

## ---------------------------------------------------------------------------
## link
## ---------------------------------------------------------------------------

# Each fact goes into the state folder before the change it covers, so unlink can
# undo a run that stopped part way. No state file is ever sourced as shell.
cmd_link() { # cmd_link <tree>
  local tree="$1" dir state host app_db idp_meta sp_meta raw b64 f line count active idp_id sp_id cert
  check_tree "$tree"
  state="$(state_dir "$tree")"
  if [[ -d "$state" ]]; then printf '%s is already linked\n' "$tree"; return 0; fi
  for f in idp-metadata.xml sp-metadata.xml; do
    [[ -s "$SAML_DIR/generated/$f" ]] || die "no $SAML_DIR/generated/$f; run 'ohrm saml up' first"
  done
  dir="$(test_root)/$tree"
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

  log "recording $tree's starting state in $state"
  run mkdir -p "$state"
  printf '%s\n' "$app_db" | write_file "$state/app_db"
  # The x keeps a row holding an empty value apart from no row at all.
  raw="$(db_sql "$app_db" <<< "SELECT REPLACE(TO_BASE64(value), CHAR(10), '') FROM ohrm_config WHERE property = 'domain.name';" && printf x)"
  raw="${raw%x}"
  if [[ -z "$raw" ]]; then
    remove_path "$state"
    die "$tree has no domain.name row in ohrm_config of database $app_db"
  fi
  b64="${raw%$'\n'}"
  printf '%s\n' "$b64" | write_file "$state/domain_name.b64"

  log "setting $tree's domain.name to $host"
  db_sql "$app_db" > /dev/null <<< "UPDATE ohrm_config SET value = FROM_BASE64('$(printf %s "$host" | to_b64)') WHERE property = 'domain.name';"

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

  for f in "$IDP_KEY_FILE" "$IDP_CRT_FILE"; do
    line="/$IDP_CERT_DIR/$f"
    if ! grep -qxF -- "$line" "$dir/.git/info/exclude" 2>/dev/null; then
      append_line "$state/exclude_added" "$line"
      append_line "$dir/.git/info/exclude" "$line"
    fi
  done

  active="$(db_sql "$app_db" <<< "SELECT COUNT(*) FROM ohrm_saml_provider WHERE type = 'IDP' AND status = 1;")"
  if [[ "$active" =~ ^[0-9]+$ ]] && (( active > 0 )); then
    warn "warning: $tree already has $active active IdP provider row(s), so its login page will offer more than one SAML provider"
  fi

  log "adding the 'SAML test container' IdP and SP rows to $app_db.ohrm_saml_provider"
  idp_id="$(db_sql "$app_db" <<< "INSERT INTO ohrm_saml_provider (name, type, metadata, username_key, status) VALUES ('SAML test container', 'IDP', FROM_BASE64('$idp_meta'), 'username', 1); SELECT LAST_INSERT_ID();")"
  check_row_id IdP "$idp_id"
  printf '%s\n' "$idp_id" | write_file "$state/idp_row_id"
  # One transaction, so a failed attribute insert leaves no SP row unrecorded.
  sp_id="$(db_sql "$app_db" <<< "START TRANSACTION; INSERT INTO ohrm_saml_provider (name, type, metadata, username_key, status) VALUES ('SAML test container', 'SP', FROM_BASE64('$sp_meta'), NULL, 1); SET @sp = LAST_INSERT_ID(); INSERT INTO ohrm_saml_provider_attribute (provider_id, token_id, claim_name) VALUES (@sp, 2, 'username'), (@sp, 3, 'firstName'), (@sp, 5, 'email'), (@sp, 6, 'employeeId'); COMMIT; SELECT @sp;")"
  check_row_id SP "$sp_id"
  printf '%s\n' "$sp_id" | write_file "$state/sp_row_id"

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

  if web_running; then
    log "clearing $tree's symfony cache"
    run docker exec -w "$CONTAINER_TEST_ROOT/$tree/symfony" "$WEB_CONTAINER" php symfony cc
  else
    printf 'web container is down; later run: ohrm sf %s -- php symfony cc\n' "$tree"
  fi

  log "$tree is linked"
  printf '  tree login: https://%s/auth/login\n' "$host"
  printf '  apps page:  %s\n' "$SAML_URL"
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
  link)
    if [[ -z "$tree" ]]; then printf 'ohrm saml: %s needs a tree\n\n' "$subcmd" >&2; usage; fi
    "cmd_$subcmd" "$tree" ;;
  *)
    printf 'ohrm saml: unknown command %s\n\n' "$subcmd" >&2; usage ;;
esac
