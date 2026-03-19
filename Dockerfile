# syntax=docker/dockerfile:1
#
# Extracts the uosserver OCI image embedded in the UniFi OS Server
# self-extracting installer and repackages it as a standard Docker image.
#
# The installer bundles a podman image that cannot be run directly in a
# Docker build (it needs systemd). Binwalk extracts the embedded image.tar,
# skopeo converts it from Docker V2 to OCI format, and umoci unpacks the
# rootfs + config without any manual layer handling.
#
# Build:
#   docker build --build-arg UOS_INSTALLER_URL=<url> -t uosserver:<tag> .

FROM debian:bookworm-slim AS extractor

RUN apt-get update && apt-get install -y --no-install-recommends \
    binwalk \
    ca-certificates \
    curl \
    jq \
    skopeo \
    umoci \
    unzip \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

ARG VERSION
ARG UOS_INSTALLER_URL

RUN curl -fsSL --retry 3 --retry-delay 5 -o /tmp/installer "$UOS_INSTALLER_URL" && chmod +x /tmp/installer

WORKDIR /tmp

RUN binwalk --run-as=root -e /tmp/installer

# Binwalk extracts the embedded zip which contains image.tar. If binwalk
# didn't extract image.tar directly, fall back to manually unzipping.
RUN set -e \
    && EXTRACTED=/tmp/_installer.extracted \
    && [ -d "$EXTRACTED" ] || { echo "ERROR: binwalk extraction failed"; exit 1; } \
    && ZIP=$(find "$EXTRACTED" -name '*.zip' | head -1) \
    && IMAGE_TAR="" \
    && if [ -n "$ZIP" ]; then \
         echo "Using image.tar from embedded zip: $ZIP" \
         && rm -rf "$EXTRACTED/zip_contents" \
         && mkdir -p "$EXTRACTED/zip_contents" \
         && if unzip -o -q "$ZIP" -d "$EXTRACTED/zip_contents"; then \
              IMAGE_TAR=$(find "$EXTRACTED/zip_contents" -name "image.tar" | head -1); \
            else \
              echo "WARN: zip extraction failed, falling back to direct image.tar"; \
            fi; \
       fi \
    && if [ -z "$IMAGE_TAR" ]; then \
         IMAGE_TAR=$(find "$EXTRACTED" -maxdepth 2 -name "image.tar" | head -1); \
       fi \
    && [ -n "$IMAGE_TAR" ] || { echo "ERROR: no usable image.tar found"; ls -laR "$EXTRACTED"; exit 1; } \
    && echo "Found: $IMAGE_TAR" \
    && cp "$IMAGE_TAR" /tmp/image.tar \
    && mkdir -p /tmp/image \
    && tar -xf "$IMAGE_TAR" -C /tmp/image

# image.tar uses Docker V2 manifests inside an OCI layout. skopeo converts
# it to a proper OCI image so umoci can unpack the rootfs + config.json.
RUN set -e \
    && SRC="oci-archive:/tmp/image.tar" \
    && echo "Source reference: $SRC" \
    && skopeo copy "$SRC" "oci:/tmp/oci:uosserver:uosserver" \
    && umoci unpack --image /tmp/oci:uosserver:uosserver /bundle

# Linux Kubernetes pods usually do not resolve host.docker.internal.
# Point unifi-core discovery client at localhost inside the container.
RUN sed -i 's|host\.docker\.internal|localhost|g' \
    /bundle/rootfs/etc/default/unifi-core_advanced

# uos-discovery-client and uos-agent ship as stub binaries in the extracted
# image — they exit immediately (printing "Stub package") without providing
# any real functionality.  Both units use Restart=always + StartLimitIntervalSec=0
# which causes a tight restart storm that fills the journal with noise.
# Drop-in overrides suppress the restart loop.  uos-discovery-client is also
# disabled by default; keep it disabled since the stub never serves port 11002.
RUN mkdir -p \
         /bundle/rootfs/etc/systemd/system/uos-discovery-client.service.d \
         /bundle/rootfs/etc/systemd/system/uos-agent.service.d \
    && printf '[Service]\nRestart=no\n' \
         > /bundle/rootfs/etc/systemd/system/uos-discovery-client.service.d/no-restart.conf \
    && printf '[Service]\nRestart=no\n' \
         > /bundle/rootfs/etc/systemd/system/uos-agent.service.d/no-restart.conf

