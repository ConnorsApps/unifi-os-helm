---
name: upgrade-unifi-os
description: Check for and perform a UniFi OS Server upgrade in this repo — find the latest release (version, installer URLs, sha256, release notes) from Ubiquiti, bump uos-version.env + the chart, diff upstream changes, fix image patches, build and verify the image. Use when asked to upgrade/bump UniFi OS, check for a new UniFi OS Server version, or when a new release is mentioned.
---

# Upgrading UniFi OS Server

The pin lives in **`uos-version.env`** (version, per-arch installer URLs +
sha256), read by the Makefile and `publish-image.yml`. `Chart.yaml`
`appVersion` carries the same version; `image.tag` defaults to it. Never
hand-edit installer URLs anywhere else.

## 1. Discover

```bash
scripts/uos-latest.sh --check     # exit 10 = update available, 0 = up to date
scripts/uos-latest.sh --json      # version, released, release_notes_url, assets[{platform,url,sha256,size}]
```

Sources (unauthenticated JSON that ui.com uses):
- Primary, with sha256 + size: `https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-os-server&filter=eq~~channel~~release`
  → `._embedded.firmware[]`: `version` (`v5.1.42`), `platform` (`linux-x64`, `linux-arm64`), `sha256_checksum`, `file_size`, `_links.data.href`.
- Fallback, no checksums: `https://download.svc.ui.com/v1/software-downloads` (Linux entries have `platform: null`; match on `filename`).
- Release notes: `https://community.ui.com/releases/r/uosserver/<version>`.

**Blocked hosts** (claude.ai cloud sandboxes by default): ask the user to allow
`fw-update.ubnt.com`, `fw-download.ubnt.com`, `download.svc.ui.com` and
`community.ui.com`, or to run this and share the file:

```bash
curl -s 'https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-os-server&filter=eq~~channel~~release' > fw-update.json
```

then pass `--from-file fw-update.json` to both scripts. Read the release notes
(or ask for them) and flag container/podman changes, new services, database
changes and new requirements.

The community.ui.com release page is rendered by JavaScript: `WebFetch` returns
only a loading shell, so don't spend a call on it. Give the user the link and
say the notes are unread, or ask them to paste the text. The `make diff-upstream`
package diff (step 3) is the reliable signal for what actually changed.

## 2. Bump

```bash
scripts/bump-uos-version.sh --latest       # or --from-file fw-update.json
# specific version: scripts/bump-uos-version.sh 5.1.42 --url-amd64 URL --sha256-amd64 SHA [--url-arm64 URL --sha256-arm64 SHA]
```

Exits 0 ("nothing to do") when already current. Otherwise it writes
`uos-version.env` and `Chart.yaml` (appVersion + chart patch bump; `--minor`
when templates/values changed too), runs `helm lint` and the render matrix when
the subcharts are present, and lists leftover references to the old version
(fix real ones; historical comments are fine).

## 3. Diff upstream (needs podman/docker + network; usually the user's machine)

```bash
make diff-upstream                 # committed pin (HEAD) vs bumped working tree; or OLD=<url> NEW=<url>
```

Downloads and extracts both installers (~780 MB each), so run it with a long
timeout (600000 ms) and expect several minutes. It ends with a per-snapshot
summary: when everything but `packages.txt` says `unchanged`, no patch or rootfs
edits are needed (5.1.40 → 5.1.42 was like this). Builds the raw `extractor` stage for both installers and writes
`file-dumps/upgrade-<old>-<new>/upstream.diff`. Check it against every edit in
`image/patch.sh` and every file in `image/rootfs/`:

| Snapshot | Look for |
|---|---|
| `units.txt`, `unit-files.txt`, `unit-links.txt` | renamed/new units (stubs and drop-ins in `image/rootfs/etc/systemd/system` target exact names: `postgresql@14-main`, `rabbitmq-server`, `epmd`, `uos-agent`, `uos-discovery-client`, `mongodb`); new `ExecStartPre` hooks; new `Requires=` on stubbed units |
| `config-files.txt` | `/etc/default/unifi-core*` (host.docker.internal), `nginx.conf` log lines, `/usr/lib/*` marker files now shipped upstream |
| `oci-process.json` | entrypoint args/env (`/entrypoint.sh` is generated from it) |
| `postgresql-majors.txt`, `packages.txt` | PostgreSQL majors (patch.sh drops 16, keeps the 14 client), mongodb/node/nginx bumps |
| `usr-lib.txt`, `binaries.txt` | moved/removed binaries (`timedatectl`, `mongo`, `rabbitmq*`) |

New services may need a row in `SERVICES.md`.

## 4. Build and verify

```bash
make build                         # amd64 (PLATFORMS=linux/arm64 TAG=<v>-arm64 for arm64)
make verify-image                  # every image/rootfs file present, every patch applied
make build-all                     # optional: amd64 + arm64 manifest (x86 needs qemu-user-static; slow)
make verify-image TAG=<version>-arm64 PLATFORM=linux/arm64
```

`PATCH TARGET MISSING: <what>` means upstream moved that target. Find where it
went (upstream diff, or `make build PATCH_STRICT=false` and inspect the image),
then update the edit and its `need()` guard together. `PATCH_STRICT=false` is
never the fix.

## 5. Runtime test

Deploy to a test namespace (`helm upgrade --install ... --set image.tag=<version>`
with the user's `values.env.yaml`) and follow `kubectl logs -f statefulset/monolith -c journalctl`
until the readiness probe (HTTPS `/` on 443) passes. Match failures against the
table below. Fix each in `image/patch.sh` (guarded by `need()`, with a comment
saying why) or as a file in `image/rootfs/`, make sure `scripts/verify-image.sh`
covers it, and add a row here.

arm64 images can't be boot-tested without an arm64 node: report them as
"built, not boot-verified" unless the user confirms.

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

## 6. Finish

- Commit locally but don't push: pushing to `main` publishes, so leave that to the user.
- One commit: `Upgrade to unifi-os X.Y.Z` (version files plus any image/, SERVICES.md or skill-table changes).
- Merging to `main` publishes the image (amd64, plus arm64 when its URL is pinned) and releases the chart.
  Agent tokens usually can't push `.github/workflows/*`; hand workflow edits to the user.
- In the summary, say what was verified (lint / build / verify-image / runtime) and what wasn't.
