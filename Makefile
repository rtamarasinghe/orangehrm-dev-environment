# Makefile — convenience targets for the OrangeHRM dev environment.
#
# Naming: targets whose *mechanism* is specific to Apple Silicon / arm64 hosts
# (they drive the emulated amd64 `web83_client_build` service — see
# docker-compose.override.yml) carry a `-mac` suffix. On a Linux amd64 host the
# client builds natively inside ubuntuweb83 and these are neither needed nor used.
#
# The client-* targets wrap utils/web83-client-build.sh so the build logic lives
# in one place; this Makefile is just the friendly front door.
#
# WC=<working copy> picks which tree under OHRMStandalone/TEST a target acts on,
# for the client-* targets as well as `shell`. Left unset it falls back the same
# way `ohrm` does: your current directory, then $OHRM_WC, then trunk.

SHELL := /bin/bash
CLIENT_BUILD := utils/web83-client-build.sh
OHRM_SHELL   := utils/ohrm-shell.sh

# Recursive (=), not simple (:=), so WC is read when a recipe runs — which is
# what lets `make client-build-mac WC=amber` work from the command line.
WC_FLAG = $(if $(WC),--wc $(WC))

.DEFAULT_GOAL := help

.PHONY: help \
        amd64-enable-mac amd64-check-mac \
        client-install-mac client-inject-mac client-build-mac \
        client-shell-mac client-clean-mac \
        shell sql install-ohrm \
        sync-dev-hosts

help: ## Show this help
	@echo "OrangeHRM dev environment — make targets:"
	@echo
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN{FS=":.*?## "} {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Apple Silicon: run 'make amd64-enable-mac' once per Docker Desktop start"
	@echo "before the client-*-mac targets (registers amd64 emulation)."
	@echo
	@echo "WC=<working copy> targets a tree other than trunk, e.g."
	@echo "  make client-build-mac WC=amber      make shell D=vue WC=amber"
	@echo
	@echo "Shells: 'make shell' needs you to be in this directory. Run 'make install-ohrm'"
	@echo "once to get the 'ohrm' command, which works from anywhere."

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
## Legacy Angular client build (<working copy>/symfony/web/client) — amd64 on Mac
## ----------------------------------------------------------------------------

# All of these take an optional WC=<working copy>; see the WC note at the top.
# Each tree keeps its own node_modules volume, so switching between them with WC
# does not force a reinstall.

client-install-mac: amd64-check-mac ## [mac] npm install + bower install (WC=<working copy>)
	$(CLIENT_BUILD) $(WC_FLAG) install

client-inject-mac: amd64-check-mac ## [mac] Development build: install + gulp inject (WC=)
	$(CLIENT_BUILD) $(WC_FLAG) inject

client-build-mac: amd64-check-mac ## [mac] Production build: install + gulp build (WC=)
	$(CLIENT_BUILD) $(WC_FLAG) build

client-shell-mac: amd64-check-mac ## [mac] Interactive shell in the amd64 builder, node 6 (WC=)
	$(CLIENT_BUILD) $(WC_FLAG) shell

client-clean-mac: ## [mac] Remove this tree's node_modules volume + build/.tmp (WC=)
	@$(CLIENT_BUILD) $(WC_FLAG) clean

## ----------------------------------------------------------------------------
## Shells into ubuntuweb83
## ----------------------------------------------------------------------------

# Thin front door onto utils/ohrm-shell.sh, which is the same script the `ohrm`
# shell function calls. Working copy (WC) is optional: left unset it is inferred
# from your current directory, then $OHRM_WC, then trunk.

shell: ## Shell into ubuntuweb83 (D=sf|dt|vue|client, WC=<working copy>)
	@$(OHRM_SHELL) $(D) $(WC)

sql: ## MySQL console on the dev database (via ubuntuweb83)
	@$(OHRM_SHELL) sql

install-ohrm: ## Add the 'ohrm' shell function to your shell config (asks first)
	@$(OHRM_SHELL) install

## ----------------------------------------------------------------------------
## TEST source dirs -> dev domain hostnames
## ----------------------------------------------------------------------------

sync-dev-hosts: ## Sync /etc/hosts + report missing nginx aliases for TEST source dirs
	utils/sync-dev-hosts.sh