# Generate /entrypoint.sh from the OCI runtime config.
RUN set -e \
    && echo "=== OCI process config ===" \
    && jq '{args: .process.args, env: .process.env, cwd: .process.cwd}' /bundle/config.json \
    && jq -r \
        '"#!/bin/sh", \
         (.process.env // [] | .[] | \
           (split("=") | "export " + .[0] + "=" + (.[1:] | join("=") | @sh)) \
         ), \
         ("cd " + (.process.cwd // "/" | @sh)), \
         ("exec " + (.process.args | map(@sh) | join(" ")))' \
        /bundle/config.json > /bundle/rootfs/entrypoint.sh \
    && chmod +x /bundle/rootfs/entrypoint.sh \
    && echo "=== generated entrypoint.sh ===" \
    && cat /bundle/rootfs/entrypoint.sh

# Device files cannot be represented in a Docker layer tar; the runtime
# mounts /dev anyway, so clear it before the final COPY.
RUN find /bundle/rootfs/dev -mindepth 1 -delete 2>/dev/null || true

# /usr/lib/platform — generated at build time from uname -m. Matches UniFi installer naming.
RUN mkdir -p /bundle/rootfs/usr/lib \
    && case "$$(uname -m)" in \
         x86_64)   echo -n linux-x64 ;; \
         aarch64)  echo -n linux-arm64 ;; \
         *)        echo -n "linux-$$(uname -m)" ;; \
       esac > /bundle/rootfs/usr/lib/platform

RUN set -eu \
    && _version="${VERSION:-}" \
    && if [ -z "${_version}" ]; then \
         _version="$(printf '%s' "${UOS_INSTALLER_URL}" | sed -nE 's#.*-([0-9]+\.[0-9]+\.[0-9]+)-.*#\1#p')"; \
       fi \
    && [ -n "${_version}" ] || { echo "ERROR: VERSION build arg missing and unable to parse version from UOS_INSTALLER_URL"; exit 1; } \
    && echo "UOSSERVER.0000000.${_version}.0000000.000000.0000" > /bundle/rootfs/usr/lib/version

# Patch upstream nginx logging to container stdio without replacing the full file.
RUN set -e \
    && NGINX_CONF=/bundle/rootfs/etc/nginx/nginx.conf \
    && [ -f "$NGINX_CONF" ] \
    && sed -E -i 's|^[[:space:]]*access_log[[:space:]]+/data/unifi-core/logs/nginx-access\.log[[:space:]]+apm;|    access_log /dev/stdout apm;|' "$NGINX_CONF" \
    && sed -E -i 's|^[[:space:]]*error_log[[:space:]]+/data/unifi-core/logs/nginx-error\.log;|    error_log /dev/stderr;|' "$NGINX_CONF" \
    && sed -E -i 's|^[[:space:]]*error_log[[:space:]]+/var/log/nginx/error\.log[[:space:]]+notice;|error_log  /dev/stderr notice;|' "$NGINX_CONF"

