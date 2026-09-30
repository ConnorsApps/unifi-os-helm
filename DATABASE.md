# PostgreSQL

UniFi OS needs PostgreSQL **14**. That is a ceiling, not a minimum: see
[Version ceiling](#version-ceiling).

| Mode | Use when |
|---|---|
| Bundled CNPG (`postgres.enabled: true`) | No PostgreSQL yet |
| External (`postgres.enabled: false`) | You run PostgreSQL yourself (self-hosted, RDS, …) |

UniFi uses a role and database per service. Each role's password lives in a
`kubernetes.io/basic-auth` secret named `pg-login-<role>` (keys `username`,
`password`; `username` must equal the role):

| Role | Owns database(s) |
|---|---|
| `unifi-core` | `unifi-core` |
| `ulp-go` | `ulp-go` |
| `uid` | `uid` |
| `unifi-credential-server` | `unifi-credential-server`, `ucs-user-assets` |
| `unifi-directory` | `unifi-directory` |
| `ucs-agent` | `ucs-agent` |
| `ucs-update` | `unifi-identity-update` |
| `unifi-identity-update` | none (the service logs in to `unifi-identity-update`) |

## Version ceiling

**Do not use PostgreSQL 15 or newer.** `ulp-go`, the login provider, sends SQL
with a placeholder followed directly by a keyword (`... = $1AND ...`).
PostgreSQL 15 rejects it ([release notes](https://www.postgresql.org/docs/15/release-15.html), commit `2549f0661`):

```
ERROR:  trailing junk after parameter at or near "$1AND"
```

`ulp-go` then exits 11 in `prepareMainEngine` until systemd gives up
(`StartLimitBurst=10`). `unifi-core` proxies logins to a dead `127.0.0.1:9080`
and the console shows **"Login Unavailable"**. Nothing else breaks, so it looks
like an auth problem.

When evaluating an upgrade:

- **A live `pg_upgrade` looks clean.** Existing `ulp-go` connections keep
  working until the next restart. Always restart `ulp-go` (or the pod) to test.
- **CloudNativePG major upgrades are one-way.** Getting back to 14 means a
  logical dump from the newer server, stripping what `psql 14` can't parse
  (`\restrict`/`\unrestrict`, `SET transaction_timeout`), and restoring into a
  new cluster.

The ceiling lifts only when Ubiquiti fixes the SQL; recheck each release.
PostgreSQL 14 reaches end of life in November 2026.

## Bundled CNPG

Install the [CloudNativePG operator](https://cloudnative-pg.io/) first:

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace
```

**Password (chart-managed secrets).** The chart creates every `pg-login-<role>`
secret, plus `unifi-pg-auth` for the app:

```yaml
postgres:
  enabled: true
global:
  postgres:
    connection:
      password: "your-strong-password"
```

**Your own secrets** (ESO, Vault, SOPS, …). Create all eight `pg-login-<role>`
secrets in the release namespace before installing. Passwords may differ per
role:

```yaml
postgres:
  enabled: true
global:
  postgres:
    connection:
      useExistingSecrets: true
```

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

**Storage / HA:** `postgres.cluster.storage.size`, `.storageClass`, `postgres.cluster.instances`.

## External PostgreSQL

Create the roles and databases as a superuser:

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

Every service connects with the one password below (optionally set per role
with your own `pg-login-<role>` secrets):

```yaml
postgres:
  enabled: false
global:
  postgres:
    connection:
      host: "postgres.example.com"
      password: "your-password"      # or:
      # existingSecret:
      #   name: pg-credentials
      #   passwordKey: password
```

In an umbrella chart, set the same `global.postgres.connection` in the parent.

## Troubleshooting

**"Login Unavailable" / `trailing junk after parameter`:** the server is
PostgreSQL 15+. See [Version ceiling](#version-ceiling). Confirm:

```bash
kubectl exec -n unifi monolith-0 -c unifi-os -- systemctl is-active ulp-go
kubectl exec -n unifi monolith-0 -c unifi-os -- tail /data/ulp-go/log/db.log
```

**Pod stuck in `Init`:** the `init` container waits until the PostgreSQL host
accepts TCP connections (`kubectl logs -n unifi monolith-0 -c init`). Check
that the CNPG cluster is ready or that `connection.host`/`port` resolve.

**CNPG cluster won't start** with `useExistingSecrets: true`: all eight
`pg-login-*` secrets must exist, each with `username` equal to the role.

**A service can't connect:** the init container writes each service's DB config
at startup; check its logs as above.
