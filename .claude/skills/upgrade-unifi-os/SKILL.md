---
name: upgrade-unifi-os
description: Check for and perform a UniFi OS Server upgrade in this repo — `make upgrade-check` / `make upgrade` find the latest release, bump uos-version.env + the chart, diff upstream changes, build and verify the image, and write file-dumps/upgrade/report.{json,md}; then fix what the report flags. Use when asked to upgrade/bump UniFi OS, check for a new UniFi OS Server version, or when a new release is mentioned.
---

# Upgrading UniFi OS Server

The pin lives in **`uos-version.env`** (version, per-arch installer URLs +
sha256), read by the Makefile and `publish-image.yml`. `Chart.yaml`
`appVersion` carries the same version; `image.tag` defaults to it. Never
hand-edit installer URLs anywhere else.

## 1. Check and run

```bash
make upgrade-check     # writes file-dumps/upgrade/check.json {update, from, to, title}; exit 0 whenever it was written
make upgrade           # bump + helm deps + upstream snapshot diff + build/test/schema-check -> report.json, report.md, CHANGELOG.md
make upgrade-verify    # after fixing things: re-run build/test/schema-check and rewrite the report
```

`make upgrade` and `make upgrade-verify` exit 0 only when every check passed
(`verified`), and write the report either way; no report means the run itself
failed (no update, lookup or bump error). A console `repo-upgrade` workflow runs
exactly this contract (`upgrade-check`, `upgrade`, fix what `needs_review`
lists, `upgrade-verify`) and opens a draft PR with `report.md` as its body, so
what you do here is what that workflow's agent step does. The whole contract
(keys, `needs_review` rule, public-safe `report.md`) is in `CLAUDE.md`.

Run it with a long timeout (600000 ms): it downloads and extracts both
installers (~780 MB each) and builds the image, several minutes in all.

- Without podman (buildx-only environments, no `docker run`) the Makefile uses
  docker: every image inspection is a Dockerfile stage, so nothing needs `run`.
  Without `--load` the built image stays in the build cache.
- Ubiquiti's hosts are blocked in default cloud sandboxes
  (`fw-update.ubnt.com`, `fw-download.ubnt.com`, `download.svc.ui.com`,
  `community.ui.com`): allow them, or save the response on a machine with access
  (`curl -s 'https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-os-server&filter=eq~~channel~~release' > fw-update.json`)
  and run `FROM_FILE=fw-update.json make upgrade-check` / `make upgrade`.

Release lookup details (`scripts/uos-latest.sh --json` prints them):
- Primary, with sha256 + size: `https://fw-update.ubnt.com/api/firmware-latest?...`
  → `._embedded.firmware[]`: `version` (`v5.1.42`), `platform` (`linux-x64`, `linux-arm64`), `sha256_checksum`, `file_size`, `_links.data.href`.
- Fallback, no checksums: `https://download.svc.ui.com/v1/software-downloads` (Linux entries have `platform: null`; match on `filename`).
- Release notes: `https://community.ui.com/releases/r/uosserver/<version>`. The page is
  rendered by JavaScript: `WebFetch` returns only a loading shell, so don't spend a
  call on it. Give the user the link and say the notes are unread, or ask them to
  paste the text. The package diff in `report.md` is the reliable signal for what
  actually changed.

## 2. Read the report

`file-dumps/upgrade/report.json` (machine) and `report.md` (public PR body):
- `needs_review` empty and `verified: true`: nothing in the rootfs the patches
  depend on changed (5.1.40 → 5.1.42 was like this); the upgrade is the version
  files + changelog.
- Otherwise each `needs_review` reason is yours to resolve: a changed snapshot
  (other than `packages.txt`; review it, it stays listed), an old-version
  reference left in the tree, a failed check, or an installer pin the bump lost
  or has no sha256 for (upstream hasn't published that arch yet: never invent a
  pin; the PR waits or ships without that arch on purpose). The raw diff is `diff` (`file-dumps/upgrade/diff/upstream.diff`,
  with `old/` and `new/` snapshots beside it).

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

`PATCH TARGET MISSING: <what>` means upstream moved that target;
`PATCH POSTCONDITION FAILED: <what>` means an edit no longer does its job.
Find where the target went (upstream diff, or `make build PATCH_STRICT=false`
and inspect the image), then update the edit, its `need()` guard and its
`ensure()` postcondition together. `PATCH_STRICT=false` is never the fix.

`image/patch.sh` asserts every postcondition (each edit's `ensure()`, every file
in `image/rootfs/`, version and platform markers, the entrypoint), so a passing
`make build` means the image is verified, in CI too. Then:

```bash
make upgrade-verify                # build + test + schema-check, rewrites report.{json,md} and the changelog entry
make build-all                     # optional: amd64 + arm64 manifest (x86 needs qemu-user-static; slow)
```

## 4. Runtime test

Deploy to a test namespace (`helm upgrade --install ... --set image.tag=<version>`
with the user's `values.env.yaml`) and follow `kubectl logs -f statefulset/monolith -c journalctl`
until the readiness probe (HTTPS `/` on 443) passes. Match failures against the
table below. Fix each in `image/patch.sh` (guarded by `need()`, with a comment
saying why) or as a file in `image/rootfs/`, add an `ensure()` postcondition next to it
(`make build` must fail without it), and add a row here.

`make upgrade` builds linux/amd64 only; `make build PLATFORMS=linux/arm64`
builds arm64 (qemu on x86). arm64 images can't be boot-tested without an arm64
node: report them as "built, not boot-verified" unless the user confirms.

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

- Commit locally but don't push: pushing to `main` publishes, so leave that to the user.
- One commit: `Upgrade to unifi-os X.Y.Z` (version files, `CHANGELOG.md`, plus any image/, SERVICES.md or skill-table changes).
- Merging to `main` publishes the image (amd64, plus arm64 when its URL is pinned) and releases the chart.
  Agent tokens usually can't push `.github/workflows/*`; hand workflow edits to the user.
- In the summary, say what was verified (lint / build with its patch assertions / runtime) and what wasn't.
