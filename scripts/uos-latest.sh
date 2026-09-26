#!/usr/bin/env bash
# Report the latest UniFi OS Server release for Linux: version, release date,
# release notes, and per-architecture installer URLs + sha256 checksums.
#
# Sources (both unauthenticated JSON APIs, queried by ui.com itself):
#   1. fw-update firmware API (primary; has sha256 + size):
#        https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-os-server&filter=eq~~channel~~release
#   2. ui.com download catalogue (fallback; no checksums):
#        https://download.svc.ui.com/v1/software-downloads
#
# Usage:
#   scripts/uos-latest.sh                 # KEY=value lines, same keys as uos-version.env
#   scripts/uos-latest.sh --json          # normalized JSON
#   scripts/uos-latest.sh --check         # compare with uos-version.env; exit 10 if an update exists
#   scripts/uos-latest.sh --from-file f   # parse a saved response from either API (offline use)
#   scripts/uos-latest.sh --source software-downloads
#
# Exit codes: 0 ok / up to date, 10 update available (--check), 1 error.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${UOS_VERSION_FILE:-$ROOT/uos-version.env}"

FW_UPDATE_URL='https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-os-server&filter=eq~~channel~~release'
SOFTWARE_DOWNLOADS_URL='https://download.svc.ui.com/v1/software-downloads'
RELEASE_NOTES_BASE='https://community.ui.com/releases/r/uosserver'

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

format="env"
check=false
from_file=""
source=auto
while [ $# -gt 0 ]; do
  case "$1" in
    --json) format=json ;;
    --check) check=true ;;
    --from-file) from_file="${2:?--from-file needs a path}"; shift ;;
    --source) source="${2:?--source needs fw-update|software-downloads}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }

# Both normalizers emit a flat list of Linux installers:
#   [{version, platform: linux-x64|linux-arm64, url, sha256, size, released}]
# shellcheck disable=SC2016
JQ_FW_UPDATE='
  [._embedded.firmware[]?
   | select(.platform == "linux-x64" or .platform == "linux-arm64")
   | {version: (.version | ltrimstr("v")), platform, url: ._links.data.href,
      sha256: (.sha256_checksum // ""), size: .file_size,
      released: ((.created // "")[0:10])}]'
# shellcheck disable=SC2016
JQ_SOFTWARE_DOWNLOADS='
  (if type == "array" then . else (.downloads // .data // []) end)
  | [.[]
     | select(any(.products[]?; .slug == "unifi-os-server"))
     | (.filename // (.file_url | split("/") | last)) as $f
     | (if ($f | test("-linux-x64-")) then "linux-x64"
        elif ($f | test("-linux-arm64-")) then "linux-arm64"
        else empty end) as $p
     | {version, platform: $p, url: .file_url, sha256: "", size: null,
        released: (.date_published // "")}]'

fetch() {
  curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 60 "$1"
}

normalize() { # <fw-update|software-downloads>  (JSON on stdin)
  case "$1" in
    fw-update) jq -c "$JQ_FW_UPDATE" ;;
    software-downloads) jq -c "$JQ_SOFTWARE_DOWNLOADS" ;;
    *) echo "ERROR: unknown source '$1'" >&2; return 1 ;;
  esac
}

assets=""
if [ -n "$from_file" ]; then
  [ -r "$from_file" ] || { echo "ERROR: cannot read $from_file" >&2; exit 1; }
  if [ "$source" = auto ]; then
    if jq -e 'has("_embedded")?' "$from_file" >/dev/null 2>&1; then source=fw-update; else source=software-downloads; fi
  fi
  assets="$(normalize "$source" < "$from_file")"
else
  requested="$source"
  if [ "$requested" = auto ] || [ "$requested" = fw-update ]; then
    if raw="$(fetch "$FW_UPDATE_URL")"; then
      assets="$(printf '%s' "$raw" | normalize fw-update)"
      source=fw-update
    else
      echo "WARN: fw-update API unreachable" >&2
    fi
  fi
  if { [ -z "$assets" ] || [ "$assets" = "[]" ]; } \
      && { [ "$requested" = auto ] || [ "$requested" = software-downloads ]; }; then
    if raw="$(fetch "$SOFTWARE_DOWNLOADS_URL")"; then
      assets="$(printf '%s' "$raw" | normalize software-downloads)"
      source=software-downloads
      echo "WARN: using download.svc.ui.com fallback — no sha256 checksums available" >&2
    fi
  fi
  if [ -z "$assets" ]; then
    cat >&2 <<EOF
ERROR: could not reach Ubiquiti's release APIs (network policy?).
Fetch the metadata on a machine with access and pass it in:
  curl -s '$FW_UPDATE_URL' > fw-update.json
  $0 --from-file fw-update.json
EOF
    exit 1
  fi
fi

# Keep only the newest version (numeric compare, not string compare).
release="$(printf '%s' "$assets" | jq -c --arg notes "$RELEASE_NOTES_BASE" --arg source "$source" '
  if length == 0 then error("no Linux UniFi OS Server installers found in response") else . end
  | (max_by(.version | split(".") | map(tonumber? // 0)) | .version) as $v
  | [.[] | select(.version == $v)] as $a
  | {version: $v,
     released: ([$a[].released | select(. != "")] | first // ""),
     release_notes_url: "\($notes)/\($v)",
     source: $source,
     assets: ($a | unique_by(.platform) | map(del(.version, .released)))}')"

asset_field() { # <platform> <field>
  printf '%s' "$release" | jq -r --arg p "$1" --arg f "$2" \
    '(.assets[] | select(.platform == $p) | .[$f]) // "" | tostring | if . == "null" then "" else . end'
}

latest="$(printf '%s' "$release" | jq -r .version)"

if [ "$check" = true ]; then
  [ -r "$VERSION_FILE" ] || { echo "ERROR: $VERSION_FILE not found" >&2; exit 1; }
  current="$(sed -n 's/^UOS_VERSION=//p' "$VERSION_FILE")"
  newest="$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -n1)"
  update=false
  if [ "$current" != "$latest" ] && [ "$newest" = "$latest" ]; then update=true; fi
  echo "current=$current"
  echo "latest=$latest"
  echo "update_available=$update"
  echo "release_notes_url=$RELEASE_NOTES_BASE/$latest"
  [ "$update" = true ] && exit 10
  exit 0
fi

if [ "$format" = json ]; then
  printf '%s' "$release" | jq .
  exit 0
fi

cat <<EOF
UOS_VERSION=$latest
UOS_RELEASED=$(printf '%s' "$release" | jq -r .released)
UOS_INSTALLER_URL_AMD64=$(asset_field linux-x64 url)
UOS_INSTALLER_SHA256_AMD64=$(asset_field linux-x64 sha256)
UOS_INSTALLER_URL_ARM64=$(asset_field linux-arm64 url)
UOS_INSTALLER_SHA256_ARM64=$(asset_field linux-arm64 sha256)
UOS_RELEASE_NOTES_URL=$RELEASE_NOTES_BASE/$latest
EOF
