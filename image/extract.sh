#!/bin/sh
# Download the UniFi OS Server installer for TARGETARCH and unpack the OCI image
# embedded in it to /bundle (rootfs/ + config.json).
set -eu

arch="${TARGETARCH:-$(dpkg --print-architecture)}"
case "$arch" in
  amd64) url="${UOS_INSTALLER_URL_AMD64:-}" sha="${UOS_INSTALLER_SHA256_AMD64:-}" ;;
  arm64) url="${UOS_INSTALLER_URL_ARM64:-}" sha="${UOS_INSTALLER_SHA256_ARM64:-}" ;;
  *) echo "ERROR: unsupported architecture $arch" >&2; exit 1 ;;
esac
[ -n "$url" ] || { echo "ERROR: no installer URL for $arch (set the UOS_INSTALLER_URL_<ARCH> build arg)" >&2; exit 1; }

cd /tmp
echo "Installer ($arch): $url"
echo "$url" > installer-url
curl -fsSL --retry 3 --retry-delay 5 -o installer "$url"
if [ -n "$sha" ]; then
  echo "$sha  installer" | sha256sum -c -
else
  echo "WARN: no sha256; installer not verified" >&2
fi

# The installer wraps a zip holding image.tar; prefer that copy over anything
# binwalk carved out directly.
binwalk --run-as=root -e installer
x=/tmp/_installer.extracted
zip="$(find "$x" -name '*.zip' | head -n1)"
[ -z "$zip" ] || unzip -oq "$zip" -d "$x/zip" || echo "WARN: unzip failed, trying a carved image.tar" >&2
tar="$(find "$x/zip" -name image.tar 2>/dev/null | head -n1)"
[ -n "$tar" ] || tar="$(find "$x" -maxdepth 2 -name image.tar | head -n1)"
[ -n "$tar" ] || { echo "ERROR: no image.tar in installer" >&2; ls -laR "$x" >&2; exit 1; }

# image.tar holds Docker v2 manifests in an OCI layout: skopeo normalizes it,
# umoci unpacks rootfs + config.json.
skopeo copy "oci-archive:$tar" "oci:/tmp/oci:uosserver:uosserver"
umoci unpack --image /tmp/oci:uosserver:uosserver /bundle
