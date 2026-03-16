SHELL := /usr/bin/env bash

ROOT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Build configuration (override at runtime, e.g. make build TAG=latest)
IMAGE ?= todo
TAG ?= 5.0.6
PLATFORMS ?= linux/amd64
# amd64: https://fw-download.ubnt.com/data/unifi-os-server/1856-linux-x64-5.0.6-33f4990f-6c68-4e72-9d9c-477496c22450.6-x64
# arm64: https://fw-download.ubnt.com/data/unifi-os-server/df5b-linux-arm64-5.0.6-f35e944c-f4b6-4190-93a8-be61b96c58f4.6-arm64
UOS_INSTALLER_URL ?= https://fw-download.ubnt.com/data/unifi-os-server/1856-linux-x64-5.0.6-33f4990f-6c68-4e72-9d9c-477496c22450.6-x64

# Extraction configuration
CONTAINER ?= uosserver
CONTAINER_USER ?= uosserver
FILE_DUMPS_DIR ?= file-dumps
CONFIG_DUMP_DIR ?= $(FILE_DUMPS_DIR)/configs
CONFIG_TARBALL ?= $(FILE_DUMPS_DIR)/configs.tar.gz
SYSTEMD_DUMP_DIR ?= $(FILE_DUMPS_DIR)/systemd-services

.PHONY: help build extract-container-configs extract-systemd-map

help:
	@echo "Available targets:"
	@echo "  make build                      Build and push UniFi OS image (podman)"
	@echo "  make extract-container-configs  Extract live container configs into file-dumps/configs"
	@echo "  make extract-systemd-map        Dump systemd maps into file-dumps/systemd-services"

build:
	@echo "Building $(IMAGE):$(TAG) for $(PLATFORMS)"
	podman build . \
		--platform "$(PLATFORMS)" \
		--build-arg "UOS_INSTALLER_URL=$(UOS_INSTALLER_URL)" \
		--tag "$(IMAGE):$(TAG)"
	podman push "$(IMAGE):$(TAG)"

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
