#!/usr/bin/env bash
#
# Keep /etc/hosts and docker-compose.override.yml's nginx network aliases in
# sync with the directories under the OrangeHRM TEST source tree (e.g.
# `trunk`), so each one is reachable at
# <dirname>.test-webubuntu83.orangehrmdev.com from the host and from other
# containers on ohrmdevnet — nginx's server_name regex and Apache's
# VirtualDocumentRoot already route any such hostname automatically; the
# only missing piece per new directory is DNS resolution.
#
# Run manually whenever you add/remove a directory under TEST (or change
# OHRM_TEST_SRC_PATH in .env to point elsewhere).
#
# - /etc/hosts is updated automatically (with confirmation; requires sudo).
# - docker-compose.override.yml is NOT auto-edited; missing aliases are
#   printed for you to add under the nginx service's networks.ohrmdevnet.aliases.
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root (utils/ -> ..)

test_src="./html/OHRMStandalone/TEST"
if [[ -f .env ]]; then
  env_val="$(grep -E '^OHRM_TEST_SRC_PATH=' .env | tail -n1 | cut -d= -f2- || true)"
  [[ -n "${env_val:-}" ]] && test_src="$env_val"
fi

if [[ ! -d "$test_src" ]]; then
  echo "TEST source path '$test_src' does not exist, nothing to sync." >&2
  exit 1
fi

domain_suffix="test-webubuntu83.orangehrmdev.com"
dirs=()
while IFS= read -r -d '' d; do
  dirs+=("$(basename "$d")")
done < <(find "$test_src" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

if [[ ${#dirs[@]} -eq 0 ]]; then
  echo "No subdirectories found under '$test_src'." >&2
  exit 0
fi

hostnames=()
for d in "${dirs[@]}"; do
  hostnames+=("${d}.${domain_suffix}")
done

echo "Source directories under $test_src: ${dirs[*]}"
echo

# --- /etc/hosts ---
missing_hosts=()
for h in "${hostnames[@]}"; do
  grep -qE "[[:space:]]${h}([[:space:]]|\$)" /etc/hosts || missing_hosts+=("$h")
done

if [[ ${#missing_hosts[@]} -eq 0 ]]; then
  echo "/etc/hosts: all entries already present."
else
  echo "/etc/hosts: missing entries for: ${missing_hosts[*]}"
  read -r -p "Add them now (requires sudo)? [y/N] " reply
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    for h in "${missing_hosts[@]}"; do
      echo "127.0.0.1 $h" | sudo tee -a /etc/hosts >/dev/null
    done
    echo "Added ${#missing_hosts[@]} entries to /etc/hosts."
  else
    echo "Skipped. Add manually:"
    for h in "${missing_hosts[@]}"; do echo "  127.0.0.1 $h"; done
  fi
fi

echo

# --- docker-compose.override.yml nginx aliases ---
override_file="docker-compose.override.yml"
missing_aliases=()
for h in "${hostnames[@]}"; do
  grep -qF -- "$h" "$override_file" || missing_aliases+=("$h")
done

if [[ ${#missing_aliases[@]} -eq 0 ]]; then
  echo "$override_file: all nginx aliases already present."
else
  echo "$override_file: missing nginx network aliases for: ${missing_aliases[*]}"
  echo "Add these lines under the nginx service's networks.ohrmdevnet.aliases in $override_file, then 'docker-compose up -d nginx' to apply:"
  for h in "${missing_aliases[@]}"; do echo "          - $h"; done
fi
