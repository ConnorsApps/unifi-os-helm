SHELL := /usr/bin/env bash

ROOT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Pinned UniFi OS Server release (version, per-arch installer URLs + sha256).
# Update it with `make bump` / scripts/bump-uos-version.sh.
include $(ROOT_DIR)uos-version.env

# Build configuration (override at runtime, e.g. make build TAG=latest)
IMAGE ?= ghcr.io/connorsapps/unifi-os
TAG ?= $(UOS_VERSION)
PLATFORMS ?= linux/amd64
# Optional single-installer override (any arch). Leave empty to use the
# per-arch URLs from uos-version.env, selected by the build's target arch.
UOS_INSTALLER_URL ?=
UOS_INSTALLER_SHA256 ?=
# Set to false to turn Dockerfile patch-target failures into warnings.
PATCH_STRICT ?= true
# Platform for verify-image (e.g. linux/arm64 for a build-all -arm64 tag).
PLATFORM ?=

# UniFi version baked into /usr/lib/version. Independent of TAG so custom tags
# (latest, test, <v>-arm64) don't leak into the image; empty with an installer
# override, in which case the Dockerfile parses it from the installer URL.
UOS_BUILD_VERSION = $(if $(UOS_INSTALLER_URL),,$(UOS_VERSION))

BUILD_ARGS = \
	--build-arg "VERSION=$(UOS_BUILD_VERSION)" \
	--build-arg "UOS_INSTALLER_URL=$(UOS_INSTALLER_URL)" \
	--build-arg "UOS_INSTALLER_SHA256=$(UOS_INSTALLER_SHA256)" \
	--build-arg "UOS_INSTALLER_URL_AMD64=$(UOS_INSTALLER_URL_AMD64)" \
	--build-arg "UOS_INSTALLER_SHA256_AMD64=$(UOS_INSTALLER_SHA256_AMD64)" \
	--build-arg "UOS_INSTALLER_URL_ARM64=$(UOS_INSTALLER_URL_ARM64)" \
	--build-arg "UOS_INSTALLER_SHA256_ARM64=$(UOS_INSTALLER_SHA256_ARM64)" \
	--build-arg "PATCH_STRICT=$(PATCH_STRICT)"

# Upgrade helpers: FROM_FILE = saved fw-update API response (offline bump);
# OLD/NEW = installer URLs to diff (defaults: see scripts/diff-uos-images.sh).
FROM_FILE ?=
OLD ?=
NEW ?=

# Extraction configuration
CONTAINER ?= uosserver
CONTAINER_USER ?= uosserver
FILE_DUMPS_DIR ?= file-dumps
CONFIG_DUMP_DIR ?= $(FILE_DUMPS_DIR)/configs
CONFIG_TARBALL ?= $(FILE_DUMPS_DIR)/configs.tar.gz
SYSTEMD_DUMP_DIR ?= $(FILE_DUMPS_DIR)/systemd-services

.PHONY: help build build-all verify-image latest check-update bump diff-upstream extract-container-configs extract-systemd-map

help:
	@echo "Available targets:"
	@echo "  make build                      Build the UniFi OS image for PLATFORMS (podman)"
	@echo "  make build-all                  Build amd64 + arm64 and assemble a multi-arch manifest"
	@echo "  make verify-image [PLATFORM=linux/arm64]  Static checks on the built image"
	@echo "  make latest                     Show the latest UniFi OS Server release from Ubiquiti"
	@echo "  make check-update               Compare uos-version.env with the latest release"
	@echo "  make bump [FROM_FILE=fw.json]   Bump uos-version.env + chart to the latest release"
	@echo "  make diff-upstream [OLD=<url> NEW=<url>]  Diff two upstream installers' rootfs"
	@echo "  make extract-container-configs  Extract live container configs into file-dumps/configs"
	@echo "  make extract-systemd-map        Dump systemd maps into file-dumps/systemd-services"

build:
	@echo "Building $(IMAGE):$(TAG) for $(PLATFORMS)"
	podman build . \
		--platform "$(PLATFORMS)" \
		$(BUILD_ARGS) \
		--tag "$(IMAGE):$(TAG)"

