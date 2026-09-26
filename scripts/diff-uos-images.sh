#!/usr/bin/env bash
# Diff two upstream UniFi OS Server releases before patching/building, to spot
# changes that could invalidate this repo's Dockerfile patches (renamed units,
# moved config files, new PostgreSQL major, changed entrypoint/env, ...).
#
# Builds the Dockerfile's raw `extractor` stage (download + unpack, no patches)
# for each installer, dumps a text snapshot of the parts of the rootfs this
# repo patches or depends on, and diffs the snapshots.
#
# Usage:
#   scripts/diff-uos-images.sh [--old INSTALLER_URL] [--new INSTALLER_URL]
#     --old defaults to the amd64 installer pinned in the committed (HEAD)
#           uos-version.env
#     --new defaults to the working-tree uos-version.env when it differs from
#           HEAD (i.e. right after scripts/bump-uos-version.sh), otherwise to
#           the latest release (scripts/uos-latest.sh)
#   A URL matching a pinned one reuses its sha256 for download verification.
#
# Env: CONTAINER_ENGINE (default podman), PLATFORM (default linux/amd64),
#      OUT_DIR (default file-dumps/upgrade-<old>-<new>)
# Output: $OUT_DIR/{old,new}/*.txt, $OUT_DIR/upstream.diff, summary on stdout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${CONTAINER_ENGINE:-podman}"
PLATFORM="${PLATFORM:-linux/amd64}"

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

old_url="${old_url:-$(printf '%s\n' "$pinned_head" | kv UOS_INSTALLER_URL_AMD64)}"
if [ -z "$new_url" ]; then
  if [ "$pinned_head" != "$pinned_tree" ]; then
    new_url="$(printf '%s\n' "$pinned_tree" | kv UOS_INSTALLER_URL_AMD64)"
    echo "==> NEW from working-tree uos-version.env" >&2
  else
    latest="$("$ROOT/scripts/uos-latest.sh")" \
      || { echo "ERROR: latest release lookup failed; pass --new <installer-url>" >&2; exit 1; }
    new_url="$(printf '%s\n' "$latest" | kv UOS_INSTALLER_URL_AMD64)"
    echo "==> NEW from latest release" >&2
  fi
fi

# sha256_for <url> — checksum from any known pin (HEAD, working tree, latest)
sha256_for() {
  local src
  for src in "$pinned_head" "$pinned_tree" "$latest"; do
    [ -n "$src" ] || continue
    if [ "$(printf '%s\n' "$src" | kv UOS_INSTALLER_URL_AMD64)" = "$1" ]; then
      printf '%s\n' "$src" | kv UOS_INSTALLER_SHA256_AMD64; return
    fi
    if [ "$(printf '%s\n' "$src" | kv UOS_INSTALLER_URL_ARM64)" = "$1" ]; then
      printf '%s\n' "$src" | kv UOS_INSTALLER_SHA256_ARM64; return
    fi
  done
}
old_sha="$(sha256_for "$old_url")"
new_sha="$(sha256_for "$new_url")"
[ -n "$old_url" ] && [ -n "$new_url" ] || { echo "ERROR: missing installer URL(s)" >&2; exit 1; }
[ "$old_url" != "$new_url" ] || { echo "ERROR: old and new installer are the same ($old_url)" >&2; exit 1; }

old_ver="$(version_of "$old_url")"; old_ver="${old_ver:-old}"
new_ver="$(version_of "$new_url")"; new_ver="${new_ver:-new}"
OUT_DIR="${OUT_DIR:-$ROOT/file-dumps/upgrade-$old_ver-$new_ver}"
mkdir -p "$OUT_DIR"

# Runs inside the extractor image; writes text snapshots to /out.
# shellcheck disable=SC2016
DUMP='
set -eu
R=/bundle/rootfs
cd "$R"
find etc/systemd lib/systemd usr/lib/systemd \( -name "*.service" -o -name "*.target" -o -name "*.timer" -o -name "*.socket" -o -name "*.conf" \) 2>/dev/null | sort > /out/units.txt
find etc/systemd lib/systemd usr/lib/systemd -type l 2>/dev/null | sort | while read -r l; do echo "$l -> $(readlink "$l")"; done > /out/unit-links.txt
: > /out/unit-files.txt
for f in $(grep -E "(unifi|uos|ulp|ubnt|mongo|postgres|rabbit|nginx|epmd|podman|systemd-tim)" /out/units.txt); do
  [ -f "$f" ] && { echo "===== /$f"; cat "$f"; echo; } >> /out/unit-files.txt
done
: > /out/config-files.txt
for f in etc/default/unifi-core* etc/nginx/nginx.conf* usr/lib/version usr/lib/platform usr/lib/app_model usr/lib/product_name; do
  [ -f "$f" ] && { echo "===== /$f"; cat "$f"; echo; } >> /out/config-files.txt
done
ls -1 usr/lib | sort > /out/usr-lib.txt
ls -1 usr/lib/postgresql 2>/dev/null > /out/postgresql-majors.txt || : > /out/postgresql-majors.txt
find usr/bin usr/sbin usr/local/bin -maxdepth 1 ! -type d 2>/dev/null | sort > /out/binaries.txt
awk "/^Package: /{p=\$2} /^Version: /{print p\" \"\$2}" var/lib/dpkg/status | sort > /out/packages.txt
jq "{args: .process.args, env: .process.env, cwd: .process.cwd, user: .process.user}" /bundle/config.json > /out/oci-process.json
'

snapshot() { # <side> <url> <sha>
  local side="$1" url="$2" sha="$3" tag="localhost/uos-extract:$4"
  echo "==> [$side] building extractor stage for $url" >&2
  "$ENGINE" build "$ROOT" --target extractor --platform "$PLATFORM" \
    --build-arg "UOS_INSTALLER_URL=$url" --build-arg "UOS_INSTALLER_SHA256=$sha" \
    --tag "$tag" >&2
  rm -rf "${OUT_DIR:?}/$side"; mkdir -p "$OUT_DIR/$side"
  local mount="$OUT_DIR/$side:/out"
  [ "$ENGINE" = podman ] && mount="$mount:Z"  # SELinux relabel; no-op elsewhere
  "$ENGINE" run --rm --platform "$PLATFORM" -v "$mount" --entrypoint /bin/sh "$tag" -c "$DUMP"
}

snapshot old "$old_url" "$old_sha" "$old_ver"
snapshot new "$new_url" "$new_sha" "$new_ver"

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
