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
mkdir -p "$fx/saml/keys" "$fx/saml/trees" "$fx/nginx/cert/saml" "$fx/test"
: > "$fx/hosts"

# TEST trees: king, queen, knight and bishop can be linked; wt is a git worktree
# (.git is a file). knight never gets a state folder; bishop's state holds one
# unusable file at a time. The container metadata stands in for what `up` exports.
cert_dir=symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert
for t in king queen knight bishop wt; do
  mkdir -p "$fx/test/$t/symfony/config" "$fx/test/$t/$cert_dir"
  printf "all:\n  doctrine:\n    param:\n      dsn: 'mysql:host=db101115;port=3306;dbname=%s'\n" "$t" \
    > "$fx/test/$t/symfony/config/databases.yml"
done
for t in king queen knight bishop; do
  mkdir -p "$fx/test/$t/.git/info"
  printf '# git ls-files --others --exclude-from=.git/info/exclude\n' > "$fx/test/$t/.git/info/exclude"
done
printf 'gitdir: /elsewhere/.git/worktrees/wt\n' > "$fx/test/wt/.git"
mkdir -p "$fx/saml/generated"
printf '<x/>\n' > "$fx/saml/generated/idp-metadata.xml"
printf '<x/>\n' > "$fx/saml/generated/sp-metadata.xml"

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

echo "up, metadata export"
out=$(run up)
check "up exports IdP metadata" "curl -fsS http://localhost/simplesaml/module.php/saml/idp/metadata" "$out"
check "up exports SP metadata"  "curl -fsS http://localhost/simplesaml/module.php/saml/sp/metadata/container-sp" "$out"
check "IdP metadata file"       "+ write $fx/saml/generated/idp-metadata.xml" "$out"
check "SP metadata file"        "+ write $fx/saml/generated/sp-metadata.xml" "$out"

echo "down"
out=$(run down);                   check "down removes the container" "-f custom-compose/saml.yml rm -sf saml" "$out"

echo "link"
out=$(run link 'Bad!');            check "bad slug refused"        "must match ^[a-z0-9]+\$" "$out"
out=$(run link nosuch);            check "unknown tree refused"    "no working copy 'nosuch'" "$out"
out=$(run link wt);                check "worktree refused"        "worktree trees are not supported" "$out"
mv "$fx/saml/generated" "$fx/saml/gen.off"; out=$(run link king); mv "$fx/saml/gen.off" "$fx/saml/generated"
check "needs up first" "run 'ohrm saml up' first" "$out"
out=$(OHRM_WEB_RUNNING=true run link king)
check "records domain.name first"       "SELECT REPLACE(TO_BASE64(value), CHAR(10), '') FROM ohrm_config WHERE property = 'domain.name'" "$out"
check_before "record before update"     "TO_BASE64(value)" "UPDATE ohrm_config" "$out"
check "sets domain.name via base64"     "UPDATE ohrm_config SET value = FROM_BASE64('$(printf %s king.test-webubuntu83.orangehrmdev.com | base64)') WHERE property = 'domain.name'" "$out"
check "generates tree IdP key"          "openssl req -x509" "$out"
check "appends pem exclude line"        "/symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert/saml.prod.orangehrm-idp.pem" "$out"
check "inserts IdP row"                 "'SAML test container', 'IDP'" "$out"
check "IdP row username_key"            "'username', 1" "$out"
check "inserts SP row"                  "'SAML test container', 'SP'" "$out"
check "maps four attributes"            "(@sp, 2, 'username'), (@sp, 3, 'firstName'), (@sp, 5, 'email'), (@sp, 6, 'employeeId')" "$out"
check "writes registration"             "$fx/saml/trees/king.json" "$out"
check "clears tree cache"               "php symfony cc" "$out"
out=$(OHRM_WEB_RUNNING=false run link king)
check_not "link skips cache clear when web container is down" "docker exec -w /var/www/html/OHRMStandalone/TEST/king/symfony" "$out"
check     "says how to clear later"     "ohrm sf king -- php symfony cc" "$out"
touch "$fx/test/king/symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert/saml.prod.orangehrm-idp."{pem,crt}
printf '%s\n' /symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert/saml.prod.orangehrm-idp.{pem,crt} >> "$fx/test/king/.git/info/exclude"
out=$(run link king)
check_not "existing key kept"           "openssl req -x509" "$out"
check_not "existing exclude kept"       "append $fx/test/king/.git/info/exclude" "$out"
mkdir -p "$fx/saml/state/king"; out=$(run link king)
check "already linked is a no-op"       "king is already linked" "$out"
check_not "no-op touches nothing"       "UPDATE" "$out"

