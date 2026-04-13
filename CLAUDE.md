# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A Helm chart that runs Ubiquiti's UniFi OS Server in Kubernetes. The project extracts the upstream OCI image from Ubiquiti's self-extracting installer binary, patches it for external database connections, and wraps it in a Helm chart with optional PostgreSQL (CloudNativePG) and RabbitMQ subcharts. MongoDB runs embedded inside the container (hardcoded by UniFi).

## Commands

### Build the Docker image
```bash
make build TAG=5.0.6 PLATFORMS=linux/amd64
# Uses podman. Requires binwalk, skopeo, umoci, curl, jq.
# Override installer URL: make build UOS_INSTALLER_URL=<url>
```

### Install/upgrade the chart
```bash
cp values.env.example.yaml values.env.yaml
# Edit values.env.yaml with real passwords

helm repo add unifi-os https://connorsapps.github.io/unifi-os-helm
helm repo update
helm upgrade -n unifi --create-namespace unifi unifi-os/unifi-os --install -f values.env.yaml
```

### Reverse-engineering utilities
```bash
make extract-container-configs   # Extract live configs from running container into file-dumps/configs/
make extract-systemd-map         # Dump systemd unit definitions into file-dumps/systemd-services/
```

### Update Helm dependencies
```bash
helm dependency update charts/unifi-os
```

## Architecture

### Chart templating: HULL
The chart uses [HULL](https://github.com/vidispine/hull) as a meta-templating engine. Almost every Kubernetes object (StatefulSet, Services, ConfigMaps, Secrets, Routes) is defined as data in `charts/unifi-os/values.yaml` under `hull.objects`, not as separate template files. `charts/unifi-os/templates/hull.yaml` is a single line that delegates all rendering to HULL.

Values needing Helm template logic use the `_HT!` prefix for inline Go templates within the YAML data.

### Template helpers (`charts/unifi-os/templates/_helpers.tpl`)
Provides functions for resolving database connections:
- `unifi-os.postgresHost` — resolves hostname from explicit `connection.host` or derives from CloudNativePG cluster name
- `unifi-os.rabbitmqURI` — builds RabbitMQ connection URI with password injection from secrets
- Connection merging: `global.<service>.connection` overrides chart-local `<service>.connection` (for umbrella chart usage)


### Dockerfile
Multi-stage build that:
1. Downloads Ubiquiti's self-extracting installer binary
2. Extracts the embedded OCI image using `binwalk`, `skopeo`, `umoci`
3. Patches upstream systemd services (disables stub services, redirects nginx logs to stdout/stderr, stubs out embedded PostgreSQL)
4. Bakes in PostgreSQL 14 client wrappers for external connections
5. Generates `/entrypoint.sh` from the OCI runtime config

### Services
The container runs upstream systemd managing ~15 services intact. See `SERVICES.md` for the full reference. Key patched behaviors:
- `uos-discovery-client` replaced with a Node.js HTTP shim (defined in `values.yaml` ConfigMap `discovery-shim-script`)
- `uos-agent` stubbed out (disabled with `Restart=no`)
- PostgreSQL externalized; embedded instance replaced with client wrappers

### Dependencies
PostgreSQL and RabbitMQ can be toggled between bundled subcharts and external instances:
- PostgreSQL: CloudNativePG operator (`postgres.enabled: true`); requires CloudNativePG operator installed in cluster
- RabbitMQ: CloudPirates subchart (`rabbitmq.enabled: true`)
- MongoDB: runs embedded inside the container via the bundled `mongodb.service` — hardcoded by UniFi, not configurable externally

For external instances, set `global.<service>.connection.host` (and credentials) in your values override file.

### Optional features
Both are disabled by default; enable in values:
- **Backups**: `backup` section — runs `unifi-backup` CronJob with a local UniFi OS admin account
- **Metrics**: `unifiExporter` section — runs `unpoller` exporter for Prometheus scraping

## Key files
| Path | Purpose |
|------|---------|
| `Dockerfile` | Image extraction and patching |
| `Makefile` | Build, push, extraction targets |
| `charts/unifi-os/values.yaml` | All K8s object definitions (HULL) + service config |
| `charts/unifi-os/templates/_helpers.tpl` | Connection resolution helpers |
| `values.env.example.yaml` | Template for environment-specific overrides |
| `SERVICES.md` | Reference for all ~15 UniFi OS systemd services |
| `file-dumps/` | Extracted container configs and systemd maps (for reverse-engineering) |
