# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A Helm chart that runs Ubiquiti's UniFi OS Server in Kubernetes. The project extracts the upstream OCI image from Ubiquiti's self-extracting installer binary, patches it for external database connections, and wraps it in a Helm chart with optional PostgreSQL (CloudNativePG) and RabbitMQ subcharts. MongoDB runs embedded inside the container (hardcoded by UniFi).

## Commands

### Build the Docker image
```bash
make build TAG=5.1.21 PLATFORMS=linux/amd64
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

### Local render / backwards-compat tests (gitignored output)
```bash
scripts/test-render-compat.sh <output-dir>   # helm template across the .render-test/values/*.yaml matrix
```
`.render-test/values/00-base.yaml` (fake secrets) is merged with each numbered scenario file (external/bundled postgres, both secret modes, both TLS modes, backup, exporter+ServiceMonitor, all 6 gateway routes, a kitchen-sink combo). The values files and the script are tracked in git; rendered output (`.render-test/golden/`, `.render-test/out/`) is gitignored. Use this matrix to check for regressions before/after template changes — diff the rendered YAML structurally (kind+name+spec), not byte-for-byte (cosmetic label/order differences are fine).

## Architecture

### Chart templating: plain Helm templates
The chart used to render via [HULL](https://github.com/vidispine/hull) (a meta-templating engine driven entirely by data in `values.yaml`); it was migrated off HULL to hand-written templates in `charts/unifi-os/templates/` — one file per resource or resource group (`statefulset.yaml`, `services.yaml`, `secrets.yaml`, `configmaps.yaml`, `routes.yaml`, `servicemonitor.yaml`, `deployment-unifi-exporter.yaml`, `cronjob-unifi-backup.yaml`, plus the pre-existing `backend-tls-policy.yaml`, `certmanager-certificate.yaml`, `postgres-role-secrets.yaml`). `values.yaml` now only holds domain configuration (image, storage, TLS, Gateway API routes, backup, exporter config, postgres/rabbitmq passthrough) plus the curated override values described below — there is no more generic `hull.objects` escape hatch.

**Critical compatibility constraint:** every object's `metadata.name` (StatefulSet `monolith`, Services `unifi`/`hotspot`/`udp`/`unifi-exporter`, Secrets, ConfigMaps, Routes, etc.) is a **hardcoded literal string in the template, not derived from a fullname/release-prefix helper**. This matches HULL's old `noObjectNamePrefixes: true` behavior and must stay this way — renaming any of these would orphan the StatefulSet's `volumeClaimTemplates`-backed PVCs and break Service selectors on upgrade. Don't "fix" this into a `{{ include "unifi-os.fullname" . }}` pattern.

### Override surface
Beyond the domain values, `unifi.*` (StatefulSet), `unifiExporter.*` (exporter Deployment), and `backup.*` (CronJob) each expose the same curated set of standard Kubernetes overrides so users don't need to fork the chart: scheduling (`nodeSelector`, `affinity`, `tolerations`, `priorityClassName`, `topologySpreadConstraints`, `runtimeClassName`), pod plumbing (`podAnnotations`, `hostAliases`, `dnsPolicy`/`dnsConfig`, `terminationGracePeriodSeconds`), security (`podSecurityContext`/`securityContext`, merged on top of whatever a workload requires by default — e.g. the `unifi-os` container's `privileged: true, runAsUser: 0` for running systemd as PID 1), and DRA (`resourceClaims` at pod level, `resources.claims` at container level). The StatefulSet additionally has `extraEnv`/`extraVolumes`/`extraVolumeMounts`/`extraInitContainers`/`serviceAccountName` and per-sidecar `journalctl.resources`/`discoveryShim.resources`. Every rendered Service (`unifi.service`, `unifi.hotspotService`, `unifi.udpService`, `unifiExporter.service`) accepts `type`/`annotations`, and `udpService` additionally accepts `externalTrafficPolicy`. Chart-wide: `commonLabels`, `commonAnnotations`, `imagePullSecrets`. See `values.env.example.yaml` for commented examples of each.

### Template helpers (`charts/unifi-os/templates/_helpers.tpl`)
- `unifi-os.labels` / `unifi-os.selectorLabels` — standard chart labels (merged with `commonLabels`) and selector labels (take a `component` param), replacing HULL's automatic label injection
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
- `uos-discovery-client` replaced with a Node.js HTTP shim (script baked into the `discovery-shim-script` ConfigMap in `templates/configmaps.yaml`)
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
| `charts/unifi-os/values.yaml` | Domain config (image, storage, TLS, Gateway routes, backup, exporter, postgres/rabbitmq passthrough) + curated override defaults |
| `charts/unifi-os/templates/` | Plain Helm templates, one file per resource/resource group |
| `charts/unifi-os/templates/_helpers.tpl` | Label + connection/secret/TLS resolution helpers |
| `values.env.example.yaml` | Template for environment-specific overrides, incl. curated override examples |
| `SERVICES.md` | Reference for all ~15 UniFi OS systemd services |
| `.render-test/values/`, `scripts/test-render-compat.sh` | Local backwards-compat render matrix (tracked; rendered output gitignored) |
| `file-dumps/` | Extracted container configs and systemd maps (for reverse-engineering) |
