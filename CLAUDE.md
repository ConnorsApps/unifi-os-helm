# CLAUDE.md

Helm chart for Ubiquiti's UniFi OS Server. The image is extracted from
Ubiquiti's self-extracting installer and patched for Kubernetes; upstream
systemd runs ~15 services in one privileged container. PostgreSQL (CloudNativePG)
and RabbitMQ (CloudPirates) are optional subcharts or external; MongoDB is
embedded (UniFi hardcodes it).

## Commands

```bash
make help                  # all targets
make build                 # podman if installed, else docker + buildx (CONTAINER_ENGINE= overrides); installer URL + sha256 from uos-version.env; patch.sh asserts the result
make build PLATFORMS=linux/arm64 TAG=<v>-arm64   # or make build-all (amd64 + arm64 manifest)
make test                  # helm lint + render tests/values/* (needs subcharts: helm dependency update)
make schema                # regenerate charts/unifi-os/values.schema.json from cmd/schema-gen
make schema-check          # generator tests + fail if the committed schema is stale
make upgrade-check         # is a newer UniFi OS release out? writes file-dumps/upgrade/check.json
make upgrade               # bump, diff upstream, build/test/schema-check; writes report.json/report.md + CHANGELOG.md
make upgrade-verify        # re-run the checks after fixes; rewrites the report
scripts/render-matrix.sh <out-dir> [chart-dir]    # render the matrix; diff two runs structurally
```

Upgrading UniFi OS: use the `upgrade-unifi-os` skill (`make upgrade`). Ubiquiti's hosts are
blocked in default cloud sandboxes; `FROM_FILE=fw-update.json make upgrade-check|upgrade` takes
a saved API response.

## Upgrade contract

`scripts/upgrade.sh` owns the upgrade pipeline and its "needs human or agent review" signal. A
console `repo-upgrade` workflow runs it in a sandbox with the docker CLI + buildx and no podman and
no `docker run` (the Makefile picks docker when podman is missing), so everything that inspects an
image is a Dockerfile stage (`snapshot-out`), never a `run`. Make collapses exit codes to 2, so status lives in JSON under
`file-dumps/upgrade/` (repo-relative paths):

- `make upgrade-check` writes `check.json` = `{"update": bool, "from": "<pinned>", "to": "<latest>",
  "title": "Upgrade to unifi-os <latest>"}`. Exit 0 whenever the file was written; non-zero only on error.
- `make upgrade` = `bump-uos-version.sh --latest`, `helm dependency update` if the subcharts are missing,
  `diff-uos-images.sh` (committed pin at HEAD vs bumped tree, output in `diff/`), then `upgrade-verify`.
  Re-running on an already bumped tree is fine; with nothing to upgrade it exits non-zero and writes no report.
- `make upgrade-verify` = `make build` (always `PATCH_STRICT=true`), `make test`, `make schema-check`, then rewrites `report.json`,
  `report.md` and the `CHANGELOG.md` section. Both exit 0 iff verified (every check passed) and write the
  report either way; a missing report is an error (no update, lookup or bump failure).
- `report.json`, exactly these keys: `from`, `to`, `chart_from`, `chart_to`, `title`, `brief`
  (`.claude/skills/upgrade-unifi-os/SKILL.md`), `needs_review` (strings), `verified` (bool),
  `checks` (`[{name, ok}]`: build, test, schema-check), `report_md` (`file-dumps/upgrade/report.md`),
  `diff` (`file-dumps/upgrade/diff/upstream.diff`; `""` if the snapshot diff failed, which also adds a
  `needs_review` reason).
- `needs_review` rule (lives only in `upgrade.sh`): no snapshot comparison, any snapshot other than
  `packages.txt` CHANGED, an installer the previous pin had and the new one lacks (merging would stop
  publishing that arch) or one without a sha256, any reference to the old version left in the tree
  (`scripts/stale-refs.sh`), any failed check. Empty + `verified: true` means nothing the patches
  depend on changed. Snapshot reasons stay listed after a fix: they ask for review, not for a change.
- `make upgrade-verify` re-derives versions from HEAD vs the tree on every run, so bumping the chart's
  minor (templates changed) after `make upgrade` is picked up.
- `report.md` is posted verbatim as a public PR body: versions, chart versions, release date, the
  (unread) release-notes link, the snapshot table and package changes, check results, `needs_review`
  reasons and what is not verified (runtime boot; builds other than linux/amd64, which only the
  publish workflow builds). Nothing else: no local paths beyond repo-relative ones,
  no hostnames, no raw logs (those stay in `file-dumps/upgrade/logs/`).
- `CHANGELOG.md`: `upgrade` and `upgrade-verify` write the `## <chart version>` section at the top,
  replacing any section above HEAD's chart version (an earlier run's, maybe under another version).
  Headings are exactly `## X.Y.Z`; a parser windows by them. Don't hand-edit those sections.

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
| `scripts/` | Upgrade automation (`upgrade.sh`, `uos-latest.sh`, `bump-uos-version.sh`, `diff-uos-images.sh`, `stale-refs.sh`), `render-matrix.sh`, `extract-container-configs.sh` |
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
