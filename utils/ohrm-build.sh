#!/usr/bin/env bash
#
# Rebuild a working copy after a branch switch: symfony cache, Doctrine model and
# plugin assets, the Vue app, the legacy Angular client, and — only when asked —
# a fresh dev-data load. Normally reached as `ohrm build` (see utils/ohrm-shell.sh).
#
# Usage:
#   ohrm build [steps...] [working-copy] [--data] [--serial] [--yes]
#
#   ohrm build                  # sf + vue + client (the default; same as `all`)
#   ohrm build --data           # the same, plus a fresh dev-data load
#   ohrm build vue              # one step
#   ohrm build sf client king   # several steps, in working copy king
#   ohrm build data             # only the dev-data load
#
# Steps:
#   sf      symfony: php symfony cc, doctrine:build-model, orangehrm:publish-assets
#   vue     symfony/web/vue-app: npm ci && npm run build      (Node 14, nvm `latest`)
#   client  symfony/web/client: npm install, bower install, gulp build
#                                                            (Node 6, nvm `default`)
#   data    DESTRUCTIVE: devTools/load/dev-load.sh drops and reloads the working
#           copy's app and test databases, then clears the symfony cache again
#   all     sf vue client — never data, which is only run when named
#
# Order: sf runs first, on its own, and a failure there stops the run, because the
# data load boots the Doctrine model that sf generates. data, vue and client need
# nothing from each other, so they then run in parallel with every output line
# prefixed by its step name; --serial runs them one after another instead.
#
# gulp deletes symfony/web/client/build before it builds, so a failed client step
# leaves the working copy without a client bundle until a build succeeds.
#
# The client step depends on the web container's architecture:
#   aarch64 (Apple Silicon)  utils/web83-client-build.sh, the emulated amd64
#                            builder; amd64 emulation is registered if missing
#   x86_64  (Linux)          natively inside the web container
#
# data asks for confirmation, naming the databases, when stdin is a terminal;
# --yes (-y) skips it. Without a terminal and without --yes it refuses.
#
# Working copy: resolved the way `ohrm` resolves it — the argument, then your
# CWD if you are inside a working copy, then $OHRM_WC, then trunk. Steps are a
# closed set, so any other bare argument is read as the working copy.
#
# Environment overrides: OHRM_WEB_CONTAINER, OHRM_TEST_SRC_PATH, OHRM_DEFAULT_WC,
# OHRM_DB_PASS (MySQL root password for the data load, default 1234),
# OHRM_BUILD_ARCH (skips asking the container its architecture). OHRM_TTY=1/0
# forces the data confirmation on or off. OHRM_DRY_RUN=1 prints each step's
# command instead of running it (used by utils/tests/ohrm-build-test.sh).
set -euo pipefail

CONTAINER="${OHRM_WEB_CONTAINER:-dev_web_83_ubuntu}"
DEFAULT_WC="${OHRM_DEFAULT_WC:-trunk}"
DB_PASS="${OHRM_DB_PASS:-1234}"

# Where the TEST tree is mounted *inside* the container. Fixed by the bind mount
# in docker-compose.yml, regardless of which host path is mounted there.
CONTAINER_TEST_ROOT="/var/www/html/OHRMStandalone/TEST"

# nvm is not on PATH in the container's non-interactive shells.
NVM='source /root/.nvm/nvm.sh'

case "${OHRM_TTY:-auto}" in
  1)  interactive=1 ;;
  0)  interactive=0 ;;
  *)  [[ -t 0 ]] && interactive=1 || interactive=0 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '==> %s\n' "$*"; }
die() { printf 'ohrm build: %s\n' "$1" >&2; exit "${2:-1}"; }

# The long help is the comment header above, from "Usage:" to the end of the
# block — so there is only one copy of it to keep correct.
help_text() {
  awk '/^# Usage:/{f=1} f{ if ($0 !~ /^#/) exit; sub(/^#[ ]?/, ""); print }' "${BASH_SOURCE[0]}"
}

usage() {
  printf 'usage: ohrm build [sf|vue|client|data|all...] [working-copy] [--data] [--serial] [--yes]\n' >&2
  printf "run 'ohrm build --help' for the full description\n" >&2
  exit 2
}

# Path to the TEST tree on the *host*. Mirrors docker-compose's
# ${OHRM_TEST_SRC_PATH:-./html/OHRMStandalone/TEST}, including reading .env.
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

# Absolute, symlink-resolved path, or empty if it doesn't exist. Used instead of
# realpath(1), which isn't reliably present on macOS.
abs() { ( cd "$1" 2>/dev/null && pwd -P ) || true; }

working_copies() {
  find "$1" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort
}

