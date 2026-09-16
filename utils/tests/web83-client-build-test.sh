#!/usr/bin/env bash
#
# Tests for utils/web83-client-build.sh.
#
# The script's testable core is the same as ohrm-shell.sh's: which working copy a
# given set of arguments/environment/CWD resolves to, and what that turns into on
# the docker-compose command line. Every case below runs with OHRM_DRY_RUN=1, so
# it prints the command it *would* run instead of starting an emulated amd64
# container — no Docker needed, and the assertions can be exact.
#
# The TEST tree is a throwaway fixture pointed at by OHRM_TEST_SRC_PATH, so these
# tests neither read nor depend on the developer's real .env or source checkouts.
#
# Usage: utils/tests/web83-client-build-test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$script_dir/../web83-client-build.sh"

pass=0; fail=0

# Three working copies: two buildable, one without a client dir at all.
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/trunk/symfony/web/client" \
         "$fixture/feature-x/symfony/web/client" \
         "$fixture/lean/symfony/web/vue-app"

# Run in dry-run mode against the fixture, from $run_dir (default: outside the
# fixture, so CWD inference stays off unless a test asks for it). The project
# name is pinned so the trunk volume name does not depend on where this repo
# happens to be checked out.
run() {
  local run_dir="${RUN_DIR:-$fixture/..}"
  ( cd "$run_dir" \
    && OHRM_DRY_RUN=1 OHRM_TEST_SRC_PATH="$fixture" COMPOSE_PROJECT_NAME=web \
       "$BUILD" "$@" 2>&1 )
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
FX=$C/feature-x/symfony/web/client

echo "tasks"
check "inject is the default task"  "&& gulp inject"  "$(run)"
check "build runs gulp build"       "&& gulp build"   "$(run build)"
check "inject runs gulp inject"     "&& gulp inject"  "$(run inject)"
check "install stops after bower"   "bower install --allow-root" "$(run install)"
check_not "install runs no gulp task" "gulp"          "$(run install)"
check "gulp takes an arbitrary task"  "&& gulp watch --verbose" "$(run gulp watch --verbose)"
check "shell opens a login shell"     "exec bash"     "$(run shell)"
check "every build task installs first" "npm install" "$(run build)"

echo "trunk uses the service definition as-is"
trunk_out="$(run build)"
check     "no working-copy override is passed" "--rm web83_client_build" "$trunk_out"
check_not "trunk passes no -w"                 "-w "                     "$trunk_out"
check_not "trunk passes no -v"                 "-v web83_client_node_modules" "$trunk_out"

echo "resolution: working copy"
check "--wc selects the tree"     "-w $FX "           "$(run --wc feature-x build)"
check "--wc=<value> form works"   "-w $FX "           "$(run --wc=feature-x build)"
check "OHRM_WC is used when no --wc is given" \
      "-w $FX "                   "$(OHRM_WC=feature-x run build)"
check "explicit --wc beats OHRM_WC" \
      "--rm web83_client_build"   "$(OHRM_WC=feature-x run --wc trunk build)"
check "--wc applies to gulp too"  "-w $FX "           "$(run --wc feature-x gulp watch)"
check "--wc applies to shell too" "-w $FX "           "$(run --wc feature-x shell)"

echo "resolution: CWD inference"
check "CWD under a working copy infers it" \
      "-w $FX "  "$(RUN_DIR="$fixture/feature-x" run build)"
check "CWD inference works from a nested dir" \
      "-w $FX "  "$(RUN_DIR="$fixture/feature-x/symfony/web/client" run build)"
check "explicit --wc beats CWD inference" \
      "--rm web83_client_build" "$(RUN_DIR="$fixture/feature-x" run --wc trunk build)"
check "CWD inference beats OHRM_WC" \
      "-w $FX "  "$(OHRM_WC=trunk RUN_DIR="$fixture/feature-x" run build)"

echo "node_modules volume"
check "a non-trunk tree gets its own volume" \
      "-v web83_client_node_modules_feature-x:$FX/node_modules" \
      "$(run --wc feature-x build)"
# ohrm-tree.sh build-client names the per-tree volume the same way, so both entry
# points share one install per tree. Keep these two spellings in step.
check "the volume name matches ohrm-tree.sh build-client" \
      "web83_client_node_modules_feature-x" \
      "$(grep -o 'web83_client_node_modules_\$slug' "$script_dir/../ohrm-tree.sh" \
         | head -1 | sed 's/\$slug/feature-x/')"

echo "clean"
clean_fx="$(run --wc feature-x clean)"
check "clean removes the tree's volume"     "docker volume rm web83_client_node_modules_feature-x" "$clean_fx"
check "clean removes build/"                "$fixture/feature-x/symfony/web/client/build"          "$clean_fx"
check "clean removes .tmp/"                 "$fixture/feature-x/symfony/web/client/.tmp"           "$clean_fx"
clean_trunk="$(run clean)"
check "clean on trunk uses the compose-prefixed volume" \
      "docker volume rm web_web83_client_node_modules" "$clean_trunk"
check_not "clean never starts the builder"  "docker-compose run" "$clean_trunk"

echo "errors"
unknown="$(run --wc no-such-wc build)"
check "unknown working copy is an error"     "no-such-wc" "$unknown"
check "unknown working copy lists available" "feature-x"  "$unknown"
check "a tree with no client dir is an error" \
      "symfony/web/client" "$(run --wc lean build)"
check "unknown task is rejected"   "usage" "$(run frobnicate)"
check "unknown option is rejected" "usage" "$(run --bogus build)"
check "--wc with no value is rejected" "needs a working copy" "$(run --wc)"
check "--help prints the usage block"  "Working copy:" "$(run --help)"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
