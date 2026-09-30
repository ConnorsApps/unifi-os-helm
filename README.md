# UniFi OS Server — Kubernetes Helm Chart

Runs Ubiquiti's [UniFi OS Server](https://ui.com/download/unifi-os-server) in
Kubernetes, so you can self-host the **UniFi Network** application (the
controller for switches, APs and gateways) without a UniFi Console. It succeeds
the standalone Network Application.

UniFi OS Server does **not** support Protect, Access, Talk or Connect; those
still need a Console.

> **Warning:** experimental, not production-ready. There's a lot of AI work I don't have time to verify all of.

## Architecture

Upstream systemd, managing ~15 tightly coupled services, runs intact in one
container. PostgreSQL and RabbitMQ run outside it (bundled subcharts or your
own). MongoDB stays embedded: UniFi hardcodes it.

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
  │    └─ unifi-os image (unifi-core, unifi, ulp-go, nginx, identity services,
  │                       mongodb — embedded, not externalized)
  ├─ PostgreSQL          (CloudNativePG subchart or external)
  └─ RabbitMQ            (CloudPirates subchart or external)
```

## Prerequisites

- Kubernetes and Helm 3
- [CloudNativePG operator](https://cloudnative-pg.io/) for the bundled PostgreSQL (`postgres.enabled: true`)
- [cert-manager](https://cert-manager.io/) for `unifi.tls.certManager` (optional)

## Quick start

```bash
cp values.env.example.yaml values.env.yaml   # set passwords, storage, routes
helm repo add unifi-os https://connorsapps.github.io/unifi-os-helm
helm upgrade --install unifi unifi-os/unifi-os -n unifi --create-namespace -f values.env.yaml
```

Minimal credentials (see [DATABASE.md](https://github.com/ConnorsApps/unifi-os-helm/blob/main/DATABASE.md) for secret-based options):

```yaml
global:
  postgres:
    connection:
      password: "your-pg-password"
  rabbitmq:
    connection:
      password: "your-rabbit-password"
      erlangCookie: "your-erlang-cookie"
```

## Configuration

| Topic | Where |
|---|---|
| Every value, with defaults | [values.yaml](https://github.com/ConnorsApps/unifi-os-helm/blob/main/charts/unifi-os/values.yaml) |
| Example override file | [values.env.example.yaml](https://github.com/ConnorsApps/unifi-os-helm/blob/main/values.env.example.yaml) |
| PostgreSQL: bundled vs external, credentials, **the version 14 ceiling** | [DATABASE.md](https://github.com/ConnorsApps/unifi-os-helm/blob/main/DATABASE.md) |
| TLS: self-signed, existing secret, cert-manager, BackendTLSPolicy | [TLS.md](https://github.com/ConnorsApps/unifi-os-helm/blob/main/TLS.md) |
| What each UniFi service does | [SERVICES.md](https://github.com/ConnorsApps/unifi-os-helm/blob/main/SERVICES.md) |

Optional, all off by default:

- `backup`: scheduled backups with [unifi-backup](https://github.com/ConnorsApps/unifi-backup), using a local UniFi OS admin.
- `unifiExporter`: Prometheus metrics with [unpoller](https://github.com/unpoller/unpoller) (API key, username/password, or an existing secret), plus an optional ServiceMonitor.
- `unifi.gateway`: Gateway API routes (HTTPS, inform, TCP 8080, UDP discovery/STUN/syslog).

## The image

The [Dockerfile](https://github.com/ConnorsApps/unifi-os-helm/blob/main/Dockerfile) pulls the OCI image out of Ubiquiti's installer and patches it for Kubernetes ([image/](https://github.com/ConnorsApps/unifi-os-helm/tree/main/image)). The installer version is pinned in [uos-version.env](https://github.com/ConnorsApps/unifi-os-helm/blob/main/uos-version.env).

```bash
make build          # podman; make help lists the rest
make verify-image
```

## Legal

Not affiliated with, endorsed by, or sponsored by Ubiquiti Inc. "UniFi" and
"UniFi OS" are trademarks of Ubiquiti Inc. Independent community work for
self-hosting; use at your own risk. There's some AI ducktape holding this project together.
