---
name: upgrade-unifi-os
description: Check for and perform a UniFi OS Server upgrade in this repo — find the latest release (version, installer URLs, sha256, release notes) from Ubiquiti, bump uos-version.env + the chart, diff upstream changes, fix Dockerfile patches, build and verify the image. Use when asked to upgrade/bump UniFi OS, check for a new UniFi OS Server version, or when a new release is mentioned.
---

# Upgrading UniFi OS Server

The pinned release lives in **`uos-version.env`** (version, per-arch installer URLs + sha256). The Makefile and `.github/workflows/publish-image.yml` read it; `Chart.yaml` `appVersion`/`version` and `values.yaml` `image.tag` carry the same version. Never hand-edit installer URLs anywhere else.

## 1. Discover

```bash
scripts/uos-latest.sh --check     # exit 10 = update available, 0 = up to date
scripts/uos-latest.sh --json      # version, released, release_notes_url, assets[{platform,url,sha256,size}]
```

Sources (unauthenticated JSON, what ui.com/download uses):
- Primary — firmware API, has sha256 + size:
  `https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-os-server&filter=eq~~channel~~release`
  → `._embedded.firmware[]` with `version` (`v5.1.42`), `platform` (`linux-x64`, `linux-arm64`, macOS/windows ignored), `sha256_checksum`, `file_size`, `_links.data.href` (installer URL).
- Fallback — `https://download.svc.ui.com/v1/software-downloads` (no checksums; Linux entries have `platform: null`, match on `filename`).
- Release notes: `https://community.ui.com/releases/r/uosserver/<version>`.

**If the sandbox blocks these hosts** (claude.ai cloud sessions do by default): ask the user either to allow `fw-update.ubnt.com`, `fw-download.ubnt.com`, `download.svc.ui.com` and `community.ui.com` in the environment's network settings, or to run this and paste/save the output:

```bash
curl -s 'https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-os-server&filter=eq~~channel~~release' > fw-update.json
```

then use `--from-file fw-update.json` with both scripts. Read the release notes (or ask the user to paste them) and flag anything about container/podman changes, new services, database changes, or minimum requirements.

## 2. Bump

```bash
scripts/bump-uos-version.sh --latest            # or --from-file fw-update.json
# specific version: scripts/bump-uos-version.sh 5.1.42 --url-amd64 URL --sha256-amd64 SHA [--url-arm64 URL --sha256-arm64 SHA]
```

Exits 0 with "nothing to do" when already on the latest release. Otherwise writes `uos-version.env`, `Chart.yaml` (appVersion + patch bump of chart version; `--minor` if chart templates/values also changed), `values.yaml` `image.tag`, runs `helm lint` and the render matrix when available, and warns about any remaining references to the old version (fix real ones; historical comments are fine).

## 3. Diff upstream (needs podman/docker + network; usually the user's machine)

```bash
make diff-upstream                 # committed pin (HEAD) vs bumped working tree; or OLD=<url> NEW=<url>
```

Defaults: OLD = amd64 installer in the committed `uos-version.env`; NEW = the working-tree one after step 2 (or the latest release if nothing is bumped yet). Known URLs reuse their pinned sha256. It builds the Dockerfile's raw `extractor` stage for both installers and writes `file-dumps/upgrade-<old>-<new>/upstream.diff`. Review against every patch in the Dockerfile `patcher` stage:

| Snapshot | What to look for |
|---|---|
| `units.txt`, `unit-files.txt`, `unit-links.txt` | renamed/new services (stubs in Dockerfile target exact unit names: `postgresql@14-main`, `rabbitmq-server`, `epmd`, `uos-agent`, `uos-discovery-client`, `mongodb`); new `ExecStartPre` hooks; new `Requires=` on things we stub |
| `config-files.txt` | `/etc/default/unifi-core*` (host.docker.internal), `nginx.conf` log lines, `/usr/lib/*` marker files upstream now ships |
| `oci-process.json` | entrypoint args/env — `/entrypoint.sh` is generated from this |
| `postgresql-majors.txt`, `packages.txt` | PostgreSQL major change (Dockerfile removes 16, keeps 14 client), mongodb/node/nginx bumps |
| `usr-lib.txt`, `binaries.txt` | moved/removed binaries (`timedatectl`, `mongo`, `rabbitmq*`) |

New services may also need `SERVICES.md` updates.

## 4. Build and verify

```bash
make build                         # amd64 (PLATFORMS=linux/arm64 for arm64)
make verify-image                  # static checks: patched files present, stripped parts gone
make build-all                     # optional: amd64 + arm64 manifest (x86 host needs qemu-user-static; slow)
make verify-image TAG=<version>-arm64 PLATFORM=linux/arm64
```

Every Dockerfile patch is guarded by `patch-target`; a build failure reading `PATCH TARGET MISSING: <what>` means upstream moved that target. Find where it went (upstream diff, or `make build PATCH_STRICT=false` then inspect the image), update the patch and its `patch-target` guard together. Never leave `PATCH_STRICT=false` as the fix.

## 5. Runtime test

Deploy to a test namespace (`helm upgrade --install ... --set image.tag=<version>` with the user's `values.env.yaml`), then watch `kubectl logs -f statefulset/monolith -c journalctl` until the readiness probe (HTTPS `/` on 443) passes. Match failures against the table below; fix each with a Dockerfile patch that has a comment explaining *why* (symptom, version, verification) like the existing ones, guarded by `patch-target`, and add a `verify-image.sh` check for it. Then append a row here.

arm64 images can't be boot-tested without an arm64 node — report them as "built, not boot-verified" unless the user confirms.

### Known failure signatures

| Log signature | Since | Cause / fix in Dockerfile |
|---|---|---|
| `Unsupported console model: ""` (unifi-core aborts) | 5.1.40 | `/usr/lib/app_model` + `/usr/lib/product_name` missing from extracted image → written at build |
| `FileNotOpen: Failed to open /var/log/mongodb/mongodb.log`; `IllegalOperation: Attempted to create a lock file on a read-only directory` | 5.1.21 | volumes shadow `/var/log`, `/var/lib/mongodb` → `mongodb.service.d/log-dir.conf` ExecStartPre mkdir/chown |
| `open() /dev/stderr failed (6: No such device or address)` (nginx down) | 5.1.21 | nginx stdio is a journald socket → leave `nginx.conf.disabled` unpatched |
| Login/auth blocked, `timedatectl` reports `NTPSynchronized=no` | — | no timesyncd in image → `timedatectl` wrapper |
| Journal flooded by `Stub package` restarts | — | stub `uos-agent`/`uos-discovery-client` → `Restart=no` drop-ins |
| unifi-core can't reach discovery on `host.docker.internal` | — | sed to `localhost` in `/etc/default/unifi-core_advanced` |

## 6. Finish

- One commit: `Upgrade to unifi-os X.Y.Z` (version files + any Dockerfile/SERVICES.md/skill-table changes).
- Merging to `main` publishes the image and releases the chart. `publish-image.yml` reads `uos-version.env` and builds amd64 + arm64 **only if its workflow update has landed** — check for `. ./uos-version.env` in it. If it still has hardcoded `DEFAULT_IMAGE_TAG`/`DEFAULT_UOS_INSTALLER_URL` (bump-uos-version.sh flags them as stale), update those too; agents' tokens usually can't push workflow files, so hand that edit to the user.
- In the summary, state what was verified (lint / build / verify-image / runtime) and what wasn't.
