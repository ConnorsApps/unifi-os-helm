# TLS

UniFi OS's nginx serves HTTPS only, on 443. The init container installs its
certificate from one of three sources:

| Option | Certificate | BackendTLSPolicy |
|---|---|---|
| Self-signed (default) | Generated at first start (`CN=unifi.local`) | Not practical: nothing to verify against |
| `existingSecret` | Your `kubernetes.io/tls` secret | `caCertificateRef` pointing at your CA |
| `certManager` (recommended) | Issued and renewed by cert-manager | `wellKnownCACertificates: System` for public CAs |

## Existing secret

```yaml
unifi:
  tls:
    existingSecret: my-tls-secret   # tls.crt, tls.key, optional ca.crt
```

Without `ca.crt`, `tls.crt` doubles as the CA certificate.

## cert-manager

Needs [cert-manager](https://cert-manager.io/). The Certificate writes to
`certManager.secretName` (default `unifi-tls`), which is then used like an
existing secret.

```yaml
unifi:
  tls:
    certManager:
      enabled: true
      issuerRef:
        name: letsencrypt-prod
        kind: ClusterIssuer
      dnsNames:                     # default: [gateway.httpRoute.hostname]
        - unifi.example.com
```

## BackendTLSPolicy

A gateway that terminates TLS forwards plain HTTP, which nginx on 443 rejects.
`backendTLSPolicy` makes the gateway re-encrypt. It needs `hostname` (the SNI
name on nginx's certificate) and exactly one CA source:

```yaml
unifi:
  tls:
    backendTLSPolicy:
      enabled: true
      hostname: unifi.example.com
      wellKnownCACertificates: System   # public CA; or for a private CA:
      # caCertificateRef:
      #   name: my-ca-configmap         # ConfigMap with key ca.crt
```
