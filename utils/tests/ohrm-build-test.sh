#!/usr/bin/env bash
#
# Tests for utils/ohrm-build.sh.
#
# The script's testable core is which steps a set of arguments selects, in what
# order, for which working copy, and what each step turns into on the docker
# command line. Every case below runs with OHRM_DRY_RUN=1, so it prints the
# commands it *would* run instead of building anything — no Docker needed.
# OHRM_BUILD_ARCH stands in for asking the web container its architecture, so
# both the Apple Silicon and the Linux client paths are covered on either host.
#
# The TEST tree is a throwaway fixture pointed at by OHRM_TEST_SRC_PATH, so these
# tests neither read nor depend on the developer's real .env or source checkouts.
#
# Usage: utils/tests/ohrm-build-test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$script_dir/../ohrm-build.sh"

pass=0; fail=0

# trunk and feature-x have every step's directory; only trunk has a
# databases.yml; lean has nothing but symfony.
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
for wc in trunk feature-x; do
  mkdir -p "$fixture/$wc/symfony/web/vue-app" \
           "$fixture/$wc/symfony/web/client" \
           "$fixture/$wc/symfony/config" \
           "$fixture/$wc/devTools/load"
done
mkdir -p "$fixture/lean/symfony"
cat > "$fixture/trunk/symfony/config/databases.yml" <<'YML'
all:
  doctrine:
    class: ohrmDoctrineDatabase
    param:
      dsn: 'mysql:host=db101115;port=3306;dbname=trunk_app'
test:
  doctrine:
    class: ohrmDoctrineDatabase
    param:
      dsn: 'mysql:host=db101115;port=3306;dbname=test_trunk_app'
YML

