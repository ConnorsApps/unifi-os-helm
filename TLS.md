# TLS Configuration

UniFi OS's internal nginx always listens on HTTPS (port 443). The chart provides
three options for the TLS certificate it uses.

---

## Option A — Self-signed (default)

No configuration needed. The init container generates a self-signed certificate
at startup and writes it to `/data/unifi-core/config/unifi-core.crt`.

This works for internal access but browsers will show a security warning, and
Gateway API `BackendTLSPolicy` cannot verify it without extra steps.

---

## Option B — Existing TLS secret

If you already have a `kubernetes.io/tls` secret in the namespace:

```yaml
unifi:
  tls:
    existingSecret: my-tls-secret   # must have tls.crt and tls.key keys
```

The init container copies `tls.crt` → `unifi-core.crt` and `tls.key` → `unifi-core.key`
before nginx starts, skipping self-signed generation. An optional `ca.crt` key is
used as the CA cert; if absent, `tls.crt` is used as its own CA.

---

## Option C — cert-manager (recommended)

Requires the [cert-manager](https://cert-manager.io/) operator installed in your cluster.

```yaml
unifi:
  tls:
    certManager:
      enabled: true
      issuerRef:
        name: letsencrypt-prod   # your ClusterIssuer or Issuer name
        kind: ClusterIssuer
      # dnsNames defaults to gateway.httpRoute.hostname when not set
      dnsNames:
        - unifi.example.com
```

cert-manager issues the certificate and stores it in the secret named
`unifi.tls.certManager.secretName` (default: `unifi-tls`). The init container
mounts and copies it exactly as in Option B.

### BackendTLSPolicy

When a gateway terminates TLS and forwards to the UniFi backend, it sends plain
HTTP to port 443 — which nginx rejects. Enable `backendTLSPolicy` to generate a
Gateway API `BackendTLSPolicy` that tells the gateway to re-encrypt:

**Public CA (Let's Encrypt etc.):**

```yaml
unifi:
  tls:
    certManager:
      enabled: true
      issuerRef:
        name: letsencrypt-prod
      backendTLSPolicy:
        enabled: true
        wellKnownCACertificates: System
```

**Private CA:**

```yaml
unifi:
  tls:
    certManager:
      enabled: true
      issuerRef:
        name: my-internal-issuer
      backendTLSPolicy:
        enabled: true
        caCertificateRef:
          name: my-ca-configmap   # ConfigMap with ca.crt key containing the CA cert
```

### BackendTLSPolicy hostname

The SNI hostname sent to the backend defaults to `dnsNames[0]` (or
`gateway.httpRoute.hostname`). Override with:

```yaml
      backendTLSPolicy:
        enabled: true
        wellKnownCACertificates: System
        hostname: unifi.example.com
```

---

## Summary

| Option | Secret source | BackendTLSPolicy |
|--------|--------------|-----------------|
| Self-signed | Generated at init time | Not practical (no verifiable CA) |
| `existingSecret` | You provide | Possible with `caCertificateRef` if you have the CA |
| `certManager` | cert-manager issues | `wellKnownCACertificates: System` for public CAs |