# Bake static monolith startup wiring into the image so runtime only renders
# env/secret-derived files before handing off to systemd.
RUN set -e \
    && mkdir -p /bundle/rootfs/etc/systemd/system \
    && printf '%s\n' \
         '[Unit]' \
         'Description=External PostgreSQL (stub)' \
         '' \
         '[Service]' \
         'Type=oneshot' \
         'ExecStart=/bin/true' \
         'RemainAfterExit=yes' \
         '' \
         '[Install]' \
         'WantedBy=multi-user.target' \
       > /bundle/rootfs/etc/systemd/system/postgresql.service \
    && for _unit in postgresql@14-main.service postgresql-cluster@14-main.service mongodb.service rabbitmq-server.service epmd.service; do \
         printf '%s\n' \
           '[Unit]' \
           'Description=External dependency stub' \
           '' \
           '[Service]' \
           'Type=oneshot' \
           'ExecStart=/bin/true' \
           'RemainAfterExit=yes' \
           '' \
           '[Install]' \
           'WantedBy=multi-user.target' \
         > "/bundle/rootfs/etc/systemd/system/${_unit}"; \
       done \
    && mkdir -p /bundle/rootfs/etc/systemd/system.conf.d /bundle/rootfs/etc/sudoers.d \
    && printf '%s\n' \
         'Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' \
         'Defaults env_keep += "PGHOST PGPORT"' \
       > /bundle/rootfs/etc/sudoers.d/60-unifi-postgres-env \
    && chmod 0440 /bundle/rootfs/etc/sudoers.d/60-unifi-postgres-env \
    && mkdir -p /bundle/rootfs/usr/local/bin \
    && for _tool in psql createuser createdb dropdb dropuser; do \
         printf '%s\n' \
           '#!/bin/sh' \
           '_default_host="${PGHOST:-}"' \
           '_default_port="${PGPORT:-}"' \
           'if [ -z "${PGPASSWORD:-}" ] && [ -r /run/secrets/postgres-superuser/pgpass ]; then' \
           '  _pw="$(cut -d: -f5 /run/secrets/postgres-superuser/pgpass | head -n1)"' \
           '  [ -n "${_pw}" ] && export PGPASSWORD="${_pw}"' \
           'fi' \
           '_set_host=false' \
           '_set_port=false' \
           '_set_password_mode=false' \
           'for _arg in "$@"; do' \
           '  case "${_arg}" in' \
           '    -h|--host|--host=*) _set_host=true ;;' \
           '    -p|--port|--port=*) _set_port=true ;;' \
           '    -w|-W|--no-password|--password) _set_password_mode=true ;;' \
           '  esac' \
           'done' \
           'if [ -n "${_default_host}" ] && [ "${_set_host}" = "false" ]; then' \
           '  set -- "$@" --host="${_default_host}"' \
           'fi' \
           'if [ -n "${_default_port}" ] && [ "${_set_port}" = "false" ]; then' \
           '  set -- "$@" --port="${_default_port}"' \
           'fi' \
           'if [ "${_set_password_mode}" = "false" ]; then' \
           '  set -- "$@" --no-password' \
           'fi' \
           'exec "/usr/bin/$(basename "$0")" "$@"' \
         > "/bundle/rootfs/usr/local/bin/${_tool}" \
         && chmod 0755 "/bundle/rootfs/usr/local/bin/${_tool}"; \
       done

# Trim embedded local data-plane services not used in charted/externalized mode.
# Keep PostgreSQL 14 toolchain for compatibility with existing wrappers.
RUN set -e \
    && rm -rf \
         /bundle/rootfs/usr/bin/mongo \
         /bundle/rootfs/usr/bin/mongod \
         /bundle/rootfs/usr/bin/mongos \
         /bundle/rootfs/usr/bin/rabbitmq* \
         /bundle/rootfs/usr/sbin/rabbitmq* \
         /bundle/rootfs/usr/lib/rabbitmq \
         /bundle/rootfs/usr/lib/erlang \
         /bundle/rootfs/etc/rabbitmq \
         /bundle/rootfs/etc/mongodb.conf \
         /bundle/rootfs/var/lib/mongodb \
         /bundle/rootfs/var/lib/rabbitmq \
         /bundle/rootfs/var/log/rabbitmq \
         /bundle/rootfs/var/log/mongodb \
         /bundle/rootfs/usr/lib/postgresql/16 \
         /bundle/rootfs/usr/share/postgresql/16 \
         /bundle/rootfs/etc/postgresql/16 \
         /bundle/rootfs/var/lib/postgresql/16 \
         /bundle/rootfs/usr/share/doc \
         /bundle/rootfs/usr/share/man \
         /bundle/rootfs/usr/share/info

FROM scratch
COPY --from=extractor /bundle/rootfs/ /
ENTRYPOINT ["/entrypoint.sh"]
