#!/usr/bin/env bash
#
# Open a shell (or run a command) inside ubuntuweb83, already cd'd into one of
# the directories you actually work in — without having to remember, or type,
# the full /var/www/html/OHRMStandalone/TEST/<working-copy>/... path.
#
# Meant to be called by memory from anywhere on the host. To wire up the `ohrm`
# shell function, run:
#
#     utils/ohrm-shell.sh install
#
# Usage:
#   ohrm [destination] [working-copy] [-- command...]
#
#   ohrm                     # <wc>/symfony            (symfony is the default)
#   ohrm dt                  # <wc>/devTools
#   ohrm vue                 # <wc>/symfony/web/vue-app
#   ohrm client              # <wc>/symfony/web/client
#   ohrm feature-x           # feature-x/symfony       (see working copies, below)
#   ohrm vue feature-x       # feature-x/symfony/web/vue-app
#   ohrm sf -- php symfony cc    # run a command there instead of opening a shell
#   ohrm sql                 # mysql console on the dev database
#   ohrm sql -- 'show databases;'
#   ohrm ls                  # list the working copies under TEST
#
#   ohrm install             # add the `ohrm` function to your shell config
#   ohrm install --rc ~/.zshrc --rc ~/.bash_profile   # target specific files
#   ohrm install --yes       # skip the confirmation prompt
#
# Working copies: `trunk` is only the most common checkout, not the only one, so
# which one you land in is resolved in this order —
#
#   1. the argument, if given                 (ohrm vue feature-x)
#   2. inferred from your host CWD, if you're already somewhere under a
#      working copy                           (cd .../TEST/feature-x/... ; ohrm)
#   3. $OHRM_WC, if exported                  (export OHRM_WC=feature-x)
#   4. `trunk`
#
# Because destinations are a closed set, a lone argument that isn't one of them
# is read as a working copy — so `ohrm feature-x` means feature-x/symfony.
#
# Environment overrides: OHRM_WEB_CONTAINER, OHRM_TEST_SRC_PATH, OHRM_DEFAULT_WC,
# OHRM_DB_HOST, OHRM_DB_USER, OHRM_DB_PASS. OHRM_TTY=1/0 forces TTY allocation
# on or off (otherwise it follows whether stdin is a terminal). OHRM_DRY_RUN=1
# prints the docker command instead of running it (used by
# utils/tests/ohrm-shell-test.sh).
set -euo pipefail

CONTAINER="${OHRM_WEB_CONTAINER:-dev_web_83_ubuntu}"
DEFAULT_WC="${OHRM_DEFAULT_WC:-trunk}"
DB_HOST="${OHRM_DB_HOST:-db101115}"
DB_USER="${OHRM_DB_USER:-root}"
DB_PASS="${OHRM_DB_PASS:-1234}"

# Where the TEST tree is mounted *inside* the container. Fixed by the bind mount
# in docker-compose.yml, regardless of which host path is mounted there.
CONTAINER_TEST_ROOT="/var/www/html/OHRMStandalone/TEST"

# `docker exec -t` fails outright when there is no terminal to attach, which is
# exactly the case when a `-- command` form is used from a script or a pipeline.
case "${OHRM_TTY:-auto}" in
  1)  TTY_FLAGS="-it" ;;
  0)  TTY_FLAGS="-i" ;;
  *)  [[ -t 0 ]] && TTY_FLAGS="-it" || TTY_FLAGS="-i" ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The long help is the comment header above, from "Usage:" to the end of the
# block — so there is only one copy of it to keep correct.
help_text() {
  awk '/^# Usage:/{f=1} f{ if ($0 !~ /^#/) exit; sub(/^#[ ]?/, ""); print }' "${BASH_SOURCE[0]}"
}

# Absolute path to this script, so the installed function keeps working from any
# directory and regardless of how the script was invoked.
script_abs="$repo_root/utils/$(basename "${BASH_SOURCE[0]}")"

# Identifies a block this script wrote, so `install` can recognise its own work.
INSTALL_MARKER="# ohrm — shell into ubuntuweb83 (added by utils/ohrm-shell.sh install)"

