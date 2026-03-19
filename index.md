# UniFi OS Server — Kubernetes Helm Chart

A Helm chart that runs Ubiquiti's [UniFi OS Server](https://ui.com/download/unifi-os-server) in Kubernetes —
letting you self-host the **UniFi Network** application (the controller for
switches, APs, gateways, etc.) without buying a UniFi Console. This is the
successor to the standalone Network Application that Ubiquiti previously offered.

UniFi OS Server does **not** support UniFi Protect (cameras), Access, Talk, or
Connect — those still require a UniFi Console.

The upstream runtime model (systemd managing ~15 tightly coupled services) is
kept intact while PostgreSQL, MongoDB, and RabbitMQ are exposed as explicit,
replaceable dependencies. Each dependency can be toggled between a bundled
subchart and an externally-managed instance.

> **Warning** — this project is experimental and not suitable for production yet. There's a lot of AI work I don't have time to verify all of.

## Architecture

### Upstream (what Ubiquiti ships 🤮)

```
Installer binary
  └─ Podman container
       └─ systemd
            ├─ unifi-core        (Node.js — platform API)
            ├─ unifi             (Java — Network controller)
            ├─ ulp-go            (Go — identity platform)
            ├─ nginx             (reverse proxy / TLS)
            ├─ postgresql        (embedded)
            ├─ mongodb           (embedded)
            ├─ rabbitmq + epmd   (embedded)
            └─ 7 more identity/agent services …
```

### This chart 😎

```
Helm release
  ├─ StatefulSet (single container, upstream systemd startup)
  │    └─ unifi-os image (unifi-core, unifi, ulp-go, nginx, identity services)
  ├─ PostgreSQL          (CloudNativePG subchart or external)
  ├─ MongoDB             (CloudPirates subchart or external)
  └─ RabbitMQ            (CloudPirates subchart or external)
```

## Why HULL

This chart is built on [HULL](https://github.com/vidispine/hull), which means
almost every Kubernetes object (services, routes, secrets, env vars, resource limits,
etc.) is defined as data in `charts/unifi-os/values.yaml` under `hull.objects`. You can override
or extend any object in your own values file without forking the chart. Values
that need Helm template logic use the `_HT!` prefix for inline [Go Helm templates](https://helm.sh/docs/chart_template_guide/).

## Repository contents

| Path | Purpose |
|------|---------|
| [Dockerfile](Dockerfile) | Extracts the upstream OCI image and repackages it as a standard Docker image. |
| [Makefile](Makefile) | Build/push the image, extract configs, dump systemd maps. |
| [Chart.yaml](charts/unifi-os/Chart.yaml) | Helm chart definition (app version 5.0.6) with subchart dependencies. |
| [values.yaml](charts/unifi-os/values.yaml) | Primary chart values — StatefulSet, services, secrets, Gateway API routes. |
| [values.env.example.yaml](values.env-example.yaml) | Environment-specific overrides (registry, passwords, hostnames). |
| [SERVICES.md](SERVICES.md) | Reference for every UniFi OS service, its role, and dependencies. |
| `charts/unifi-os/templates/` | HULL entrypoint, helpers, and Postgres override secrets. |
| `scripts/` | Extraction utilities for reverse-engineering the upstream image. |

## Prerequisites

- Kubernetes
- Helm 3+
- [CloudNativePG operator](https://cloudnative-pg.io/) if using the bundled PostgreSQL subchart (`postgres.enabled: true`)

## Quick start

### 1. Configure

```bash
cp values.env.example.yaml values.env.yaml
```

Edit `values.env.yaml` and set real passwords for
`global.postgres.connection.password`, `global.mongodb.connection.password`,
and `global.rabbitmq.connection.password`.

### 2. Install

```bash
helm repo add unifi-os https://connorsapps.github.io/unifi-os-helm
helm repo update
helm upgrade -n unifi --create-namespace unifi unifi-os/unifi-os --install \
  -f values.env.yaml
```

## Optional features

The chart includes opt-in support for:

- **Automated backups** via [unifi-backup](https://github.com/ConnorsApps/unifi-backup) — runs as a CronJob using a local UniFi OS admin account.
- **Prometheus metrics** via [unpoller](https://github.com/unpoller/unpoller) — scrapes UniFi OS and exposes metrics for Prometheus.

Both are disabled by default. See `values.env.example.yaml` and the `backup` / `unifiExporter` sections in `values.yaml` to enable them.

## Legal

This project is **not affiliated with, endorsed by, or sponsored by Ubiquiti Inc.**
"UniFi" and "UniFi OS" are trademarks of Ubiquiti Inc. This repository is independent
community work for self-hosting purposes. Use at your own risk. There's some AI ducktape holding this project together.