echo "unlink and rollback"
# Hand-made state, as link would leave it: only the .pem was created and only
# its exclude line added.
mkstate() { # mkstate <tree> <domain value>
  local d="$fx/saml/state/$1"; mkdir -p "$d"; echo "$1" > "$d/app_db"
  printf %s "$2" | base64 | tr -d '\n' > "$d/domain_name.b64"
  printf '%s\n' symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert/saml.prod.orangehrm-idp.pem > "$d/created_files"
  printf '%s\n' /symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert/saml.prod.orangehrm-idp.pem > "$d/exclude_added"
  echo 41 > "$d/idp_row_id"; echo 42 > "$d/sp_row_id"; echo '{}' > "$fx/saml/trees/$1.json"
}
mkstate king "rook-style.example.com"; mkstate queen "localhost"
out=$(run unlink king)
check "unlink restores a non-localhost domain.name" "SET value = FROM_BASE64('$(printf %s rook-style.example.com | base64)')" "$out"
check "deletes only created files"   "rm -f $fx/test/king/symfony/plugins/orangehrmOpenidAuthenticationPlugin/config/saml/cert/saml.prod.orangehrm-idp.pem" "$out"
check_not "keeps files it didn't make" "saml.prod.orangehrm-idp.crt" "$out"
check "removes only added exclude lines" "remove-lines $fx/test/king/.git/info/exclude" "$out"
check "deletes attribute rows by id" "DELETE FROM ohrm_saml_provider_attribute WHERE provider_id IN (41, 42)" "$out"
check "deletes provider rows by id"  "DELETE FROM ohrm_saml_provider WHERE id IN (41, 42) AND name = 'SAML test container'" "$out"
check "removes registration"         "rm -f $fx/saml/trees/king.json" "$out"
check "removes state last"           "rm -rf $fx/saml/state/king" "$out"
check_before "registration before state" "trees/king.json" "state/king" "$out"
check_not "unlink king leaves queen alone" "queen" "$out"
rm -rf "$fx/saml/state/king"; out=$(run unlink king); rc=$?
check "unlink without state changes nothing" "king is not linked" "$out"; check_not "no SQL" "sql[" "$out"; [[ $rc -eq 1 ]] || fail_rc
out=$(OHRM_SAML_FAIL_AT=7 OHRM_WEB_RUNNING=true run link knight); rc=$?
check "failed link rolls back" "rolling back knight" "$out"; [[ $rc -eq 1 ]] || fail_rc
check_before "rollback ends by removing state" "rolling back knight" "rm -rf $fx/saml/state/knight" "$out"

echo "unlink refuses unusable state files"
# Each case spoils one file of an otherwise good state. The spoiled step is
# skipped, the other steps still run, the state folder is kept and unlink exits 1.
bad="$fx/saml/state/bishop"
sql_lines() { grep -E 'DELETE|UPDATE' <<< "$1"; }
rm_lines() { grep '^+ rm -f' <<< "$1"; }

rm -rf "$bad"; mkstate bishop localhost; echo '2; DROP TABLE x' > "$bad/sp_row_id"
out=$(run unlink bishop); rc=$?
check_not "bad sp_row_id never reaches SQL"  "DROP TABLE" "$(sql_lines "$out")"
check_not "bad sp_row_id skips the row step" "DELETE" "$out"
check     "bad sp_row_id: other steps run"   "rm -f $fx/saml/trees/bishop.json" "$out"
check_not "bad sp_row_id keeps the state"    "rm -rf $bad" "$out"; [[ $rc -eq 1 ]] || fail_rc

rm -rf "$bad"; mkstate bishop localhost; echo "king'x" > "$bad/app_db"
out=$(run unlink bishop); rc=$?
check_not "bad app_db never reaches SQL"     "sql[" "$out"
check     "bad app_db: other steps run"      "rm -f $fx/test/bishop/$cert_dir/saml.prod.orangehrm-idp.pem" "$out"
check_not "bad app_db keeps the state"       "rm -rf $bad" "$out"; [[ $rc -eq 1 ]] || fail_rc

rm -rf "$bad"; mkstate bishop localhost
printf '%s\n' ../queen/x /etc/passwd "$cert_dir/saml.prod.orangehrm-idp.pem" > "$bad/created_files"
out=$(run unlink bishop); rc=$?
check_not "no rm through a .. path"          "queen" "$(rm_lines "$out")"
check_not "no rm of an absolute path"        "passwd" "$(rm_lines "$out")"
check     "paths inside the tree still go"   "rm -f $fx/test/bishop/$cert_dir/saml.prod.orangehrm-idp.pem" "$out"
check_not "bad created_files keeps the state" "rm -rf $bad" "$out"; [[ $rc -eq 1 ]] || fail_rc
rm -rf "$bad"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
