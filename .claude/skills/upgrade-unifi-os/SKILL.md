---
name: upgrade-unifi-os
description: Check for and perform a UniFi OS Server upgrade in this repo: `make upgrade-check` / `make upgrade` find the latest release, bump uos-version.env + the chart, diff upstream, build and verify the image and write file-dumps/upgrade/report.{json,md}; then fix what the report flags. Use when asked to upgrade/bump UniFi OS, check for a new UniFi OS Server version, or when a new release is mentioned.
---

# Upgrading UniFi OS Server

The pin lives in **`uos-version.env`** (version, per-arch installer URLs +
sha256), read by the Makefile and `publish-image.yml`. `Chart.yaml`
`appVersion` carries the same version; `image.tag` defaults to it. Never
hand-edit installer URLs anywhere else.

## 1. Check and run

Targets, exit codes, report keys and the `needs_review` rules: `CLAUDE.md` (Upgrade contract).

```bash
make upgrade-check     # update available? -> file-dumps/upgrade/check.json
make upgrade           # bump, diff upstream, build/test/schema-check -> report
make upgrade-verify    # after fixing things: re-run the checks, rewrite the report
```

Use a long timeout (600000 ms): it downloads and extracts both installers (~780 MB each) and builds
the image.

Ubiquiti's hosts (`fw-update.ubnt.com`, `fw-download.ubnt.com`, `download.svc.ui.com`,
`community.ui.com`) are blocked in default cloud sandboxes: allow them, or save the response on a
machine with access and run `FROM_FILE=fw-update.json make upgrade-check` / `make upgrade`:

```bash
curl -s 'https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-os-server&filter=eq~~channel~~release' > fw-update.json
```

Release lookup (`scripts/uos-latest.sh --json` prints it):
- Primary, with sha256 + size: the URL above → `._embedded.firmware[]`: `version` (`v5.1.42`),
  `platform` (`linux-x64`, `linux-arm64`), `sha256_checksum`, `file_size`, `_links.data.href`.
- Fallback, no checksums: `https://download.svc.ui.com/v1/software-downloads` (Linux entries have
  `platform: null`; match on `filename`).
- Release notes: `https://community.ui.com/releases/r/uosserver/<version>` is JavaScript-rendered
  (`WebFetch` gets a loading shell). Give the user the link and say the notes are unread, or ask them
  to paste the text. The package diff in `report.md` is the reliable signal.

## 2. Read the report

`file-dumps/upgrade/report.json` (machine) and `report.md` (PR body). Resolve every `needs_review`
reason. Never invent an installer pin for an arch upstream hasn't published: the PR waits, or ships
without that arch on purpose. An empty list with `verified: true` makes the upgrade the version files
and changelog (5.1.40 → 5.1.42 was like this). The raw diff is `file-dumps/upgrade/diff/upstream.diff`,
with `old/` and `new/` snapshots beside it.

Check the diff against every edit in `image/patch.sh` and every file in `image/rootfs/`:

| Snapshot | Look for |
|---|---|
| `units.txt`, `unit-files.txt`, `unit-links.txt` | renamed/new units (stubs and drop-ins in `image/rootfs/etc/systemd/system` target exact names: `postgresql@14-main`, `rabbitmq-server`, `epmd`, `uos-agent`, `uos-discovery-client`, `mongodb`); new `ExecStartPre` hooks; new `Requires=` on stubbed units |
| `config-files.txt` | `/etc/default/unifi-core*` (host.docker.internal), `nginx.conf` log lines, `/usr/lib/*` marker files now shipped upstream |
| `oci-process.json` | entrypoint args/env (`/entrypoint.sh` is generated from it) |
| `postgresql-majors.txt`, `packages.txt` | PostgreSQL majors (patch.sh drops 16, keeps the 14 client), mongodb/node/nginx bumps |
| `usr-lib.txt`, `binaries.txt` | moved/removed binaries (`timedatectl`, `mongo`, `rabbitmq*`) |

New services may need a row in `SERVICES.md`.

## 3. Fix, then re-verify

`PATCH TARGET MISSING: <what>`: upstream moved that target. `PATCH POSTCONDITION FAILED: <what>`: an
edit no longer does its job. Find where the target went (upstream diff, or inspect the image from
`make build PATCH_STRICT=false`), then update the edit, its `need()` and its `ensure()` together.
`PATCH_STRICT=false` is never the fix.

```bash
make upgrade-verify                # rewrites report.{json,md} and the changelog entry
make build-all                     # optional: amd64 + arm64 (x86 needs qemu-user-static; slow)
```

## 4. Runtime test

Deploy to a test namespace (`helm upgrade --install ... --set image.tag=<version>` with the user's
`values.env.yaml`) and follow `kubectl logs -f statefulset/monolith -c journalctl` until the readiness
probe (HTTPS `/` on 443) passes. Match failures against the table below. Fix each in `image/patch.sh`
(behind `need()`, with a why-comment, plus an `ensure()` that makes `make build` fail without it) or as
a file in `image/rootfs/`, and add a row here.

`make upgrade` builds linux/amd64 only; `make build PLATFORMS=linux/arm64` builds arm64 (qemu on x86).
arm64 can't be boot-tested without an arm64 node: report it as "built, not boot-verified" unless the
user confirms.

### Known failure signatures

| Log signature | Since | Cause / fix |
|---|---|---|
| `Unsupported console model: ""` (unifi-core aborts) | 5.1.40 | `/usr/lib/app_model` + `product_name` missing from the extracted image → `image/rootfs/usr/lib/` |
| `FileNotOpen: Failed to open /var/log/mongodb/mongodb.log`; `IllegalOperation: Attempted to create a lock file on a read-only directory` | 5.1.21 | volumes shadow `/var/log` and `/var/lib/mongodb` (root-owned) → `mongodb.service.d/log-dir.conf` ExecStartPre mkdir/chown |
| `open() /dev/stderr failed (6: No such device or address)` (nginx down) | 5.1.21 | nginx stdio is a journald socket, and unifi-core's pre-start copies `nginx.conf.disabled` over `nginx.conf` → leave `nginx.conf.disabled` unpatched; only the global `error_log` goes to stderr |
| Login/auth blocked, `timedatectl` reports `NTPSynchronized=no` | — | no timesyncd in the image → `timedatectl` wrapper |
| Journal flooded by `Stub package` restarts | — | stub `uos-agent`/`uos-discovery-client` → `Restart=no` drop-ins |
| unifi-core can't reach discovery on `host.docker.internal` | — | sed to `localhost` in `/etc/default/unifi-core_advanced` |
| "Login Unavailable", `trailing junk after parameter` | PG 15+ | ulp-go SQL; PostgreSQL 14 is a ceiling (DATABASE.md) |

## 5. Finish

- Commit locally, don't push: pushing to `main` publishes.
- One commit, `Upgrade to unifi-os X.Y.Z`: version files, `CHANGELOG.md`, and any image/, SERVICES.md
  or skill-table changes.
- Merging to `main` publishes the image (amd64, plus arm64 when its URL is pinned) and releases the
  chart. Agent tokens usually can't push `.github/workflows/*`; hand workflow edits to the user.
- In the summary, say what was verified (lint / build with its patch assertions / runtime) and what
  wasn't.
