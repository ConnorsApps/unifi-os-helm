# UniFi OS Services

Consolidated service reference for UniFi OS Server, focused on what each service does and what it depends on.

The chart now runs these services in a single systemd-driven container and externalizes PostgreSQL, MongoDB, and RabbitMQ via
chart dependencies or external endpoints.

## Table of contents

- [unifi-core](#unifi-core)
- [unifi](#unifi-network-application)
- [ulp-go](#ulp-go-users--ulp)
- [unifi-credential-server](#unifi-credential-server)
- [unifi-directory](#unifi-directory)
- [ucs-agent](#ucs-agent-unifi-credential-server-agent)
- [uid-agent](#uid-agent)
- [uos-agent](#uos-agent)
- [uos-discovery-client](#uos-discovery-client)
- [unifi-identity-update](#unifi-identity-update)
- [nginx](#nginx)
- [postgresql](#postgresql)
- [mongodb](#mongodb)
- [rabbitmq](#rabbitmq)
- [epmd](#epmd-erlang-port-mapper-daemon)
- [ubnt-dpkg](#ubnt-dpkg-unifi-package-restore--cache)

## unifi-core

**What it is:** Node.js API backend and central UniFi OS coordinator. Proxies to internal services and orchestrates core platform behavior.

**Dependencies:**
- Required: PostgreSQL, `nginx`, `ulp-go`
- Optional: `ubnt-dpkg-cache.service` (referenced in unit, may be absent in containers)
- Runtime links: `uid-agent` (6080), `unifi`/Network app (8080/8081), `uos-agent` (11010/11011), optional `uos-discovery-client` (11002)

## unifi (Network Application)

**What it is:** Java UniFi Network controller for device management and adoption workflows.

**Dependencies:**
- Required: `unifi-core`
- Required for data/messaging: MongoDB (`MONGO_URI`) and RabbitMQ (`RABBITMQ_URI`) when externalized

## ulp-go (Users / ULP)

**What it is:** Users/identity platform service (ULP) for account and lifecycle operations.

**Dependencies:**
- Required: PostgreSQL
- Runtime links: `unifi-core` (11081), `ucs-agent` (9680), `unifi-directory` (13080)
- Provides shared socket: `/run/ulp-go/jsonrpc.sock` for multiple identity services

## unifi-credential-server

**What it is:** Credential and identity backend for SSO/credential operations.

**Dependencies:**
- Required: PostgreSQL
- Wanted: `unifi-directory`
- Required runtime integration: `ulp-go` socket at `/run/ulp-go/jsonrpc.sock`

## unifi-directory

**What it is:** Directory service backing identity/org structure.

**Dependencies:**
- Required: PostgreSQL
- Required runtime integration: `ulp-go` socket at `/run/ulp-go/jsonrpc.sock`

## ucs-agent (UniFi Credential Server Agent)

**What it is:** Agent for credential/identity workflows and service proxying.

**Dependencies:**
- Required: PostgreSQL
- Required runtime integration: `ulp-go` socket at `/run/ulp-go/jsonrpc.sock`
- Runtime link: consumed by `ulp-go` over HTTP (9680)

## uid-agent

**What it is:** UID service agent for identity and guest portal flows.

**Dependencies:**
- Required: PostgreSQL
- Startup ordering: after `unifi-core`
- Required runtime integration: `ulp-go` socket at `/run/ulp-go/jsonrpc.sock`
- Optional runtime link: `unifi-access` (if installed)

## uos-agent

**What it is:** Low-level UniFi OS host agent (hardware/platform operations), typically root-level.

**Dependencies:**
- Required: `network.target`
- Runtime link: consumed by `unifi-core` on 11010/11011
- Status: **stub binary** in the extracted image — `/usr/bin/uos-agent` does not send the `sd_notify` READY signal required by `Type=notify`, causing it to fail immediately.  A `Restart=no` drop-in prevents the restart storm.  `unifi-core` logs recurring `No connection to UOS Server Manager` errors as a result (non-fatal; app continues).

## uos-discovery-client

**What it is:** Device discovery/adoption helper service.  Provides the HTTP `/scan` endpoint on port 11002 that `unifi-core` uses to enumerate network interfaces and resolve the LAN IP.

**Dependencies:**
- Required: `network.target`
- Ordering: before `unifi-core` when enabled
- Status: **stub binary** in the extracted image — `/usr/bin/uos-discovery-client` prints "Stub package" and exits immediately; disabled by default.  A `Restart=no` drop-in prevents the restart storm that would otherwise occur.  Port 11002 is never served; `unifi-core` logs recurring `Failed to fetch network interfaces` warnings as a result (non-fatal).

## unifi-identity-update

**What it is:** Identity package/update service.

**Dependencies:**
- Required: PostgreSQL
- Wanted: `ulp-go`
- Required runtime integration: `ulp-go` socket at `/run/ulp-go/jsonrpc.sock`

## nginx

**What it is:** Reverse proxy and TLS entrypoint for UniFi OS services.

**Dependencies:**
- Required system targets: `network-online`, `remote-fs`, `nss-lookup`
- Strong runtime coupling: `unifi-core` generates/maintains upstream and site config includes

## postgresql

**What it is:** Primary relational database for core and identity services.

**Dependencies:**
- Base infrastructure service (no app-level dependency)
- Required by: `unifi-core`, `ulp-go`, `unifi-credential-server`, `unifi-directory`, `ucs-agent`, `uid-agent`, `unifi-identity-update`

## mongodb

**What it is:** Document database used by the UniFi Network application.

**Dependencies:**
- Base infrastructure service (no app-level dependency)
- Used by: `unifi` (Network app) only

## rabbitmq

**What it is:** Message queue used by the UniFi Network application.

**Dependencies:**
- Required: `epmd`
- Used by: `unifi` (Network app) only

## epmd (Erlang Port Mapper Daemon)

**What it is:** Erlang port mapper required by RabbitMQ node runtime.

**Dependencies:**
- Required: `epmd.socket` (systemd socket activation)
- Needed only when running local/internal RabbitMQ

## ubnt-dpkg (UniFi Package Restore / Cache)

**What it is:** UniFi hardware package restore/cache helpers tied to firmware update workflows.

**Dependencies:**
- Hardware/firmware flow dependency: `/boot/.fwupdate` marker for restore path
- Not required for standard containerized deployments