usage() {
  printf 'usage: ohrm [destination] [working-copy] [-- command...]\n' >&2
  printf 'destinations: sf (default) | dt | vue | client | sql | ls | install\n' >&2
  printf "run 'ohrm --help' for the full description\n" >&2
  exit "${1:-2}"
}

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

# Absolute, symlink-resolved path, or empty if it doesn't exist. Used instead of
# realpath(1), which isn't reliably present on macOS.
abs() { ( cd "$1" 2>/dev/null && pwd -P ) || true; }

working_copies() {
  local root="$1"
  find "$root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort
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

die_unknown_wc() {
  local wc="$1" root="$2"
  {
    printf "ohrm: no working copy '%s' under %s\n" "$wc" "$root"
    printf 'available: %s\n' "$(working_copies "$root" | paste -sd' ' -)"
  } >&2
  exit 1
}

# The shell config that the user's login shell actually reads. On macOS, bash
# login shells read .bash_profile and never .bashrc; elsewhere it is the reverse.
default_rc() {
  case "$(basename "${SHELL:-bash}")" in
    zsh)  printf '%s\n' "$HOME/.zshrc" ;;
    bash) if [[ "$(uname -s)" == "Darwin" ]]; then
            printf '%s\n' "$HOME/.bash_profile"
          else
            printf '%s\n' "$HOME/.bashrc"
          fi ;;
    *)    printf '%s\n' "$HOME/.profile" ;;
  esac
}

