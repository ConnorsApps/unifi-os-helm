SHELL := /usr/bin/env bash
ROOT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Pinned release: UOS_VERSION + per-arch installer URLs/sha256. Any of them can be
# overridden, e.g. make build UOS_VERSION=5.1.42 UOS_INSTALLER_URL_AMD64=<url>
include $(ROOT_DIR)uos-version.env

IMAGE ?= ghcr.io/connorsapps/unifi-os
TAG ?= $(UOS_VERSION)
PLATFORMS ?= linux/amd64
PLATFORM ?=
# podman where it's installed, else docker with buildx (an agent sandbox: a remote
# buildkitd, no daemon). Without --load, docker builds stay in the build cache,
# which is all the verification needs.
CONTAINER_ENGINE ?= $(if $(shell command -v podman 2>/dev/null),podman,docker)
export CONTAINER_ENGINE
PATCH_STRICT ?= true
FROM_FILE ?=
OLD ?=
NEW ?=
CONTAINER ?= uosserver
CONTAINER_USER ?= uosserver
CONFIG_DUMP_DIR ?= file-dumps/configs

BUILD_ARGS = $(foreach v,UOS_INSTALLER_URL_AMD64 UOS_INSTALLER_SHA256_AMD64 UOS_INSTALLER_URL_ARM64 UOS_INSTALLER_SHA256_ARM64 PATCH_STRICT,--build-arg "$(v)=$($(v))")

.PHONY: help build build-all test schema schema-check latest check-update bump diff-upstream upgrade-check upgrade upgrade-verify extract-container-configs

help: ## List targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-26s %s\n", $$1, $$2}'

build: ## Build IMAGE:TAG for PLATFORMS [CONTAINER_ENGINE=podman|docker, default podman if installed]; patch.sh asserts the result
	$(CONTAINER_ENGINE) build "$(ROOT_DIR)" --platform "$(PLATFORMS)" $(BUILD_ARGS) --tag "$(IMAGE):$(TAG)"

# podman: per-arch images joined into a manifest list (arm64 on an x86 host needs
# qemu-user-static); push with: podman manifest push --all $(IMAGE):$(TAG) docker://$(IMAGE):$(TAG)
# docker: one multi-platform build (a docker-container or remote buildx builder;
# the default docker driver refuses multi-platform without the containerd store).
build-all: ## Build amd64 + arm64 (podman: and a manifest list)
	@test -n "$(UOS_INSTALLER_URL_ARM64)" || { echo "UOS_INSTALLER_URL_ARM64 is empty"; exit 1; }
ifeq ($(CONTAINER_ENGINE),podman)
	podman build "$(ROOT_DIR)" --platform linux/amd64 $(BUILD_ARGS) --tag "$(IMAGE):$(TAG)-amd64"
	podman build "$(ROOT_DIR)" --platform linux/arm64 $(BUILD_ARGS) --tag "$(IMAGE):$(TAG)-arm64"
	-podman manifest rm "$(IMAGE):$(TAG)" 2>/dev/null
	podman manifest create "$(IMAGE):$(TAG)"
	podman manifest add "$(IMAGE):$(TAG)" "containers-storage:$(IMAGE):$(TAG)-amd64"
	podman manifest add "$(IMAGE):$(TAG)" "containers-storage:$(IMAGE):$(TAG)-arm64"
else
	$(CONTAINER_ENGINE) build "$(ROOT_DIR)" --platform linux/amd64,linux/arm64 $(BUILD_ARGS) --tag "$(IMAGE):$(TAG)"
endif

test: ## helm lint + render every tests/values scenario
	@test -d "$(ROOT_DIR)charts/unifi-os/charts" || helm dependency update "$(ROOT_DIR)charts/unifi-os"
	helm lint "$(ROOT_DIR)charts/unifi-os" -f "$(ROOT_DIR)tests/values/00-base.yaml"
	"$(ROOT_DIR)scripts/render-matrix.sh" "$${TMPDIR:-/tmp}/unifi-os-render"

schema: ## Regenerate charts/unifi-os/values.schema.json (needs helm dependency update)
	@test -d "$(ROOT_DIR)charts/unifi-os/charts" || helm dependency update "$(ROOT_DIR)charts/unifi-os"
	cd "$(ROOT_DIR)cmd/schema-gen" && go run .

schema-check: ## Run the generator's tests; fail if values.schema.json is stale
	@test -d "$(ROOT_DIR)charts/unifi-os/charts" || helm dependency update "$(ROOT_DIR)charts/unifi-os"
	cd "$(ROOT_DIR)cmd/schema-gen" && go vet ./... && go test ./... && go run . -check

latest: ## Show the latest UniFi OS Server release
	"$(ROOT_DIR)scripts/uos-latest.sh"

check-update: ## Compare uos-version.env with the latest release
	"$(ROOT_DIR)scripts/uos-latest.sh" --check

bump: ## Bump uos-version.env + Chart.yaml to the latest release [FROM_FILE=fw.json]
	"$(ROOT_DIR)scripts/bump-uos-version.sh" $(if $(FROM_FILE),--from-file "$(FROM_FILE)",--latest)

diff-upstream: ## Diff two upstream installers' rootfs [OLD=<url> NEW=<url>]
	PLATFORM="$(or $(PLATFORM),linux/amd64)" "$(ROOT_DIR)scripts/diff-uos-images.sh" $(if $(OLD),--old "$(OLD)") $(if $(NEW),--new "$(NEW)")

# The upgrade contract (CLAUDE.md): status is JSON in file-dumps/upgrade/, because make
# turns every failing exit code into 2. upgrade and upgrade-verify exit 0 iff verified.
upgrade-check: ## Is a newer release out? Writes file-dumps/upgrade/check.json [FROM_FILE=fw.json]
	"$(ROOT_DIR)scripts/upgrade.sh" check $(if $(FROM_FILE),--from-file "$(FROM_FILE)")

upgrade: ## Bump, diff upstream, build/test/schema-check; writes report.json, report.md, CHANGELOG.md [FROM_FILE=fw.json]
	"$(ROOT_DIR)scripts/upgrade.sh" run $(if $(FROM_FILE),--from-file "$(FROM_FILE)")

upgrade-verify: ## Re-run build/test/schema-check on the bumped tree and rewrite the report
	"$(ROOT_DIR)scripts/upgrade.sh" verify

extract-container-configs: ## Dump configs from a live upstream podman install into file-dumps/configs
	rm -rf "$(ROOT_DIR)$(CONFIG_DUMP_DIR)" && mkdir -p "$(ROOT_DIR)$(CONFIG_DUMP_DIR)"
	sudo -u "$(CONTAINER_USER)" env CONTAINER="$(CONTAINER)" bash -lc 'cd /tmp && podman exec -i "$$CONTAINER" bash -s' < "$(ROOT_DIR)scripts/extract-container-configs.sh"
	sudo -u "$(CONTAINER_USER)" env CONTAINER="$(CONTAINER)" bash -lc 'cd /tmp && podman exec "$$CONTAINER" cat /tmp/configs.tar.gz' \
		| tar -xz -C "$(ROOT_DIR)$(CONFIG_DUMP_DIR)" --strip-components=1
