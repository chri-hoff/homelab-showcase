#!/usr/bin/env python3
"""Egress proxy with an allowlist for the DR test VM (#157).

The VM sits in an isolated libvirt network (no forwarding): it can reach only the
laptop. This proxy, started by dr-test.sh on the laptop's address in that network, is
its only way out -- and only to the hosts needed to rebuild the homelab (Debian mirrors,
Docker registries, CrowdSec hub, GitHub releases). Everything the restored homelab would
talk to on its own (Telegram, smtp, ipv64, Let's Encrypt, Gitea, OneDrive ...) is
simply unreachable, because no container is configured to use this proxy anyway.

    drtest-proxy.py <listen-addr> <port> <logfile>

Plain HTTP (apt) and CONNECT (HTTPS) only. Every request is logged as ALLOW/DENY so a
missing allowlist entry shows up directly in the log.
"""
import asyncio
import sys
import time

# Host suffixes (the host itself or any subdomain)
ALLOW = (
    "deb.debian.org", "security.debian.org", "debian.map.fastlydns.net",
    "download.docker.com",
    "docker.io", "docker.com",                  # registry-1/auth/production.cloudflare
    "ghcr.io", "githubusercontent.com", "github.com",
    "packagecloud.io", "cloudfront.net",        # CrowdSec apt repo and its CDN
    "crowdsec.net",                             # hub index and items
    "alpinelinux.org",                          # vault-agent image build (apk)
    "quay.io",
)

LOG = None


def log(verdict, host, port):
    LOG.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {verdict} {host}:{port}\n")
    LOG.flush()


def allowed(host):
    host = host.lower().rstrip(".")
    return any(host == s or host.endswith("." + s) for s in ALLOW)


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


async def handle(client_r, client_w):
    try:
        head = await client_r.readuntil(b"\r\n\r\n")
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError):
        client_w.close()
        return
    line = head.split(b"\r\n", 1)[0].decode("latin-1")
    try:
        method, target, _ = line.split(" ", 2)
    except ValueError:
        client_w.close()
        return

    if method == "CONNECT":
        host, _, port = target.rpartition(":")
        port = int(port or 443)
        rest = b""
    else:
        # absolute-form URI: http://host[:port]/path
        if not target.startswith("http://"):
            client_w.write(b"HTTP/1.1 400 Bad Request\r\n\r\n")
            client_w.close()
            return
        hostport, _, path = target[7:].partition("/")
        host, _, port = hostport.partition(":")
        port = int(port or 80)
        rest = head.replace(target.encode(), b"/" + path.encode(), 1)

    if not allowed(host):
        log("DENY ", host, port)
        client_w.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
        await client_w.drain()
        client_w.close()
        return
    log("ALLOW", host, port)

    try:
        up_r, up_w = await asyncio.wait_for(asyncio.open_connection(host, port), 20)
    except (OSError, asyncio.TimeoutError):
        client_w.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        client_w.close()
        return

    if method == "CONNECT":
        client_w.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
        await client_w.drain()
    else:
        up_w.write(rest)
        await up_w.drain()
    await asyncio.gather(pipe(client_r, up_w), pipe(up_r, client_w))


async def main(addr, port):
    server = await asyncio.start_server(handle, addr, port, limit=1 << 16)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    LOG = open(sys.argv[3], "a", buffering=1)
    asyncio.run(main(sys.argv[1], int(sys.argv[2])))
