# PostgreSQL Setup

UniFi OS requires PostgreSQL **14** — this is a ceiling, not a minimum. See
[Version ceiling](#version-ceiling) before changing it.

The chart supports two modes:

| Mode | When to use |
|------|-------------|
| **Bundled CNPG** (`postgres.enabled: true`) | New deployments; no existing PostgreSQL |
| **External** (`postgres.enabled: false`) | You manage PostgreSQL yourself (self-hosted, RDS, etc.) |

---

## Version ceiling

**Do not run this on PostgreSQL 15 or newer.**

UniFi's `ulp-go` (the login provider behind `/api/auth/login`) builds SQL in which a
bind placeholder is immediately followed by a keyword — `... = $1AND ...`. PostgreSQL
accepted that through 14; PostgreSQL 15 added the `param_junk` lexer rule
([commit `2549f0661`](https://www.postgresql.org/docs/15/release-15.html)) and now
rejects it:

```
ERROR:  trailing junk after parameter at or near "$1AND"
```

`ulp-go` hits this in `prepareMainEngine` while syncing `schema_migrations`, exits
with status 11, and systemd stops retrying after `StartLimitBurst=10`. `unifi-core`
then proxies logins to a dead `127.0.0.1:9080`, returns `401`, and the console shows
**"Login Unavailable — Please reboot the console or try again later."** Nothing else
breaks, which makes it easy to misread as an auth problem rather than a database one.

Two traps when evaluating an upgrade:

- **A live `pg_upgrade` looks clean.** `ulp-go`'s existing connections keep working, so
  the console stays up until the next pod restart — possibly days later. Always restart
  `ulp-go` (or the whole pod) as part of the test.
- **CloudNativePG's major upgrade is one-way.** There is no in-place downgrade; getting
  back to 14 means a logical dump from the newer server, stripping constructs that
  `psql 14` cannot parse (`\restrict` / `\unrestrict` headers, `SET transaction_timeout`),
  and restoring into a freshly created cluster.

The ceiling lifts only when Ubiquiti fixes that SQL. Re-check on each UniFi OS Server
release; note that PostgreSQL 14 reaches end-of-life in November 2026.

## Bundled CNPG

Requires the [CloudNativePG operator](https://cloudnative-pg.io/) installed in your cluster first:

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace
```

### Option A — password (chart-managed secrets)

Set a password and the chart creates all credential secrets automatically:

```yaml
postgres:
  enabled: true

global:
  postgres:
    connection:
      password: "your-strong-password"
```

The chart generates:
- `pg-login-<rolename>` — one `kubernetes.io/basic-auth` secret per CNPG role (8 total)
- `unifi-pg-auth` — secret used for the app pod's `PGPASSWORD`

### Option B — useExistingSecrets (bring your own secrets)

Create the `pg-login-*` secrets yourself before installing — for example via ESO, Vault, or SOPS:

```yaml
postgres:
  enabled: true

global:
  postgres:
    connection:
      useExistingSecrets: true
```

**Secret names are fixed.** You must create exactly these 8 secrets in the same namespace:

| Secret name | Role |
|-------------|------|
| `pg-login-unifi-core` | `unifi-core` |
| `pg-login-ulp-go` | `ulp-go` |
| `pg-login-uid` | `uid` |
| `pg-login-unifi-credential-server` | `unifi-credential-server` |
| `pg-login-unifi-directory` | `unifi-directory` |
| `pg-login-ucs-agent` | `ucs-agent` |
| `pg-login-ucs-update` | `ucs-update` |
| `pg-login-unifi-identity-update` | `unifi-identity-update` |

Each must be `type: kubernetes.io/basic-auth` with `username` matching the role name exactly (CNPG requirement) and a `password` key:

```yaml
apiVersion: v1
kind: Secret
type: kubernetes.io/basic-auth
metadata:
  name: pg-login-unifi-core
  namespace: unifi
stringData:
  username: unifi-core
  password: "your-password"
```

Roles may have unique passwords. Each service reads its own password from its role's `pg-login-<rolename>` secret at startup; `pg-login-unifi-core` is only used for the app pod's own `PGPASSWORD` and the CNPG readiness check.

### Storage / HA

```yaml
postgres:
  enabled: true
  cluster:
    storage:
      size: 20Gi
      storageClass: "fast-ssd"
    instances: 3   # 1 primary + 2 replicas
```

---

## External PostgreSQL

### Prerequisites

Create the required roles and databases manually. Run as superuser:

```sql
CREATE ROLE "unifi-core" LOGIN PASSWORD 'your-password';
CREATE ROLE "ulp-go" LOGIN PASSWORD 'your-password' CREATEDB;
CREATE ROLE "uid" LOGIN PASSWORD 'your-password' CREATEDB;
CREATE ROLE "unifi-credential-server" LOGIN PASSWORD 'your-password' CREATEDB;
CREATE ROLE "unifi-directory" LOGIN PASSWORD 'your-password' CREATEDB;
CREATE ROLE "ucs-agent" LOGIN PASSWORD 'your-password' CREATEDB;
CREATE ROLE "ucs-update" LOGIN PASSWORD 'your-password' CREATEDB;
CREATE ROLE "unifi-identity-update" LOGIN PASSWORD 'your-password' CREATEDB;

CREATE DATABASE "unifi-core" OWNER "unifi-core";
CREATE DATABASE "ulp-go" OWNER "ulp-go";
CREATE DATABASE "uid" OWNER "uid";
CREATE DATABASE "unifi-credential-server" OWNER "unifi-credential-server";
CREATE DATABASE "ucs-user-assets" OWNER "unifi-credential-server";
CREATE DATABASE "unifi-directory" OWNER "unifi-directory";
CREATE DATABASE "ucs-agent" OWNER "ucs-agent";
CREATE DATABASE "unifi-identity-update" OWNER "ucs-update";
```

### Option A — plaintext password

```yaml
postgres:
  enabled: false

global:
  postgres:
    connection:
      host: "postgres.example.com"
      password: "your-password"
```

### Option B — existing K8s secret

```yaml
postgres:
  enabled: false

global:
  postgres:
    connection:
      host: "postgres.example.com"
      existingSecret:
        name: "pg-credentials"
        passwordKey: "password"
```

---

## Umbrella chart

When this chart is a subchart, set `global` in the parent values:

```yaml
global:
  postgres:
    connection:
      host: "shared-postgres.infra.svc.cluster.local"
      password: "shared-password"
```

---

## Troubleshooting

**`Login Unavailable` in the web UI / `trailing junk after parameter` in the logs:**
The Postgres server is 15 or newer. See [Version ceiling](#version-ceiling) — `ulp-go`
cannot start against it. Confirm with:
```bash
kubectl exec -n unifi <pod> -c unifi-os -- systemctl is-active ulp-go
kubectl exec -n unifi <pod> -c unifi-os -- tail /data/ulp-go/log/db.log
```

**Pod stuck in init:**
The `wait-postgres` init container waits until the postgres host is reachable. Verify the CNPG cluster is ready and `connection.host` resolves.

**CNPG cluster fails to start:**
With `global.postgres.connection.useExistingSecrets: true`, check that all 8 `pg-login-*` secrets exist in the namespace and each has a `username` field matching the role name exactly.

**Services can't connect:**
The init container writes per-service config at startup. Check its logs:
```bash
kubectl logs -n unifi <pod> -c init
```