# Run in dry-run mode against the fixture, from $run_dir (default: outside the
# fixture, so CWD inference stays off unless a test asks for it). No terminal by
# default, so the data confirmation only prompts when a test forces OHRM_TTY=1.
run() {
  local run_dir="${RUN_DIR:-$fixture/..}"
  ( cd "$run_dir" \
    && OHRM_DRY_RUN=1 OHRM_TEST_SRC_PATH="$fixture" \
       OHRM_BUILD_ARCH="${OHRM_BUILD_ARCH:-x86_64}" OHRM_TTY="${OHRM_TTY:-0}" \
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

check_before() { # check_before <description> <earlier substring> <later substring> <actual>
  local to_a="${4%%"$2"*}" to_b="${4%%"$3"*}"
  if [[ "$4" == *"$2"* && "$4" == *"$3"* && ${#to_a} -lt ${#to_b} ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n       expected %s before %s\n       got: %s\n' "$1" "$2" "$3" "$4"
  fi
}

C=/var/www/html/OHRMStandalone/TEST
CTR=dev_web_83_ubuntu

echo "steps"
default="$(run)"
check     "no step named builds sf"      "[sf] "     "$default"
check     "no step named builds vue"     "[vue] "    "$default"
check     "no step named builds client"  "[client] " "$default"
check_not "no step named never loads data" "[data]"  "$default"
check     "all is sf + vue + client"     "$default"  "$(run all)"
check_not "all never loads data"         "[data]"    "$(run all)"
only_vue="$(run vue)"
check     "a named step runs"            "[vue] "    "$only_vue"
check_not "an unnamed step does not run" "[sf]"      "$only_vue"
check_not "an unnamed step does not run (client)" "[client]" "$only_vue"
pair="$(run sf client)"
check     "several steps can be named"   "[client] " "$pair"
check_not "only the named ones run"      "[vue]"     "$pair"
check "a repeated step runs once" "1" "$(run vue vue | grep -c '^\[vue\]')"
data_only="$(run data --yes)"
check     "data can run alone"           "[data] "   "$data_only"
check_not "data alone builds nothing"    "[sf]"      "$data_only"
with_data="$(run --data --yes)"
check     "--data adds data to the default steps" "[data] " "$with_data"
check     "--data keeps the default steps"        "[client] " "$with_data"
vue_data="$(run vue --data --yes)"
check     "--data adds data to named steps" "[data] " "$vue_data"
check_not "--data adds nothing else"        "[sf]"    "$vue_data"

echo "order"
check_before "sf runs before data"   "[sf]" "[data]"   "$with_data"
check_before "sf runs before vue"    "[sf]" "[vue]"    "$with_data"
check_before "sf runs before client" "[sf]" "[client]" "$with_data"
check "the rest run in parallel by default" "data + vue + client in parallel" "$with_data"
check "--serial runs them one after another" "one after another" "$(run --serial)"
check "sf alone is planned as just sf" "trunk: sf" "$(run sf)"

echo "commands"
check "sf clears the cache, builds the model and publishes assets" \
      "-w $C/trunk/symfony $CTR bash -lc php symfony cc && php symfony doctrine:build-model && php symfony orangehrm:publish-assets" \
      "$(run sf)"
check "vue runs npm ci then a production build on node 14" \
      "-w $C/trunk/symfony/web/vue-app $CTR bash -lc source /root/.nvm/nvm.sh && nvm use latest && npm ci && npm run build" \
      "$only_vue"
check "data runs dev-load.sh from devTools/load with the root password" \
      "-w $C/trunk/devTools/load $CTR bash -lc bash dev-load.sh 1234" "$data_only"
check "data clears the cache after loading" \
      "dev-load.sh 1234 && cd ../../symfony && php symfony cc" "$data_only"
check "data honours OHRM_DB_PASS" \
      "dev-load.sh secret" "$(OHRM_DB_PASS=secret run data --yes)"
check "OHRM_WEB_CONTAINER picks the container" \
      "other_ctr bash -lc" "$(OHRM_WEB_CONTAINER=other_ctr run sf)"

echo "client by architecture"
check "x86_64 builds the client inside the web container on node 6" \
      "-w $C/trunk/symfony/web/client $CTR bash -lc source /root/.nvm/nvm.sh && nvm use default && node -v && npm install && bower install --allow-root && gulp build" \
      "$(OHRM_BUILD_ARCH=x86_64 run client)"
mac="$(OHRM_BUILD_ARCH=aarch64 run client)"
check     "aarch64 uses the amd64 builder"  "web83-client-build.sh --wc trunk build" "$mac"
check_not "aarch64 does not build in the web container" "gulp build" "$mac"
check "arm64 counts as Apple Silicon too" \
      "web83-client-build.sh --wc trunk build" "$(OHRM_BUILD_ARCH=arm64 run client)"
check "the builder gets the resolved working copy" \
      "web83-client-build.sh --wc feature-x build" "$(OHRM_BUILD_ARCH=aarch64 run client feature-x)"

echo "resolution: working copy"
check "a bare non-step argument is a working copy" \
      "-w $C/feature-x/symfony "            "$(run feature-x)"
check "steps and a working copy combine" \
      "-w $C/feature-x/symfony/web/vue-app " "$(run vue feature-x)"
check "the working copy may come first" \
      "-w $C/feature-x/symfony/web/vue-app " "$(run feature-x vue)"
check "OHRM_WC is used when no working copy is given" \
      "-w $C/feature-x/symfony "            "$(OHRM_WC=feature-x run sf)"
check "an explicit working copy beats OHRM_WC" \
      "-w $C/trunk/symfony "                "$(OHRM_WC=feature-x run sf trunk)"
check "CWD under a working copy infers it" \
      "-w $C/feature-x/symfony "            "$(RUN_DIR="$fixture/feature-x/symfony/web" run sf)"
check "an explicit working copy beats CWD inference" \
      "-w $C/trunk/symfony "                "$(RUN_DIR="$fixture/feature-x" run sf trunk)"
check "CWD inference beats OHRM_WC" \
      "-w $C/feature-x/symfony "            "$(OHRM_WC=trunk RUN_DIR="$fixture/feature-x" run sf)"

echo "data confirmation"
refused="$(OHRM_TTY=0 run data)"
check     "without a terminal, data needs --yes" "--yes"       "$refused"
check_not "a refusal runs nothing"               "docker exec" "$refused"
check     "-y is --yes"                          "[data] "     "$(OHRM_TTY=0 run data -y)"
declined="$(printf 'n\n' | OHRM_TTY=1 run data)"
check     "the prompt names the app database"   "trunk_app"      "$declined"
check     "the prompt names the test database"  "test_trunk_app" "$declined"
check     "declining says so"                   "not run"        "$declined"
check_not "declining runs nothing"              "docker exec"    "$declined"
check_not "declining skips the other steps too" "[sf]" \
          "$(printf 'n\n' | OHRM_TTY=1 run --data)"
check_not "EOF on the prompt declines" "docker exec" "$(OHRM_TTY=1 run data </dev/null)"
check     "answering y proceeds" "[data] " "$(printf 'y\n' | OHRM_TTY=1 run data)"
check     "without databases.yml the prompt names where the database is configured" \
          "feature-x/symfony/config/databases.yml" "$(printf 'n\n' | OHRM_TTY=1 run data feature-x)"

echo "errors"
unknown="$(run sf no-such-wc)"
check "unknown working copy is an error"      "no-such-wc" "$unknown"
check "unknown working copy lists available"  "feature-x"  "$unknown"
lean="$(run lean)"
check     "a step whose directory is missing is an error" "symfony/web/vue-app" "$lean"
check_not "a missing directory stops the run before any step" "[sf]" "$lean"
check "two working copies are rejected" "two working copies" "$(run trunk feature-x)"
check "unknown option is rejected"      "usage"  "$(run --bogus)"
check "--help prints the usage block"   "Steps:" "$(run --help)"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
