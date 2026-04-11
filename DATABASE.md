# PostgreSQL Setup

UniFi OS requires PostgreSQL 14. The chart supports two modes:

| Mode | When to use |
|------|-------------|
| **Bundled CNPG** (`postgres.enabled: true`) | New deployments; no existing PostgreSQL |
| **External** (`postgres.enabled: false`) | You manage PostgreSQL yourself (self-hosted, RDS, etc.) |

---

## How credentials work

The chart needs to know the PostgreSQL password in one of two ways:

**Option A — plaintext in values:**
```yaml
global:
  postgres:
    connection:
      password: "your-password-here"
```
The chart creates a `unifi-pg-auth` K8s secret, plus per-service override secrets that embed the password into each microservice's config file.

**Option B — reference an existing K8s secret:**
```yaml
global:
  postgres:
    connection:
      existingSecret:
        name: "my-pg-secret"      # K8s secret name
        passwordKey: "password"   # key inside that secret
```
The chart creates no credential secrets. The init container reads `PGPASSWORD` from the referenced secret at pod startup and generates the service config files at runtime.

Use Option B when the secret is managed by an operator (ESO, Vault, CNPG app secret, etc.) and you don't want the password in Helm values.

### What gets created with each option

| Resource | Option A (plaintext) | Option B (existingSecret) |
|----------|---------------------|--------------------------|
| `unifi-pg-auth` | Created | Skipped |
| `postgres-unifi-core-override` | Created (embeds password) | Skipped |
| `config-override-secret-*` (7 secrets) | Created (embeds password) | Skipped |
| `pg-login-*` (8 secrets, CNPG only) | Created | Skipped |
| Service config files | From projected secrets | Generated at init time from env vars |

### The pg-login-* secrets explained

When using bundled CNPG, the chart creates 8 `pg-login-<user>` secrets — one per database role. All 8 use the same password but represent distinct DB users with different permissions per microservice. CNPG uses these to create the PostgreSQL roles. They are only needed with bundled CNPG; external postgres manages roles independently.

---

## Bundled CNPG

Requires the [CloudNativePG operator](https://cloudnative-pg.io/) installed in your cluster first.

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace
```

### Minimal values

```yaml
postgres:
  enabled: true

global:
  postgres:
    connection:
      password: "your-strong-password"
```

The host is derived automatically as `unifi-postgres-rw.<namespace>.svc.cluster.local`.

### Storage

```yaml
postgres:
  enabled: true
  cluster:
    storage:
      size: 20Gi
      storageClass: "fast-ssd"   # optional; uses cluster default if omitted
```

### High availability

```yaml
postgres:
  enabled: true
  cluster:
    instances: 3   # 1 primary + 2 replicas
```

### Using the CNPG-generated app secret (Option B)

CNPG creates an `<clusterName>-app` secret with the app user's credentials. You can reference it directly:

```yaml
postgres:
  enabled: true
  # The CNPG operator will set the password; don't put it in values.
  # Reference the CNPG-generated app secret instead:

global:
  postgres:
    connection:
      existingSecret:
        name: "unifi-postgres-app"   # CNPG creates this: <clusterName>-app
        passwordKey: "password"
```

> **Note:** When using `postgres.enabled: true` with `existingSecret`, the CNPG `Cluster` resource still needs the `unifi-pg-auth` secret for `initdb`. In this case, also set `connection.password` so `unifi-pg-auth` is created for CNPG bootstrap — or pre-create `unifi-pg-auth` yourself. After the initial cluster creation, you can remove `connection.password` from values.

The simplest approach for bundled CNPG is Option A (set `connection.password`).

---

## External PostgreSQL

### Prerequisites

Create the required databases and roles manually. The chart expects these roles and databases to exist:

| Role | Databases owned |
|------|----------------|
| `unifi-core` | `unifi-core` |
| `ulp-go` | `ulp-go` |
| `uid` | `uid` |
| `unifi-credential-server` | `unifi-credential-server`, `ucs-user-assets` |
| `unifi-directory` | `unifi-directory` |
| `ucs-agent` | `ucs-agent` |
| `ucs-update` | `unifi-identity-update` |

All roles connect with the same password. Run as superuser:

```sql
-- Create roles (adjust password)
CREATE ROLE "unifi-core" LOGIN PASSWORD 'your-password';
CREATE ROLE "ulp-go" LOGIN PASSWORD 'your-password' CREATEDB;
CREATE ROLE "uid" LOGIN PASSWORD 'your-password' CREATEDB;
CREATE ROLE "unifi-credential-server" LOGIN PASSWORD 'your-password' CREATEDB;
CREATE ROLE "unifi-directory" LOGIN PASSWORD 'your-password' CREATEDB;
CREATE ROLE "ucs-agent" LOGIN PASSWORD 'your-password' CREATEDB;
CREATE ROLE "ucs-update" LOGIN PASSWORD 'your-password' CREATEDB;

-- Create databases
CREATE DATABASE "unifi-core" OWNER "unifi-core";
CREATE DATABASE "ulp-go" OWNER "ulp-go";
CREATE DATABASE "uid" OWNER "uid";
CREATE DATABASE "unifi-credential-server" OWNER "unifi-credential-server";
CREATE DATABASE "ucs-user-assets" OWNER "unifi-credential-server";
CREATE DATABASE "unifi-directory" OWNER "unifi-directory";
CREATE DATABASE "ucs-agent" OWNER "ucs-agent";
CREATE DATABASE "unifi-identity-update" OWNER "ucs-update";
```

The chart defaults to using `unifi-core` as both the role and the primary connection user. All 8 roles use the same password.

### Option A — plaintext password

```yaml
postgres:
  enabled: false

global:
  postgres:
    connection:
      host: "postgres.example.com"
      port: 5432          # default, omit if standard
      database: unifi-core
      user: unifi-core
      password: "your-password"
```

### Option B — existing K8s secret

Create your secret first:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: pg-credentials
  namespace: unifi
type: kubernetes.io/basic-auth
stringData:
  username: unifi-core
  password: "your-password"
```

Then reference it:

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

### Custom connection parameters

```yaml
global:
  postgres:
    connection:
      host: "postgres.example.com"
      port: 5433
      database: my-unifi-db    # if you used a non-default database name
      user: my-unifi-user      # if you used a non-default role name
      password: "your-password"
```

> If you change `database` or `user`, you must also update `unifi.configOverrides.services` to match the correct `dbName`/`dbUser` for each microservice, or they will connect with the wrong credentials.

---

## Umbrella chart / namespace override

When this chart is a subchart of an umbrella chart, use `global` in the parent's values — global values take precedence over chart-local values:

```yaml
# In parent chart values.yaml
global:
  postgres:
    connection:
      host: "shared-postgres.infra.svc.cluster.local"
      password: "shared-password"
```

---

## Troubleshooting

**Pod stuck in init:**
Check if the `wait-postgres` init container is blocked — it waits until the postgres host is reachable on the configured port. Verify network connectivity and that `connection.host` is correct.

**Services can't connect:**
The init container writes service configs during pod startup. Check init container logs:
```bash
kubectl logs -n unifi <pod> -c init
```
Look for errors in the `local.yaml`/`config.props` generation section.

**Wrong password in config files:**
With `existingSecret`, the init container reads `PGPASSWORD` from the referenced secret at startup. Verify the secret exists and has the correct key:
```bash
kubectl get secret -n unifi <existingSecret.name> -o jsonpath='{.data.<passwordKey>}' | base64 -d
```
