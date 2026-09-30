# CLAUDE.md

Helm chart for Ubiquiti's UniFi OS Server. The image is extracted from
Ubiquiti's self-extracting installer and patched for Kubernetes; upstream
systemd runs ~15 services in one privileged container. PostgreSQL (CloudNativePG)
and RabbitMQ (CloudPirates) are optional subcharts or external; MongoDB is
embedded (UniFi hardcodes it).

## Commands

```bash
make help                  # all targets
make build                 # podman; installer URL + sha256 from uos-version.env
make build PLATFORMS=linux/arm64 TAG=<v>-arm64   # or make build-all (amd64 + arm64 manifest)
make verify-image          # static checks on the built image
make test                  # helm lint + render tests/values/* (needs subcharts: helm dependency update)
scripts/render-matrix.sh <out-dir> [chart-dir]    # render the matrix; diff two runs structurally
```

Upgrading UniFi OS: use the `upgrade-unifi-os` skill (`make check-update`, `make bump`,
`make diff-upstream`). Ubiquiti's hosts are blocked in default cloud sandboxes;
the scripts accept `--from-file` with a saved API response.

## Layout

| Path | What |
|---|---|
| `uos-version.env` | Pinned version + per-arch installer URLs/sha256 (Makefile, publish workflow, scripts) |
| `Dockerfile` | `extractor` stage (`image/extract.sh`: raw upstream rootfs in /bundle) → `patcher` (`image/patch.sh`) → scratch |
| `image/patch.sh` | Edits to upstream files, each guarded by `need()`; `PATCH_STRICT=false` warns instead of failing |
| `image/rootfs/` | Files copied over the rootfs: stub units, drop-ins, psql wrapper, timedatectl wrapper, marker files |
| `charts/unifi-os/templates/` | One file per resource group; `_helpers.tpl` holds labels, metadata, podSpec, connection resolution, port table |
| `charts/unifi-os/files/` | init/start scripts and the discovery shim, inlined via `.Files.Get` |
| `tests/values/` | Render scenarios, each merged over `00-base.yaml` |
| `scripts/` | Upgrade automation, `verify-image.sh`, `render-matrix.sh`, `extract-container-configs.sh` |

## Invariants

- **Object names are hardcoded literals** (`monolith`, `unifi`, `hotspot`, `udp`,
  secrets, config maps, routes), never a fullname helper. Renaming orphans PVCs
  and breaks upgrades.
- **StatefulSet `volumeClaimTemplates` and all selectors are immutable.** Keep
  their names, order and fields byte-identical, including `storageClassName: ""`.
- **Values stay backwards compatible**: add keys, don't rename or remove them.
- **PostgreSQL 14 is a ceiling** (ulp-go SQL breaks on 15+; see DATABASE.md).
- Every patch to an upstream file stays behind `need()`, so an upstream change
  fails the build instead of silently skipping the patch.
- Before and after template changes, render `tests/values` and diff the output
  structurally (kind + name + spec); explain every difference.