# The working copy containing the current directory, if we're inside one.
wc_from_cwd() {
  local root_abs cwd rest
  root_abs="$(abs "$1")"
  [[ -n "$root_abs" ]] || return 0
  cwd="$(pwd -P)"
  [[ "$cwd" == "$root_abs/"* ]] || return 0
  rest="${cwd#"$root_abs"/}"
  printf '%s\n' "${rest%%/*}"
}

# dbname= out of one top-level section of databases.yml; empty if the file or
# the section is missing.
yml_dbname() {
  [[ -f "$1" ]] || return 0
  awk -v want="$2" '
    /^[A-Za-z_]+:/ { sec=$0; sub(":.*","",sec) }
    sec==want && match($0, /dbname=[A-Za-z0-9_]+/) {
      print substr($0, RSTART+7, RLENGTH-7); exit
    }' "$1"
}

## ---------------------------------------------------------------------------
## Arguments
## ---------------------------------------------------------------------------

steps=(); wc_arg=""; with_data=0; serial=0; assume_yes=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)   help_text; exit 0 ;;
    --data)      with_data=1 ;;
    --serial)    serial=1 ;;
    -y|--yes)    assume_yes=1 ;;
    -*)          printf 'ohrm build: unknown option %s\n\n' "$1" >&2; usage ;;
    sf|vue|client|data) steps+=("$1") ;;
    all)         steps+=(sf vue client) ;;
    *)           [[ -z "$wc_arg" ]] || die "two working copies given: $wc_arg and $1" 2
                 wc_arg="$1" ;;
  esac
  shift
done
[[ ${#steps[@]} -gt 0 ]] || steps=(sf vue client)
[[ $with_data -eq 0 ]] || steps+=(data)

wants() { [[ " ${steps[*]} " == *" $1 "* ]]; }

# Execution order, independent of the order the steps were named in: sf alone,
# then the parallel group.
run_sf=0; group=()
wants sf && run_sf=1
for s in data vue client; do wants "$s" && group+=("$s"); done

test_root="$(host_test_root)"
[[ -d "$test_root" ]] || die "TEST source path $test_root does not exist"

wc="${wc_arg:-$(wc_from_cwd "$test_root")}"
wc="${wc:-${OHRM_WC:-$DEFAULT_WC}}"
if [[ ! -d "$test_root/$wc" ]]; then
  {
    printf "ohrm build: no working copy '%s' under %s\n" "$wc" "$test_root"
    printf 'available: %s\n' "$(working_copies "$test_root" | paste -sd' ' -)"
  } >&2
  exit 1
fi

step_dir() {
  case "$1" in
    sf)     printf 'symfony\n' ;;
    vue)    printf 'symfony/web/vue-app\n' ;;
    client) printf 'symfony/web/client\n' ;;
    data)   printf 'devTools/load\n' ;;
  esac
}

# Every directory is checked before anything runs, so a working copy that can't
# take one of the steps doesn't get half-built.
for s in "${steps[@]}"; do
  d="$(step_dir "$s")"
  [[ -d "$test_root/$wc/$d" ]] || die "working copy '$wc' has no $d — can't run the $s step"
done

## ---------------------------------------------------------------------------
## Confirmation, preflight
## ---------------------------------------------------------------------------

confirm_data() {
  local yml="$test_root/$wc/symfony/config/databases.yml" db test_db what reply=""
  db="$(yml_dbname "$yml" all)"
  test_db="$(yml_dbname "$yml" test)"
  what="${db:-the database configured in $wc/symfony/config/databases.yml}"
  [[ -z "$test_db" ]] || what="$what and $test_db"

  [[ $assume_yes -eq 0 ]] || return 0
  [[ $interactive -eq 1 ]] \
    || die "the data step drops and reloads $what — pass --yes to run it without a terminal"

  printf 'The data step DROPS and reloads %s (working copy %s).\n' "$what" "$wc"
  read -r -p 'Proceed? [y/N] ' reply || true
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    printf 'ohrm build: not run\n'
    exit 1
  fi
}

wants data && confirm_data

arch=""
if [[ -z "${OHRM_DRY_RUN:-}" ]]; then
  if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]]; then
    die "container $CONTAINER is not running — start it with 'docker-compose up -d ubuntuweb83'"
  fi
fi
if wants client; then
  arch="${OHRM_BUILD_ARCH:-$(docker exec "$CONTAINER" uname -m 2>/dev/null || true)}"
  [[ -n "$arch" ]] || die "could not ask $CONTAINER for its architecture"
fi

## ---------------------------------------------------------------------------
## Steps
## ---------------------------------------------------------------------------

# Runs a script in the web container, in a directory of the working copy — or,
# under OHRM_DRY_RUN, prints the command instead.
in_ctr() { # in_ctr <dir relative to the working copy> <script>
  local cmd=(docker exec -w "$CONTAINER_TEST_ROOT/$wc/$1" "$CONTAINER" bash -lc "$2")
  if [[ -n "${OHRM_DRY_RUN:-}" ]]; then printf '%s\n' "${cmd[*]}"; return 0; fi
  "${cmd[@]}"
}

