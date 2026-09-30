# UniFi OS services

The systemd units inside the `unifi-os` container, and how this chart runs them.
PostgreSQL and RabbitMQ are external (subcharts or your own); MongoDB is embedded.

| Unit | What it is | Depends on | In this chart |
|---|---|---|---|
| `unifi-core` | Node.js platform API; coordinates and proxies the other services | PostgreSQL, `nginx`, `ulp-go`; talks to `uid-agent` (6080), `unifi` (8080/8081), `uos-agent` (11010/11011), discovery (11002) | Runs |
| `unifi` | Java Network application: devices, adoption | `unifi-core`, MongoDB, RabbitMQ (`RABBITMQ_URI`) | Runs |
| `ulp-go` | Users/identity platform (ULP); owns `/run/ulp-go/jsonrpc.sock` used by the identity services | PostgreSQL; talks to `unifi-core` (11081), `ucs-agent` (9680), `unifi-directory` (13080) | Runs; needs PostgreSQL ≤ 14 (see DATABASE.md) |
| `unifi-credential-server` | Credential/SSO backend | PostgreSQL, `ulp-go` socket; wants `unifi-directory` | Runs |
| `unifi-directory` | Directory (identity/org structure) | PostgreSQL, `ulp-go` socket | Runs |
| `ucs-agent` | Credential-server agent and proxy | PostgreSQL, `ulp-go` socket | Runs |
| `uid-agent` | UID identity and guest portal | PostgreSQL, `ulp-go` socket; after `unifi-core` | Runs |
| `unifi-identity-update` | Identity package updates | PostgreSQL; wants `ulp-go` | Runs |
| `nginx` | Reverse proxy and TLS on 443 | `unifi-core` writes its upstream/site config | Runs; certificate per TLS.md |
| `mongodb` | Network application database | — | Runs embedded; drop-in creates/chowns its log and data dirs |
| `uos-agent` | Host agent (hardware/platform) | — | Stub binary upstream: `Restart=no` drop-in; `unifi-core` logs "No connection to UOS Server Manager" (harmless) |
| `uos-discovery-client` | Discovery helper; HTTP on 11002 for `unifi-core` | — | Stub binary upstream, disabled; the `discovery-shim` sidecar serves 11002 instead |
| `postgresql`, `postgresql@14-main` | Embedded database | — | Stubbed; external. `psql`/`createdb`/… wrappers target `PGHOST` |
| `rabbitmq-server`, `epmd` | Embedded message queue | — | Stubbed; external |
| `ubnt-dpkg-*` | Firmware package restore/cache | `/boot/.fwupdate` | Unused in containers |