# One build per arch, then a manifest list under $(IMAGE):$(TAG).
# arm64 on an x86 host needs qemu-user-static (binfmt) for the RUN steps.
# Verify each: make verify-image TAG=$(TAG)-arm64 PLATFORM=linux/arm64
# Push with: podman manifest push --all $(IMAGE):$(TAG) docker://$(IMAGE):$(TAG)
build-all:
	@test -z "$(UOS_INSTALLER_URL)" || { echo "build-all uses the per-arch URLs in uos-version.env; unset UOS_INSTALLER_URL"; exit 1; }
	@test -n "$(UOS_INSTALLER_URL_ARM64)" || { echo "UOS_INSTALLER_URL_ARM64 is empty in uos-version.env"; exit 1; }
	podman build . --platform linux/amd64 $(BUILD_ARGS) --tag "$(IMAGE):$(TAG)-amd64"
	podman build . --platform linux/arm64 $(BUILD_ARGS) --tag "$(IMAGE):$(TAG)-arm64"
	-podman manifest rm "$(IMAGE):$(TAG)" 2>/dev/null
	podman manifest create "$(IMAGE):$(TAG)"
	podman manifest add "$(IMAGE):$(TAG)" "containers-storage:$(IMAGE):$(TAG)-amd64"
	podman manifest add "$(IMAGE):$(TAG)" "containers-storage:$(IMAGE):$(TAG)-arm64"
	podman manifest inspect "$(IMAGE):$(TAG)"

verify-image:
	PLATFORM="$(PLATFORM)" "$(ROOT_DIR)scripts/verify-image.sh" "$(IMAGE):$(TAG)" "$(UOS_BUILD_VERSION)"

latest:
	"$(ROOT_DIR)scripts/uos-latest.sh"

check-update:
	"$(ROOT_DIR)scripts/uos-latest.sh" --check

# For a specific (non-latest) version: scripts/bump-uos-version.sh X.Y.Z --url-amd64 <url> ...
bump:
	"$(ROOT_DIR)scripts/bump-uos-version.sh" $(if $(FROM_FILE),--from-file "$(FROM_FILE)",--latest)

diff-upstream:
	"$(ROOT_DIR)scripts/diff-uos-images.sh" $(if $(OLD),--old "$(OLD)") $(if $(NEW),--new "$(NEW)")

extract-container-configs:
	mkdir -p "$(ROOT_DIR)$(FILE_DUMPS_DIR)"
	sudo -u "$(CONTAINER_USER)" env CONTAINER="$(CONTAINER)" bash -lc 'cd /tmp && podman exec -i "$$CONTAINER" bash -s' < "$(ROOT_DIR)scripts/extract-container-configs.sh"
	sudo -u "$(CONTAINER_USER)" env CONTAINER="$(CONTAINER)" bash -lc 'cd /tmp && podman exec "$$CONTAINER" cat /tmp/configs.tar.gz' > "$(ROOT_DIR)$(CONFIG_TARBALL)"
	rm -rf "$(ROOT_DIR)$(CONFIG_DUMP_DIR)"
	mkdir -p "$(ROOT_DIR)$(CONFIG_DUMP_DIR)"
	tar -xzf "$(ROOT_DIR)$(CONFIG_TARBALL)" -C "$(ROOT_DIR)$(CONFIG_DUMP_DIR)" --strip-components=1
	rm -f "$(ROOT_DIR)$(CONFIG_TARBALL)"
	@echo "Config dump extracted to $(CONFIG_DUMP_DIR)"

extract-systemd-map:
	@if [ -f "$(ROOT_DIR)$(SYSTEMD_DUMP_DIR)" ]; then \
		mv "$(ROOT_DIR)$(SYSTEMD_DUMP_DIR)" "$(ROOT_DIR)$(SYSTEMD_DUMP_DIR).legacy"; \
		echo "Moved legacy file to $(SYSTEMD_DUMP_DIR).legacy"; \
	fi
	mkdir -p "$(ROOT_DIR)$(SYSTEMD_DUMP_DIR)"
	podman run --rm \
		-i \
		--entrypoint /bin/bash \
		-v "$(ROOT_DIR)$(SYSTEMD_DUMP_DIR):/out" \
		"$(IMAGE):$(TAG)" \
		-s < "$(ROOT_DIR)scripts/extract-systemd-map.sh"
	test -s "$(ROOT_DIR)$(SYSTEMD_DUMP_DIR)/units.txt"
	@echo "Systemd map extracted to $(SYSTEMD_DUMP_DIR)"
