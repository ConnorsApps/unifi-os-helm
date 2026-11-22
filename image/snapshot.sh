#!/bin/sh
# Text snapshots of the raw upstream rootfs (/bundle, from the `extractor`
# stage) for the parts this repo depends on, written to /out. The Dockerfile's
# `snapshot-out` stage exports them; scripts/diff-uos-images.sh diffs two
# releases' snapshots to spot changes that break image/patch.sh.
set -eu
R=/bundle/rootfs
mkdir -p /out
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
awk '/^Package: /{p=$2} /^Version: /{print p" "$2}' var/lib/dpkg/status | sort > /out/packages.txt
jq '{args: .process.args, env: .process.env, cwd: .process.cwd, user: .process.user}' /bundle/config.json > /out/oci-process.json
