# Changelog

Chart releases, newest first; each names the UniFi OS Server release it
packages (the chart's `appVersion`, and the image tag). `make upgrade` and
`make upgrade-verify` write the upstream-upgrade entries.

## 0.10.2

UniFi OS 5.1.42 (released 2026-09-10), unchanged from 0.10.1.

- JSON schema for the chart values (`values.schema.json`; `make schema` generates it, `make schema-check` fails when it is stale).
- `values.yaml`, `values.env.example.yaml` and the README example start with a `# yaml-language-server: $schema=` comment, so editors validate values.
