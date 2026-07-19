#!/usr/bin/env bash
#
# Build the legacy Angular client (html/OHRMStandalone/TEST/trunk/symfony/web/client)
# in an on-demand AMD64 container (web83_client_build in docker-compose.override.yml),
# so ubuntuweb83 can stay a native arm64 image.
#
# The client toolchain (gulp 3.9 + gulp-sass/node-sass on node 6) has no working
# arm64 build, hence amd64 — which runs under Rosetta emulation on Apple Silicon.
#
# Usage:
#   utils/web83-client-build.sh install   # npm install + bower install --allow-root
#   utils/web83-client-build.sh build     # install, then `gulp build`  (production)
#   utils/web83-client-build.sh inject     # install, then `gulp inject` (development)  [default]
#   utils/web83-client-build.sh gulp <task> [args...]   # install, then arbitrary gulp task
#
# The container is removed after each run (--rm). node_modules is kept in the
# web83_client_node_modules volume, so repeat runs skip re-downloading.
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root (utils/ -> ..)

SERVICE="web83_client_build"
# The amd64 builder doesn't mount ubuntuweb83's .bashrc, so nvm isn't auto-loaded
# in its login shell — source it explicitly, then select node 6 (the default alias).
INSTALL='source /root/.nvm/nvm.sh && nvm use default && node -v && npm install && bower install --allow-root'

task="${1:-inject}"
shift || true

case "$task" in
  install) remote="$INSTALL" ;;
  build)   remote="$INSTALL && gulp build" ;;
  inject)  remote="$INSTALL && gulp inject" ;;
  gulp)    remote="$INSTALL && gulp $*" ;;
  *) echo "usage: $0 [install|build|inject|gulp <task>...]" >&2; exit 2 ;;
esac

echo ">> [$task] amd64 client build via '$SERVICE' (emulated on Apple Silicon; the install step can take a few minutes)..."
# entrypoint is `bash -lc`, so the whole string below is executed by a login shell
# (nvm is sourced from the image's profile; `nvm use default` selects node 6).
exec docker-compose run --rm "$SERVICE" "$remote"
