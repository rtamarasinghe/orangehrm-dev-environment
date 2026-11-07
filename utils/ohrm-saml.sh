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
# 30 s for SimpleSAMLphp to answer inside the container.
#
# Environment overrides: OHRM_TEST_SRC_PATH, OHRM_WEB_CONTAINER, OHRM_DB_PASS
# (MySQL root password, default 1234), and OHRM_WEB_RUNNING=true/false, which
# stands in for asking docker whether the web container is running. OHRM_TTY=1/0
# forces the /etc/hosts prompt on or off. OHRM_DRY_RUN=1 prints each change instead
# of making it (used by utils/tests/ohrm-saml-test.sh). OHRM_SAML_DIR,
# OHRM_NGINX_DIR and OHRM_HOSTS_FILE stand in for custom-compose/config/saml,
# config/nginx and /etc/hosts.
set -euo pipefail

SAML_CONTAINER=dev_saml
NGINX_CONTAINER=dev_nginx
DB_CONTAINER=dev_mariadb_101115
DB_PASS="${OHRM_DB_PASS:-1234}"
SAML_URL="https://saml.test/"
HOSTS_LINE="127.0.0.1 saml.test"

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

log() { printf '==> %s\n' "$*"; }
die() { printf 'ohrm saml: %s\n' "$1" >&2; exit "${2:-1}"; }

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
  *)
    printf 'ohrm saml: unknown command %s\n\n' "$subcmd" >&2; usage ;;
esac
