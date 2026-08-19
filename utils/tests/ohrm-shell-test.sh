#!/usr/bin/env bash
#
# Tests for utils/ohrm-shell.sh.
#
# The script's testable core is its resolution logic: which working copy and
# which directory a given set of arguments/environment/CWD lands on. Every case
# below runs the script with OHRM_DRY_RUN=1, so it prints the docker command it
# *would* run instead of exec'ing into a container — no running containers
# needed, and the assertions can be exact.
#
# The TEST tree is a throwaway fixture pointed at by OHRM_TEST_SRC_PATH, so
# these tests neither read nor depend on the developer's real .env or source
# checkouts.
#
# Usage: utils/tests/ohrm-shell-test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OHRM="$script_dir/../ohrm-shell.sh"

pass=0; fail=0

# Build a fake TEST tree: two working copies, only one of which has every dir.
fixture="$(mktemp -d)"
fakehome="$(mktemp -d)"
trap 'rm -rf "$fixture" "$fakehome"' EXIT
mkdir -p "$fixture/trunk/symfony/web/vue-app" \
         "$fixture/trunk/symfony/web/client" \
         "$fixture/trunk/devTools" \
         "$fixture/feature-x/symfony/web/vue-app" \
         "$fixture/feature-x/devTools"

# Run the script in dry-run mode against the fixture, from $run_dir (default:
# somewhere outside the fixture, so CWD inference stays off unless asked for).
run() {
  local run_dir="${RUN_DIR:-$fixture/..}"
  ( cd "$run_dir" \
    && OHRM_DRY_RUN=1 OHRM_TTY="${OHRM_TTY:-1}" OHRM_TEST_SRC_PATH="$fixture" \
       "$OHRM" "$@" 2>&1 )
}

