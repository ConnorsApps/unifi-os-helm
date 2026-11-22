# CLAUDE.md

Helm chart for Ubiquiti's UniFi OS Server. The image is extracted from
Ubiquiti's self-extracting installer and patched for Kubernetes; upstream
systemd runs ~15 services in one privileged container. PostgreSQL (CloudNativePG)
and RabbitMQ (CloudPirates) are optional subcharts or external; MongoDB is
embedded (UniFi hardcodes it).

## Commands

```bash
make help                  # all targets
make build                 # podman (CONTAINER_ENGINE=docker for buildx); installer URL + sha256 from uos-version.env; patch.sh asserts the result
make build PLATFORMS=linux/arm64 TAG=<v>-arm64   # or make build-all (amd64 + arm64 manifest)
make test                  # helm lint + render tests/values/* (needs subcharts: helm dependency update)
make schema                # regenerate charts/unifi-os/values.schema.json from cmd/schema-gen
make schema-check          # generator tests + fail if the committed schema is stale
scripts/render-matrix.sh <out-dir> [chart-dir]    # render the matrix; diff two runs structurally
```

Upgrading UniFi OS: use the `upgrade-unifi-os` skill (`make check-update`, `make bump`,
`make diff-upstream`). Ubiquiti's hosts are blocked in default cloud sandboxes;
the scripts accept `--from-file` with a saved API response.

## Layout

| Path | What |
|---|---|
| `uos-version.env` | Pinned version + per-arch installer URLs/sha256 (Makefile, publish workflow, scripts) |
| `Dockerfile` | `extractor` stage (`image/extract.sh`: raw upstream rootfs in /bundle) → `snapshot`/`snapshot-out` (`image/snapshot.sh`: text snapshots for the upstream diff) → `patcher` (`image/patch.sh`) → scratch. Only the last stage is the default target, so `snapshot-out` never lands in the published image |
| `image/patch.sh` | Edits to upstream files: `need()` checks each precondition, `ensure()` its postcondition, plus final asserts (every `image/rootfs` file, version/platform markers, entrypoint); `PATCH_STRICT=false` warns instead of failing |
| `image/rootfs/` | Files copied over the rootfs: stub units, drop-ins, psql wrapper, timedatectl wrapper, marker files |
| `charts/unifi-os/templates/` | One file per resource group; `_helpers.tpl` holds labels, metadata, podSpec, connection resolution, port table |
| `charts/unifi-os/files/` | init/start scripts and the discovery shim, inlined via `.Files.Get` |
| `tests/values/` | Render scenarios, each merged over `00-base.yaml` |
| `cmd/schema-gen/` | Own Go module: hand-mirrored value types → `charts/unifi-os/values.schema.json` (subchart schemas read from the vendored `charts/*.tgz`) |
| `scripts/` | Upgrade automation, `render-matrix.sh`, `extract-container-configs.sh` |
| `.dockerignore` | Build context is `Dockerfile` + `image/` only |

## Invariants

- **Object names are hardcoded literals** (`monolith`, `unifi`, `hotspot`, `udp`,
  secrets, config maps, routes), never a fullname helper. Renaming orphans PVCs
  and breaks upgrades.
- **StatefulSet `volumeClaimTemplates` and all selectors are immutable.** Keep
  their names, order and fields byte-identical, including `storageClassName: ""`.
- **Values stay backwards compatible**: add keys, don't rename or remove them.
- **PostgreSQL 14 is a ceiling** (ulp-go SQL breaks on 15+; see DATABASE.md).
- **The values schema is closed.** Add a key to `values.yaml` and to the matching `cmd/schema-gen/*.go` file, then `make schema`;
  otherwise `helm lint` rejects it. `make schema-check` must pass.
- `values.yaml`, `values.env.example.yaml` and the README values example start with a
  `# yaml-language-server: $schema=` comment pointing at the raw `values.schema.json` on `main`.
- Every patch to an upstream file stays behind `need()` (precondition) and is followed by an
  `ensure()` (postcondition), so an upstream change fails the build instead of silently skipping
  or half-applying the patch. `make build` passing means the image is verified, in CI too
  (`publish-image.yml` builds the default target); there is no separate verify step.
- Before and after template changes, render `tests/values` and diff the output
  structurally (kind + name + spec); explain every difference.
