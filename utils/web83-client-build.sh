#!/usr/bin/env bash
#
# Build the legacy Angular client (<working-copy>/symfony/web/client) in an
# on-demand AMD64 container (web83_client_build in docker-compose.override.yml),
# so ubuntuweb83 can stay a native arm64 image.
#
# The client toolchain (gulp 3.9 + gulp-sass/node-sass on node 6) has no working
# arm64 build, hence amd64 — which runs under Rosetta emulation on Apple Silicon.
#
# Usage:
#   utils/web83-client-build.sh [--wc <working-copy>] <task> [args...]
#
#   install                 # npm install + bower install --allow-root
#   build                   # install, then `gulp build`  (production)
#   inject                  # install, then `gulp inject` (development)  [default]
#   gulp <task> [args...]   # install, then an arbitrary gulp task
#   shell                   # interactive shell in the builder, node 6 selected
#   clean                   # drop this tree's node_modules volume + build/.tmp
#
# Working copy: which tree under OHRMStandalone/TEST gets built is resolved the
# same way `ohrm` resolves it (see utils/ohrm-shell.sh) —
#
#   1. --wc, if given                         (--wc amber)
#   2. inferred from your CWD, if you are already inside a working copy
#   3. $OHRM_WC, if exported
#   4. trunk
#
# node_modules never lives on the host bind mount: it is arch-specific (node-sass
# is built for amd64 here, while ubuntuweb83 is arm64) and slow over virtiofs, so
# each working copy gets its own volume. trunk uses the one declared on the
# service; every other tree gets web83_client_node_modules_<wc> — the same name
# utils/ohrm-tree.sh build-client uses, so the two entry points share a tree's
# installed modules instead of each paying for its own npm install.
#
# The container is removed after each run (--rm).
#
# OHRM_DRY_RUN=1 prints the command instead of running it (used by
# utils/tests/web83-client-build-test.sh).
set -euo pipefail

# Captured before the cd to the repo root below, because the working copy can be
# inferred from wherever the caller actually was.
invocation_dir="$(pwd -P)"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SERVICE="web83_client_build"
DEFAULT_WC="${OHRM_DEFAULT_WC:-trunk}"
CLIENT_REL="symfony/web/client"

# Where the TEST tree is mounted *inside* the builder. Fixed by the bind mount in
# docker-compose.override.yml, regardless of which host path is mounted there.
CONTAINER_TEST_ROOT="/var/www/html/OHRMStandalone/TEST"

# The amd64 builder doesn't mount ubuntuweb83's .bashrc, so nvm isn't auto-loaded
# in its login shell — source it explicitly, then select node 6 (the default alias).
INSTALL='source /root/.nvm/nvm.sh && nvm use default && node -v && npm install && bower install --allow-root'

die() { printf '%s: %s\n' "${0##*/}" "$1" >&2; exit "${2:-1}"; }

# The long help is the comment header above, from "Usage:" to the end of the
# block — so there is only one copy of it to keep correct.
help_text() {
  awk '/^# Usage:/{f=1} f{ if ($0 !~ /^#/) exit; sub(/^#[ ]?/, ""); print }' "${BASH_SOURCE[0]}"
}

usage() {
  printf 'usage: %s [--wc <working-copy>] [install|build|inject|gulp <task>...|shell|clean]\n' "${0##*/}" >&2
  printf "run '%s --help' for the full description\n" "${0##*/}" >&2
  exit 2
}

# Absolute, symlink-resolved path, or empty if it doesn't exist. Used instead of
# realpath(1), which isn't reliably present on macOS.
abs() { ( cd "$1" 2>/dev/null && pwd -P ) || true; }

# Path to the TEST tree on the *host*. Mirrors docker-compose's
# ${OHRM_TEST_SRC_PATH:-./html/OHRMStandalone/TEST}, including reading .env, so
# this keeps working when TEST is mounted from a checkout outside the repo.
# Relative paths resolve against the repo root, as compose does.
host_test_root() {
  local path="${OHRM_TEST_SRC_PATH:-}"
  if [[ -z "$path" && -f "$repo_root/.env" ]]; then
    path="$(grep -E '^OHRM_TEST_SRC_PATH=' "$repo_root/.env" | tail -n1 | cut -d= -f2- || true)"
  fi
  path="${path:-./html/OHRMStandalone/TEST}"
  [[ "$path" == /* ]] || path="$repo_root/${path#./}"
  printf '%s\n' "$path"
}

working_copies() {
  find "$1" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort
}

# The working copy containing the directory we were called from, if any.
wc_from_cwd() {
  local root_abs rest
  root_abs="$(abs "$1")"
  [[ -n "$root_abs" ]] || return 0
  [[ "$invocation_dir" == "$root_abs/"* ]] || return 0
  rest="${invocation_dir#"$root_abs"/}"
  printf '%s\n' "${rest%%/*}"
}

die_unknown_wc() {
  {
    printf '%s: no working copy %s under %s\n' "${0##*/}" "'$1'" "$2"
    printf 'available: %s\n' "$(working_copies "$2" | paste -sd' ' -)"
  } >&2
  exit 1
}

