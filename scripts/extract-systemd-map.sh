#!/bin/bash
# Extract systemd unit graph and unifi-core dependencies from UniFi OS image.
# Run inside the container (podman run --rm -it --entrypoint /bin/bash <image> -c 'bash -s' < extract-systemd-map.sh)
# Or: podman run --rm -v $(pwd)/file-dumps/systemd-services:/out <image> /bin/bash -c "$(cat extract-systemd-map.sh)"
#
# Output: ./file-dumps/systemd-services/ (or $1) with systemd units, service deps, and unifi-core info.

set -euo pipefail
OUT="${1:-/out}"
# Use /out when running via: podman run -v $(pwd)/file-dumps/systemd-services:/out ...
[ -d /out ] && OUT=/out

mkdir -p "$OUT"

echo "=== Systemd units (all .service, .target) ==="
find /etc/systemd /lib/systemd -name '*.service' -o -name '*.target' 2>/dev/null | sort > "$OUT/units.txt" || true
cat "$OUT/units.txt"

echo ""
echo "=== unifi-core related units ==="
grep -i unifi "$OUT/units.txt" 2>/dev/null || echo "(none found)"
grep -i uos "$OUT/units.txt" 2>/dev/null || echo "(none found)"
grep -i rabbit "$OUT/units.txt" 2>/dev/null || echo "(none found)"
grep -i mongo "$OUT/units.txt" 2>/dev/null || echo "(none found)"

echo ""
echo "=== Default target and key services ==="
ls -la /lib/systemd/system/default.target 2>/dev/null || true
ls -la /etc/systemd/system/*.wants/ 2>/dev/null || true

echo ""
echo "=== unifi-core binary info ==="
file /usr/bin/unifi-core 2>/dev/null || true
ldd /usr/bin/unifi-core 2>/dev/null | head -30 || true

echo ""
echo "=== unifi-core unit file (if exists) ==="
for f in /etc/systemd/system/unifi*.service /lib/systemd/system/unifi*.service \
         /etc/systemd/system/uos*.service /lib/systemd/system/uos*.service; do
  [ -f "$f" ] && echo "--- $f ---" && cat "$f"
done 2>/dev/null || echo "(no unifi/uos service files)"

echo ""
echo "=== All .service files in systemd ==="
for f in /lib/systemd/system/*.service /etc/systemd/system/*.service; do
  [ -f "$f" ] && echo "--- $f ---" && cat "$f" && echo ""
done 2>/dev/null | tee "$OUT/all-services.txt" || true

echo ""
echo "=== Wants/Requires for multi-user.target ==="
ls -la /etc/systemd/system/multi-user.target.wants/ 2>/dev/null || true
ls -la /lib/systemd/system/multi-user.target.wants/ 2>/dev/null || true

echo ""
echo "Done. Output in $OUT"