# Add the `ohrm` shell function to one or more shell config files, after showing
# exactly what will be written and asking for confirmation.
do_install() {
  local assume_yes=0 rc existing status
  local -a targets=() pending=()
  local conflict=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) assume_yes=1; shift ;;
      --rc)     [[ $# -ge 2 ]] || { printf 'ohrm: --rc needs a file\n' >&2; usage 2; }
                targets+=("$2"); shift 2 ;;
      *)        printf 'ohrm: unknown install option %s\n\n' "$1" >&2; usage 2 ;;
    esac
  done
  [[ ${#targets[@]} -gt 0 ]] || targets=("$(default_rc)")

  local fn_line="ohrm() { $script_abs \"\$@\"; }"

  # Classify every target before writing or prompting, so an already-installed
  # or conflicting file never produces a pointless prompt.
  for rc in "${targets[@]}"; do
    existing=""
    [[ -f "$rc" ]] && existing="$(grep -E '^[[:space:]]*ohrm[[:space:]]*\(\)' "$rc" | head -n1 || true)"
    if [[ -z "$existing" ]]; then
      pending+=("$rc")
    elif [[ "$existing" == *"$script_abs"* ]]; then
      printf 'ohrm: already installed in %s\n' "$rc"
    else
      conflict=1
      printf 'ohrm: an ohrm function already exists in %s:\n' "$rc" >&2
      printf '    %s\n' "$existing" >&2
      printf 'ohrm: leaving it alone — remove that line first, or use --rc to target another file\n' >&2
    fi
  done

  if [[ ${#pending[@]} -eq 0 ]]; then
    return $conflict
  fi

  printf 'Will append to %s:\n\n' "$(printf '%s, ' "${pending[@]}" | sed 's/, $//')"
  printf '    %s\n    %s\n\n' "$INSTALL_MARKER" "$fn_line"

  # Point out the other configs that exist but are not being written, since a
  # machine with both bash and zsh configs will otherwise only get one of them.
  local -a others=()
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    [[ -f "$rc" ]] || continue
    [[ " ${targets[*]} " == *" $rc "* ]] || others+=("$rc")
  done
  [[ ${#others[@]} -gt 0 ]] && \
    printf 'Other shell configs found: %s  (target one with --rc FILE)\n\n' "${others[*]}"

  if [[ -n "${OHRM_DRY_RUN:-}" ]]; then
    printf 'ohrm: dry run, nothing written\n'
    return 0
  fi

  if [[ $assume_yes -eq 0 ]]; then
    local reply=""
    read -r -p 'Proceed? [y/N] ' reply || true
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
      printf 'ohrm: not installed\n'
      return 0
    fi
  fi

  for rc in "${pending[@]}"; do
    printf '\n%s\n%s\n' "$INSTALL_MARKER" "$fn_line" >> "$rc"
    printf 'ohrm: added to %s — start a new shell, or run: source %s\n' "$rc" "$rc"
  done
  return $conflict
}

# Split the arguments at `--`: everything before it selects where to go,
# everything after it is the command to run there.
ohrm_args=(); command_args=(); seen_sep=0
for arg in "$@"; do
  if [[ $seen_sep -eq 0 && "$arg" == "--" ]]; then seen_sep=1; continue; fi
  if [[ $seen_sep -eq 1 ]]; then command_args+=("$arg"); else ohrm_args+=("$arg"); fi
done

case "${ohrm_args[0]:-}" in
  -h|--help) help_text; exit 0 ;;
  -*)        printf 'ohrm: unknown option %s\n\n' "${ohrm_args[0]}" >&2; usage 2 ;;
esac

# `install` takes its own flags, so it is handled before the destination /
# working-copy parsing below.
if [[ "${ohrm_args[0]:-}" == "install" ]]; then
  do_install "${ohrm_args[@]:1}"
  exit $?
fi

# First argument is a destination if it names one; otherwise it's a working copy
# and the destination falls back to symfony.
dest="sf"; wc_arg=""
case "${ohrm_args[0]:-}" in
  "")                          ;;
  sf|dt|vue|client|sql|ls)     dest="${ohrm_args[0]}"; wc_arg="${ohrm_args[1]:-}" ;;
  *)                           wc_arg="${ohrm_args[0]}" ;;
esac

test_root="$(host_test_root)"

if [[ "$dest" == "ls" ]]; then
  [[ -d "$test_root" ]] || { printf 'ohrm: TEST source path %s does not exist\n' "$test_root" >&2; exit 1; }
  printf 'working copies under %s:\n' "$test_root"
  working_copies "$test_root" | sed 's/^/  /'
  exit 0
fi

if [[ "$dest" == "sql" ]]; then
  cmd=(docker exec "$TTY_FLAGS" "$CONTAINER" mysql "-u$DB_USER" "-p$DB_PASS" "-h$DB_HOST")
  [[ ${#command_args[@]} -gt 0 ]] && cmd+=(-e "${command_args[*]}")
  if [[ -n "${OHRM_DRY_RUN:-}" ]]; then printf '%s\n' "${cmd[*]}"; exit 0; fi
  exec "${cmd[@]}"
fi

case "$dest" in
  sf)     subpath="symfony" ;;
  dt)     subpath="devTools" ;;
  vue)    subpath="symfony/web/vue-app" ;;
  client) subpath="symfony/web/client" ;;
esac

wc="${wc_arg:-$(wc_from_cwd "$test_root")}"
wc="${wc:-${OHRM_WC:-$DEFAULT_WC}}"

[[ -d "$test_root" ]] || { printf 'ohrm: TEST source path %s does not exist\n' "$test_root" >&2; exit 1; }
[[ -d "$test_root/$wc" ]] || die_unknown_wc "$wc" "$test_root"

container_path="$CONTAINER_TEST_ROOT/$wc/$subpath"
# The host tree is bind-mounted 1:1 onto CONTAINER_TEST_ROOT, so a host-side
# check tells us whether the container path exists — and fails with a useful
# message instead of dropping us into a directory that isn't there.
if [[ ! -d "$test_root/$wc/$subpath" ]]; then
  printf 'ohrm: %s does not exist in working copy %s\n' "$container_path" "$wc" >&2
  exit 1
fi

cmd=(docker exec -w "$container_path" "$TTY_FLAGS" "$CONTAINER")
if [[ ${#command_args[@]} -gt 0 ]]; then
  cmd+=(bash -lc "${command_args[*]}")
else
  cmd+=(bash -l)
fi

if [[ -n "${OHRM_DRY_RUN:-}" ]]; then printf '%s\n' "${cmd[*]}"; exit 0; fi

if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]]; then
  printf "ohrm: container %s is not running — start it with 'docker-compose up -d ubuntuweb83'\n" "$CONTAINER" >&2
  exit 1
fi

exec "${cmd[@]}"