wc_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) help_text; exit 0 ;;
    --wc)      [[ $# -ge 2 ]] || die '--wc needs a working copy' 2
               wc_arg="$2"; shift 2 ;;
    --wc=*)    wc_arg="${1#--wc=}"; shift ;;
    --)        shift; break ;;
    -*)        printf '%s: unknown option %s\n' "${0##*/}" "$1" >&2; usage ;;
    *)         break ;;
  esac
done

task="${1:-inject}"
shift || true

test_root="$(host_test_root)"
[[ -d "$test_root" ]] || die "TEST source path $test_root does not exist"

wc="${wc_arg:-$(wc_from_cwd "$test_root")}"
wc="${wc:-${OHRM_WC:-$DEFAULT_WC}}"

[[ -d "$test_root/$wc" ]] || die_unknown_wc "$wc" "$test_root"
[[ -d "$test_root/$wc/$CLIENT_REL" ]] \
  || die "working copy '$wc' has no $CLIENT_REL — nothing to build"

client_dir="$CONTAINER_TEST_ROOT/$wc/$CLIENT_REL"

# Compose prefixes the volumes it declares with the project name; the per-tree
# ones are created verbatim by `run -v`, so the two are spelled differently.
project="${COMPOSE_PROJECT_NAME:-$(basename "$repo_root")}"
if [[ "$wc" == "$DEFAULT_WC" ]]; then
  node_modules_vol="${project}_web83_client_node_modules"
else
  node_modules_vol="web83_client_node_modules_$wc"
fi

# clean is host-side + docker volume work; it never starts the builder.
if [[ "$task" == "clean" ]]; then
  build_dirs=("$test_root/$wc/$CLIENT_REL/build" "$test_root/$wc/$CLIENT_REL/.tmp")
  if [[ -n "${OHRM_DRY_RUN:-}" ]]; then
    printf 'docker volume rm %s\n' "$node_modules_vol"
    printf 'rm -rf %s\n' "${build_dirs[*]}"
    exit 0
  fi
  echo ">> [clean] $wc: removing $node_modules_vol and generated build/.tmp"
  docker volume rm "$node_modules_vol" || true
  rm -rf "${build_dirs[@]}"
  echo ">> Cleaned. The next build for '$wc' will reinstall node_modules from scratch."
  exit 0
fi

case "$task" in
  install) remote="$INSTALL" ;;
  build)   remote="$INSTALL && gulp build" ;;
  inject)  remote="$INSTALL && gulp inject" ;;
  gulp)    remote="$INSTALL && gulp $*" ;;
  # A login shell may cd elsewhere on the way in; `cd $PWD` (expanded inside the
  # container, hence the single quotes) puts us back in the client directory.
  shell)   remote='source /root/.nvm/nvm.sh && nvm use default >/dev/null && cd $PWD && exec bash' ;;
  *)       usage ;;
esac

cd "$repo_root"   # compose resolves the source mount and override file from here

# trunk is exactly what the service definition already points at, mounts
# included, so it takes no overrides — and must not be given a CLI -v, which
# would create a second, unprefixed volume beside the project's own.
cmd=(docker-compose run --rm)
if [[ "$wc" != "$DEFAULT_WC" ]]; then
  cmd+=(-w "$client_dir" -v "$node_modules_vol:$client_dir/node_modules")
fi
cmd+=("$SERVICE" "$remote")

if [[ -n "${OHRM_DRY_RUN:-}" ]]; then printf '%s\n' "${cmd[*]}"; exit 0; fi

echo ">> [$task] $wc: amd64 client build via '$SERVICE' (emulated on Apple Silicon; the install step can take a few minutes)..."
# entrypoint is `bash -lc`, so the whole remote string is executed by a login shell.
exec "${cmd[@]}"
