# Unifi-OS Helm Chart TODO

## Ingress / TLS
- [ ] Add support for inform url over httproute
  - /inform should go to inform (8080) port
  - If not possible, add separate inform service, and point the httproute to that if the target is
  /inform
