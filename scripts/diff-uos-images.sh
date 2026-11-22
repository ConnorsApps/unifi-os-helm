#!/usr/bin/env bash
# Diff two upstream UniFi OS Server releases before patching, to spot changes
# that break image/patch.sh (renamed units, moved configs, new PostgreSQL
# major, changed entrypoint/env). Builds the Dockerfile's `snapshot-out` stage
# (image/snapshot.sh on the raw `extractor` rootfs) for each installer, which
# snapshots the parts of the rootfs this repo depends on, and diffs the snapshots.
#
# Usage: scripts/diff-uos-images.sh [--old INSTALLER_URL] [--new INSTALLER_URL]
#   --old  default: installer pinned in the committed (HEAD) uos-version.env
#   --new  default: working-tree uos-version.env if it differs from HEAD (i.e.
#          after bump-uos-version.sh), else the latest release
#   A URL that a pin names builds with that pin's installer args, sha256 included.
#
# Env: CONTAINER_ENGINE (podman if installed, else docker), PLATFORM (linux/amd64),
#      OUT_DIR (file-dumps/upgrade-<old>-<new>)
# Output: $OUT_DIR/{old,new}/*.txt, $OUT_DIR/upstream.diff, summary on stdout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${CONTAINER_ENGINE:-$(command -v podman >/dev/null && echo podman || echo docker)}"
PLATFORM="${PLATFORM:-linux/amd64}"
ARCH="$(printf '%s' "${PLATFORM#*/}" | tr '[:lower:]' '[:upper:]')"  # AMD64 | ARM64

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

old_url="" new_url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --old) old_url="${2:?--old needs an installer URL}"; shift ;;
    --new) new_url="${2:?--new needs an installer URL}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

version_of() { printf '%s' "${1##*/}" | sed -nE 's#.*-([0-9]+\.[0-9]+\.[0-9]+)-.*#\1#p'; }
# kv <KEY> — read a key from KEY=value text on stdin
kv() { sed -n "s/^$1=//p"; }

pinned_head="$(git -C "$ROOT" show HEAD:uos-version.env 2>/dev/null || cat "$ROOT/uos-version.env")"
pinned_tree="$(cat "$ROOT/uos-version.env")"
latest=""

old_url="${old_url:-$(printf '%s\n' "$pinned_head" | kv "UOS_INSTALLER_URL_$ARCH")}"
if [ -z "$new_url" ]; then
  if [ "$pinned_head" != "$pinned_tree" ]; then
    new_url="$(printf '%s\n' "$pinned_tree" | kv "UOS_INSTALLER_URL_$ARCH")"
    echo "==> NEW from working-tree uos-version.env" >&2
  else
    latest="$("$ROOT/scripts/uos-latest.sh")" \
      || { echo "ERROR: latest release lookup failed; pass --new <installer-url>" >&2; exit 1; }
    new_url="$(printf '%s\n' "$latest" | kv "UOS_INSTALLER_URL_$ARCH")"
    echo "==> NEW from latest release" >&2
  fi
fi

# pin_args <url> — build args, one per line, from the known pin (HEAD, working
# tree, latest) naming url: all four installer keys, as `make build` passes them,
# so the new side's extractor stage is the build's cache, not a second download.
pin_args() {
  local src k
  for src in "$pinned_head" "$pinned_tree" "$latest"; do
    [ -n "$src" ] || continue
    if [ "$(printf '%s\n' "$src" | kv "UOS_INSTALLER_URL_$ARCH")" = "$1" ]; then
      for k in UOS_INSTALLER_URL_AMD64 UOS_INSTALLER_SHA256_AMD64 UOS_INSTALLER_URL_ARM64 UOS_INSTALLER_SHA256_ARM64; do
        printf '%s\n' --build-arg "$k=$(printf '%s\n' "$src" | kv "$k")"
      done
      return
    fi
  done
  printf '%s\n' --build-arg "UOS_INSTALLER_URL_$ARCH=$1"  # a URL no pin names: no sha256
}
[ -n "$old_url" ] && [ -n "$new_url" ] || { echo "ERROR: missing installer URL(s)" >&2; exit 1; }
[ "$old_url" != "$new_url" ] || { echo "ERROR: old and new installer are the same ($old_url)" >&2; exit 1; }

old_ver="$(version_of "$old_url")"; old_ver="${old_ver:-old}"
new_ver="$(version_of "$new_url")"; new_ver="${new_ver:-new}"
OUT_DIR="${OUT_DIR:-$ROOT/file-dumps/upgrade-$old_ver-$new_ver}"
mkdir -p "$OUT_DIR"

# The snapshot script is the Dockerfile's `snapshot-out` stage (image/snapshot.sh), so
# this works on engines without `run` (docker/buildx against a remote buildkitd).
snapshot() { # <side> <url>
  local side="$1" url="$2" args=() a
  while IFS= read -r a; do args+=("$a"); done < <(pin_args "$url")
  echo "==> [$side] snapshotting the upstream rootfs of $url" >&2
  rm -rf "${OUT_DIR:?}/$side"; mkdir -p "$OUT_DIR/$side"
  "$ENGINE" build "$ROOT" --target snapshot-out --platform "$PLATFORM" "${args[@]}" \
    --output "type=local,dest=$OUT_DIR/$side" >&2
}

snapshot old "$old_url"
snapshot new "$new_url"

diff -ru "$OUT_DIR/old" "$OUT_DIR/new" > "$OUT_DIR/upstream.diff" || true

echo
echo "UniFi OS upstream diff: $old_ver -> $new_ver"
echo "Full diff: $OUT_DIR/upstream.diff"
echo
for f in units.txt unit-files.txt unit-links.txt config-files.txt oci-process.json postgresql-majors.txt usr-lib.txt binaries.txt packages.txt; do
  if cmp -s "$OUT_DIR/old/$f" "$OUT_DIR/new/$f"; then
    printf '  %-22s unchanged\n' "$f"
  else
    printf '  %-22s CHANGED (+%s/-%s lines)\n' "$f" \
      "$(diff "$OUT_DIR/old/$f" "$OUT_DIR/new/$f" | grep -c '^>' || true)" \
      "$(diff "$OUT_DIR/old/$f" "$OUT_DIR/new/$f" | grep -c '^<' || true)"
  fi
done
echo
echo "Package version changes:"
diff "$OUT_DIR/old/packages.txt" "$OUT_DIR/new/packages.txt" | sed -n 's/^[<>] /  &/p' || true
