# Network: AdGuard Home

DNS for the whole network, with ad and tracker blocking.

- Besides plain DNS on port 53, the compose file publishes the ports for encrypted DNS:
  DNS-over-TLS (853/tcp), DNSCrypt (5443) and HTTP/3 for DNS-over-HTTPS (443/udp). Which of
  them are active is configured in AdGuard's own settings.
- **Web UI behind Traefik** with `std-app-internal-chain`, which allows LAN, IoT and VPN only.
  The UI is not reachable from the internet.
- The image version is pinned via `VERSION` and checked by the update pipeline like every other
  container (`update-pipeline/`).

## Setup

1. Copy `adguard.env.example` to `adguard.env` and set `TRAEFIK_HOST` and `VERSION`.
2. Free port 53 on the host if `systemd-resolved` occupies it.
3. Point your router's DHCP DNS setting to the host.

Hostnames and IP ranges are placeholders (`example.com`, RFC 5737 ranges).