check_not() { # check_not <description> <substring that must be absent> <actual>
  if [[ "$3" != *"$2"* ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n       expected NOT to contain: %s\n       got: %s\n' "$1" "$2" "$3"
  fi
}

check() { # check <description> <expected substring> <actual>
  if [[ "$3" == *"$2"* ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n       expected to contain: %s\n       got: %s\n' "$1" "$2" "$3"
  fi
}

C=/var/www/html/OHRMStandalone/TEST

echo "resolution: destinations"
check "no args defaults to symfony"     "-w $C/trunk/symfony "            "$(run)"
check "sf is symfony"                   "-w $C/trunk/symfony "            "$(run sf)"
check "dt is devTools"                  "-w $C/trunk/devTools "           "$(run dt)"
check "vue is symfony/web/vue-app"      "-w $C/trunk/symfony/web/vue-app" "$(run vue)"
check "client is symfony/web/client"    "-w $C/trunk/symfony/web/client"  "$(run client)"

echo "resolution: working copy"
check "bare non-destination arg is a working copy" \
      "-w $C/feature-x/symfony "  "$(run feature-x)"
check "two-arg form" \
      "-w $C/feature-x/symfony/web/vue-app" "$(run vue feature-x)"
check "OHRM_WC is used when no arg given" \
      "-w $C/feature-x/symfony "  "$(OHRM_WC=feature-x run)"
check "explicit arg beats OHRM_WC" \
      "-w $C/trunk/symfony "      "$(OHRM_WC=feature-x run sf trunk)"

echo "resolution: CWD inference"
check "CWD under a working copy infers it" \
      "-w $C/feature-x/symfony "  "$(RUN_DIR="$fixture/feature-x/symfony" run)"
check "CWD inference works from a nested dir" \
      "-w $C/feature-x/devTools " "$(RUN_DIR="$fixture/feature-x/symfony/web/vue-app" run dt)"
check "explicit arg beats CWD inference" \
      "-w $C/trunk/symfony "      "$(RUN_DIR="$fixture/feature-x" run sf trunk)"
check "CWD inference beats OHRM_WC" \
      "-w $C/feature-x/symfony "  "$(OHRM_WC=trunk RUN_DIR="$fixture/feature-x" run)"

echo "behaviour: shell vs command"
check "opens an interactive login shell by default" \
      "-it dev_web_83_ubuntu bash -l" "$(run sf)"
check "-- runs a command instead of a shell" \
      "bash -lc php symfony cc"       "$(run sf -- php symfony cc)"
check "-- passes the working copy through" \
      "-w $C/feature-x/symfony "      "$(run sf feature-x -- php symfony cc)"
# `docker exec -t` fails when there is no terminal, so TTY allocation follows
# stdin unless forced. These tests run without a terminal.
check "no TTY is requested when stdin is not a terminal" \
      "-w $C/trunk/symfony -i dev"    "$(OHRM_TTY=auto run sf)"
check "OHRM_TTY=0 forces TTY off" \
      "-w $C/trunk/symfony -i dev"    "$(OHRM_TTY=0 run sf)"

echo "behaviour: sql"
check "sql opens a mysql console" \
      "mysql -uroot -p1234 -hdb101115" "$(run sql)"
check "sql honours OHRM_DB_* overrides" \
      "mysql -uohrm -psecret -hdb55"   "$(OHRM_DB_HOST=db55 OHRM_DB_USER=ohrm OHRM_DB_PASS=secret run sql)"
check "sql -- runs a statement" \
      "-e show databases;"             "$(run sql -- 'show databases;')"

echo "behaviour: ls and errors"
ls_out="$(run ls)"
check "ls lists trunk"      "trunk"     "$ls_out"
check "ls lists feature-x"  "feature-x" "$ls_out"

missing_wc="$(run sf no-such-wc)"
check "unknown working copy is an error"      "no-such-wc" "$missing_wc"
check "unknown working copy lists available"  "feature-x"  "$missing_wc"

missing_dir="$(run client feature-x)"
check "missing destination dir is an error" \
      "$C/feature-x/symfony/web/client" "$missing_dir"

check "unknown flag is rejected" "usage" "$(run --bogus)"

echo "behaviour: install"

# install writes for real, so it runs against a throwaway HOME rather than
# dry-run. SHELL is pinned so the default rc file is deterministic.
inst() { ( HOME="$fakehome" SHELL=/bin/zsh "$OHRM" install "$@" 2>&1 ); }

# The path install writes is the one the script resolves for itself.
OHRM_ABS="$(cd "$script_dir/.." && pwd)/ohrm-shell.sh"
FN_LINE="ohrm() { $OHRM_ABS \"\$@\"; }"

rc="$fakehome/.zshrc"
: > "$rc"
touch "$fakehome/.bash_profile"   # a second config, so it gets mentioned

declined="$(printf 'n\n' | inst)"
check     "prompt names the target file"        "$rc"            "$declined"
check     "prompt shows the line to be added"   "$FN_LINE"       "$declined"
check     "prompt lists other shell configs"    ".bash_profile"  "$declined"
check     "declining says so"                   "not installed"  "$declined"
check_not "declining writes nothing"            "ohrm()"         "$(cat "$rc")"

check_not "EOF on the prompt declines" "ohrm()" \
          "$(inst --rc "$fakehome/.rc_eof" </dev/null >/dev/null 2>&1; cat "$fakehome/.rc_eof" 2>/dev/null)"

installed="$(inst --yes)"
check "installing reports the file"   "$rc"      "$installed"
check "installing adds the function"  "$FN_LINE" "$(cat "$rc")"
check "installing adds a marker"      "added by" "$(cat "$rc")"

check "installing twice is a no-op"   "already installed" "$(inst --yes)"
check "installing twice does not duplicate the function" "1" "$(grep -c 'ohrm()' "$rc")"

foreign="$fakehome/.foreign_rc"
printf 'ohrm() { /somewhere/else/ohrm.sh "$@"; }\n' > "$foreign"
conflict="$(inst --yes --rc "$foreign" || true)"
check     "refuses to shadow a foreign ohrm function" "already exists" "$conflict"
check_not "refusal writes nothing"                    "$OHRM_ABS"      "$(cat "$foreign")"

inst --yes --rc "$fakehome/.rc_a" --rc "$fakehome/.rc_b" >/dev/null
check "--rc writes the first named file"  "$FN_LINE" "$(cat "$fakehome/.rc_a")"
check "--rc writes the second named file" "$FN_LINE" "$(cat "$fakehome/.rc_b")"

dry="$(OHRM_DRY_RUN=1 inst --yes --rc "$fakehome/.rc_dry")"
check     "dry-run names the target"  "$fakehome/.rc_dry" "$dry"
check_not "dry-run writes nothing"    "ohrm()"            "$(cat "$fakehome/.rc_dry" 2>/dev/null)"

check "unknown install option is rejected" "usage" "$(inst --bogus || true)"


echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
