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
#   scripts/diff-uos-images.sh [OLD_INSTALLER_URL [NEW_INSTALLER_URL]]
#     OLD defaults to the amd64 installer pinned in uos-version.env
#     NEW defaults to the latest amd64 installer (scripts/uos-latest.sh)
#
# Env: CONTAINER_ENGINE (default podman), PLATFORM (default linux/amd64),
#      OUT_DIR (default file-dumps/upgrade-<old>-<new>)
# Output: $OUT_DIR/{old,new}/*.txt, $OUT_DIR/upstream.diff, summary on stdout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${CONTAINER_ENGINE:-podman}"
PLATFORM="${PLATFORM:-linux/amd64}"

env_get() { sed -n "s/^$1=//p" "$ROOT/uos-version.env"; }
version_of() { printf '%s' "${1##*/}" | sed -nE 's#.*-([0-9]+\.[0-9]+\.[0-9]+)-.*#\1#p'; }

old_url="${1:-$(env_get UOS_INSTALLER_URL_AMD64)}"
old_sha=""
[ $# -ge 1 ] || old_sha="$(env_get UOS_INSTALLER_SHA256_AMD64)"
if [ $# -ge 2 ]; then
  new_url="$2"; new_sha=""
else
  meta="$("$ROOT/scripts/uos-latest.sh")" \
    || { echo "ERROR: pass NEW_INSTALLER_URL explicitly (latest release lookup failed)" >&2; exit 1; }
  new_url="$(printf '%s\n' "$meta" | sed -n 's/^UOS_INSTALLER_URL_AMD64=//p')"
  new_sha="$(printf '%s\n' "$meta" | sed -n 's/^UOS_INSTALLER_SHA256_AMD64=//p')"
fi
[ -n "$old_url" ] && [ -n "$new_url" ] || { echo "ERROR: missing installer URL(s)" >&2; exit 1; }

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
