# Makefile — convenience targets for the OrangeHRM dev environment.
#
# Naming: targets whose *mechanism* is specific to Apple Silicon / arm64 hosts
# (they drive the emulated amd64 `web83_client_build` service — see
# docker-compose.override.yml) carry a `-mac` suffix. On a Linux amd64 host the
# client builds natively inside ubuntuweb83 and these are neither needed nor used.
#
# The client-* targets wrap utils/web83-client-build.sh so the build logic lives
# in one place; this Makefile is just the friendly front door.

SHELL := /bin/bash
CLIENT_BUILD := utils/web83-client-build.sh
BUILDER_SVC  := web83_client_build

.DEFAULT_GOAL := help

.PHONY: help \
        amd64-enable-mac amd64-check-mac \
        client-install-mac client-inject-mac client-build-mac \
        client-shell-mac client-clean-mac

help: ## Show this help
	@echo "OrangeHRM dev environment — make targets:"
	@echo
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN{FS=":.*?## "} {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Apple Silicon: run 'make amd64-enable-mac' once per Docker Desktop start"
	@echo "before the client-*-mac targets (registers amd64 emulation)."

## ----------------------------------------------------------------------------
## Apple Silicon amd64 emulation
## ----------------------------------------------------------------------------

amd64-enable-mac: ## [mac] Register amd64 (qemu) emulation in the Docker VM
	@echo ">> Installing amd64 emulation into the Docker VM (qemu-x86_64)..."
	docker run --privileged --rm tonistiigi/binfmt --install amd64
	@echo ">> Done. amd64 images can now run (under emulation) on this machine."

amd64-check-mac: ## [mac] Verify amd64 emulation is available (used as a guard)
	@docker run --rm --platform linux/amd64 busybox true 2>/dev/null \
	  || { echo "ERROR: amd64 emulation is not available."; \
	       echo "       Run 'make amd64-enable-mac' first (needed after each Docker Desktop restart)."; \
	       exit 1; }

## ----------------------------------------------------------------------------
## Legacy Angular client build (html/.../symfony/web/client) — amd64 on Mac
## ----------------------------------------------------------------------------

client-install-mac: amd64-check-mac ## [mac] npm install + bower install (amd64 builder)
	$(CLIENT_BUILD) install

client-inject-mac: amd64-check-mac ## [mac] Development build: install + gulp inject
	$(CLIENT_BUILD) inject

client-build-mac: amd64-check-mac ## [mac] Production build: install + gulp build
	$(CLIENT_BUILD) build

client-shell-mac: amd64-check-mac ## [mac] Open an interactive shell in the amd64 builder (node 6)
	docker-compose run --rm $(BUILDER_SVC) \
	  'source /root/.nvm/nvm.sh && nvm use default >/dev/null && cd $$PWD && exec bash'

client-clean-mac: ## [mac] Remove the builder's node_modules volume + generated build/.tmp
	-docker volume rm web_web83_client_node_modules
	-rm -rf html/OHRMStandalone/TEST/trunk/symfony/web/client/{build,.tmp}
	@echo ">> Cleaned. Next client-*-mac run will reinstall node_modules from scratch."
