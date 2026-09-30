#!/usr/bin/env bash
# Static checks on a built image: every image/rootfs file is present and each
# patch in image/patch.sh took effect. Does not boot the image (that needs
# systemd + Postgres + RabbitMQ; see the upgrade skill).
#
# Usage: scripts/verify-image.sh <image> [expected-version]
# Env:   CONTAINER_ENGINE (default podman), PLATFORM (e.g. linux/arm64)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:?usage: verify-image.sh <image> [expected-version]}"
EXPECTED_VERSION="${2:-}"
ENGINE="${CONTAINER_ENGINE:-podman}"
OVERLAY="$(cd "$ROOT/image/rootfs" && find . ! -type d | sed 's|^\.||' | sort | tr '\n' ' ')"

# Runs inside the image with /bin/sh; exits 1 on any FAIL.
# shellcheck disable=SC2016
CHECKS='
fails=0
ok()    { echo "PASS  $1"; }
bad()   { echo "FAIL  $1"; fails=$((fails + 1)); }
has()   { if [ -e "$1" ]; then ok "exists: $1"; else bad "missing: $1"; fi; }
hasnt() { if [ -e "$1" ]; then bad "should be removed: $1"; else ok "removed: $1"; fi; }
eq()    { v="$(cat "$1" 2>/dev/null)"; if [ "$v" = "$2" ]; then ok "$1 = $2"; else bad "$1 = \"$v\" (want \"$2\")"; fi; }
grepq() { if grep -Eq -- "$2" "$1" 2>/dev/null; then ok "$1 matches /$2/"; else bad "$1 lacks /$2/"; fi; }
nogrep(){ if grep -Eq -- "$2" "$1" 2>/dev/null; then bad "$1 still matches /$2/"; else ok "$1 has no /$2/"; fi; }

for f in $OVERLAY; do has "$f"; done
grepq /entrypoint.sh "^exec "
grepq /usr/lib/version "^UOSSERVER\.0000000\.${EXPECTED_VERSION:-[0-9]+\.[0-9]+\.[0-9]+}\.0000000\."
case "$(uname -m)" in
  x86_64) eq /usr/lib/platform linux-x64 ;;
  aarch64) eq /usr/lib/platform linux-arm64 ;;
  *) has /usr/lib/platform ;;
esac
nogrep /etc/default/unifi-core_advanced "host\.docker\.internal"
grepq /etc/nginx/nginx.conf "^error_log  /dev/stderr notice;"
has /usr/bin/timedatectl.real
has /usr/lib/postgresql/14
has /usr/bin/mongod
for p in /usr/lib/postgresql/16 /usr/lib/rabbitmq /usr/lib/erlang /usr/bin/mongo; do hasnt "$p"; done

echo
if [ "$fails" -eq 0 ]; then echo "All checks passed"; else echo "$fails check(s) failed"; exit 1; fi
'

platform=()
[ -n "${PLATFORM:-}" ] && platform=(--platform "$PLATFORM")
"$ENGINE" run --rm ${platform[@]+"${platform[@]}"} \
  -e "EXPECTED_VERSION=$EXPECTED_VERSION" -e "OVERLAY=$OVERLAY" \
  --entrypoint /bin/sh "$IMAGE" -c "$CHECKS"
