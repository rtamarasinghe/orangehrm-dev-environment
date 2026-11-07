#!/usr/bin/env bash
#
# Tests for utils/ohrm-saml.sh.
#
# Every case runs with OHRM_DRY_RUN=1, so the script prints each change it would
# make instead of making it: no Docker, sudo or network needed. The keys,
# certificate, nginx, hosts and TEST paths all point into a throwaway fixture, so
# these tests neither read nor change the developer's real ones.
#
# Usage: utils/tests/ohrm-saml-test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAML="$script_dir/../ohrm-saml.sh"

pass=0; fail=0

# $fx/saml is OHRM_SAML_DIR, $fx/nginx is OHRM_NGINX_DIR, $fx/hosts is
# OHRM_HOSTS_FILE (starts empty) and $fx/test is OHRM_TEST_SRC_PATH.
fx="$(mktemp -d)"
trap 'rm -rf "$fx"' EXIT
mkdir -p "$fx/saml/keys" "$fx/nginx/cert/saml" "$fx/test"
: > "$fx/hosts"

# Dry run, no terminal, so the /etc/hosts step never prompts.
run() {
  ( OHRM_DRY_RUN=1 OHRM_TTY=0 \
    OHRM_SAML_DIR="$fx/saml" OHRM_NGINX_DIR="$fx/nginx" \
    OHRM_HOSTS_FILE="$fx/hosts" OHRM_TEST_SRC_PATH="$fx/test" \
    "$SAML" "$@" 2>&1 )
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

fail_rc() { # fail_rc — the exit code in $rc was not the expected one
  fail=$((fail + 1))
  printf '  FAIL unexpected exit code %s\n       output: %s\n' "${rc:-?}" "${out:-}"
}

echo "help and errors"
out=$(run --help);                 check "help shows usage"            "ohrm saml up" "$out"
out=$(run bogus); rc=$?;           check "unknown command is an error" "usage: ohrm saml" "$out"; [[ $rc -eq 2 ]] || fail_rc

echo "up, first run"
out=$(run up)
check "up generates container keys"     "openssl req -x509" "$out"
check "up generates the salt"           "openssl rand -hex 32" "$out"
check "up asks mkcert for saml.test"    "mkcert -key-file $fx/nginx/cert/saml/key.pem -cert-file $fx/nginx/cert/saml/cert.pem saml.test" "$out"
check_before "cert before nginx block"  "mkcert" "virtual-servers/saml.conf" "$out"
check "up tests nginx before reload"    "docker exec dev_nginx nginx -t" "$out"
check "no TTY: hosts line printed"      "127.0.0.1 saml.test" "$out"
check_not "no TTY: no sudo"             "sudo tee" "$out"
check "up starts only saml"             "-f custom-compose/saml.yml up -d --build --no-deps saml" "$out"

echo "up, second run"
touch "$fx/saml/keys/container.key" "$fx/saml/keys/container.crt" "$fx/saml/keys/secretsalt" "$fx/nginx/cert/saml/cert.pem" "$fx/nginx/cert/saml/key.pem"
echo "127.0.0.1 saml.test" >> "$fx/hosts"
out=$(run up)
check_not "second up: no new keys"      "openssl req -x509" "$out"
check_not "second up: no new cert"      "mkcert" "$out"
check_not "second up: no hosts prompt"  "127.0.0.1 saml.test" "$out"

echo "down"
out=$(run down);                   check "down removes the container" "-f custom-compose/saml.yml rm -sf saml" "$out"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