# Registering amd64 emulation does not survive a Docker restart, hence checking
# on every run rather than once.
ensure_amd64() {
  docker run --rm --platform linux/amd64 busybox true >/dev/null 2>&1 && return 0
  log "registering amd64 emulation in the Docker VM"
  docker run --privileged --rm tonistiigi/binfmt --install amd64 >/dev/null
}

step_sf() {
  in_ctr symfony 'php symfony cc && php symfony doctrine:build-model && php symfony orangehrm:publish-assets'
}

step_vue() {
  in_ctr symfony/web/vue-app "$NVM && nvm use latest && npm ci && npm run build"
}

# dev-load.sh cds relative to devTools/load, so it must start there. Its exit
# status is only that of its last loader; earlier failures show in the output.
step_data() {
  in_ctr devTools/load "bash dev-load.sh $(printf '%q' "$DB_PASS") && cd ../../symfony && php symfony cc"
}

# gulp 3.9 and node-sass have no arm64 build, so on Apple Silicon the client is
# built in the emulated amd64 builder rather than in the (arm64) web container.
step_client() {
  case "$arch" in
    aarch64|arm64)
      local cmd=("$repo_root/utils/web83-client-build.sh" --wc "$wc" build)
      if [[ -n "${OHRM_DRY_RUN:-}" ]]; then printf '%s\n' "${cmd[*]}"; return 0; fi
      ensure_amd64 && "${cmd[@]}" ;;
    *)
      in_ctr symfony/web/client \
        "$NVM && nvm use default && node -v && npm install && bower install --allow-root && gulp build" ;;
  esac
}

## ---------------------------------------------------------------------------
## Run
## ---------------------------------------------------------------------------

plan="$wc: "
[[ $run_sf -eq 0 ]] || plan+="sf"
if [[ ${#group[@]} -gt 0 ]]; then
  [[ $run_sf -eq 0 ]] || plan+=", then "
  plan+="$(printf '%s + ' "${group[@]}" | sed 's/ + $//')"
  if [[ ${#group[@]} -gt 1 ]]; then
    [[ $serial -eq 1 ]] && plan+=" one after another" || plan+=" in parallel"
  fi
fi
log "$plan"

prefix() { awk -v p="[$1] " '{ print p $0; fflush() }'; }

if [[ -n "${OHRM_DRY_RUN:-}" ]]; then
  [[ $run_sf -eq 0 ]] || step_sf | prefix sf
  for s in ${group[@]+"${group[@]}"}; do "step_$s" | prefix "$s"; done
  exit 0
fi

results="$(mktemp)"
trap 'rm -f "$results"' EXIT

# Records "<step> <exit status> <seconds>" in $results, which the summary reads —
# a step run in the background cannot hand its status back any other way.
run_step() {
  local s="$1" start=$SECONDS rc=0
  "step_$s" || rc=$?
  printf '%s %s %s\n' "$s" "$rc" "$((SECONDS - start))" >> "$results"
  return $rc
}

summary() {
  local s rc secs failed=0
  log "summary ($wc)"
  while read -r s rc secs; do
    if [[ "$rc" -eq 0 ]]; then
      printf '   %-7s ok      %dm%02ds\n' "$s" $((secs / 60)) $((secs % 60))
    else
      failed=1
      printf '   %-7s FAILED  %dm%02ds  (exit %s)\n' "$s" $((secs / 60)) $((secs % 60)) "$rc"
      [[ "$s" != client ]] \
        || printf '           %s has no client bundle until a client build succeeds\n' "$wc"
    fi
  done < "$results"
  return $failed
}

if [[ $run_sf -eq 1 ]]; then
  log "[sf] clearing the cache, building the Doctrine model, publishing assets"
  if ! run_step sf; then
    summary || true
    die "sf failed — not starting the remaining steps"
  fi
fi

if [[ $serial -eq 1 || ${#group[@]} -eq 1 ]]; then
  for s in ${group[@]+"${group[@]}"}; do
    log "[$s] starting"
    run_step "$s" || true
  done
elif [[ ${#group[@]} -gt 1 ]]; then
  # Background jobs of a non-interactive shell ignore SIGINT, so Ctrl-C would
  # otherwise kill only this script. `docker exec` does not forward the signal
  # into the container, so a build already running there still runs to the end.
  trap 'trap "" TERM; kill 0; exit 130' INT TERM
  pids=()
  for s in "${group[@]}"; do
    log "[$s] starting"
    { run_step "$s" </dev/null 2>&1 | prefix "$s"; } &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || true; done
fi

summary
