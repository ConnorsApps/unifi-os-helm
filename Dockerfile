# syntax=docker/dockerfile:1
# Repackages the OCI image embedded in Ubiquiti's UniFi OS Server installer.
# Build with `make build` (installer URLs + sha256 come from uos-version.env).

FROM debian:bookworm-slim AS extractor
RUN apt-get update && apt-get install -y --no-install-recommends \
      binwalk ca-certificates curl jq skopeo umoci unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*
ARG TARGETARCH
ARG UOS_INSTALLER_URL_AMD64
ARG UOS_INSTALLER_SHA256_AMD64
ARG UOS_INSTALLER_URL_ARM64
ARG UOS_INSTALLER_SHA256_ARM64
COPY image/extract.sh /src/
RUN sh /src/extract.sh

# Raw upstream ends here. The snapshot stages (scripts/diff-uos-images.sh builds
# --target snapshot-out) stay above the final stage, the default target that
# publish-image.yml builds.
FROM extractor AS snapshot
COPY image/snapshot.sh /src/
RUN sh /src/snapshot.sh

FROM scratch AS snapshot-out
COPY --from=snapshot /out /

FROM extractor AS patcher
ARG TARGETARCH
ARG PATCH_STRICT=true
COPY image/ /src/
RUN sh /src/patch.sh

FROM scratch
COPY --from=patcher /bundle/rootfs/ /
ENTRYPOINT ["/entrypoint.sh"]
