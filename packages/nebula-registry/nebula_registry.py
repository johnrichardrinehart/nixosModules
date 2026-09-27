#!/usr/bin/env python3
"""Nebula peer registry for lighthouses.

For every local lighthouse instance (one per overlay), poll Nebula's debug SSH
console, keep a permanent history of every certificate ever seen, track
liveness, answer DNS for the overlay's zone, and serve an HTTPS view that shows
each caller the peers inside its own certificate's networks.
"""

from __future__ import annotations

import argparse
import html
import ipaddress
import json
import re
import socket
import socketserver
import sqlite3
import ssl
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from typing import Any

from dnslib import AAAA, NS, QTYPE, RCODE, RR, SOA, A, DNSError, DNSRecord

# Linux IP_FREEBIND: bind the overlay address before Nebula creates the tun
# interface (and keep the socket across Nebula restarts).
IP_FREEBIND = getattr(socket, "IP_FREEBIND", 15)
DNS_TTL = 60
SECONDS_PER_DAY = 86400

SCHEMA = """
CREATE TABLE IF NOT EXISTS peers (
    network TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    name TEXT NOT NULL,
    vpn_addrs TEXT NOT NULL,
    groups TEXT NOT NULL,
    issuer TEXT NOT NULL,
    not_before TEXT,
    not_after TEXT,
    first_seen REAL NOT NULL,
    last_seen REAL NOT NULL,
    last_underlay TEXT,
    relayed INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (network, fingerprint)
);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY,
    ts REAL NOT NULL,
    network TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    kind TEXT NOT NULL,
    detail TEXT
);
CREATE INDEX IF NOT EXISTS events_ts ON events (ts);
"""


def log(message: str) -> None:
    print(f"nebula-registry: {message}", file=sys.stderr, flush=True)


@dataclass(frozen=True)
class Observation:
    """One certificate seen in a poll, with how the lighthouse reaches it."""

    fingerprint: str
    name: str
    vpn_addrs: tuple[str, ...]  # certificate networks, e.g. ("10.77.0.2/24",)
    groups: tuple[str, ...]
    issuer: str
    not_before: str | None
    not_after: str | None
    underlay: str | None
    relayed: bool


def _certificate(
    cert: dict[str, Any], underlay: str | None, relayed: bool
) -> Observation:
    details = cert.get("details") or {}
    # v2 certificates call them networks; v1 JSON used ips.
    networks = details.get("networks") or details.get("ips") or []
    return Observation(
        fingerprint=cert["fingerprint"],
        name=details.get("name", ""),
        vpn_addrs=tuple(networks),
        groups=tuple(details.get("groups") or ()),
        issuer=details.get("issuer", ""),
        not_before=details.get("notBefore"),
        not_after=details.get("notAfter"),
        underlay=underlay,
        relayed=relayed,
    )


def parse_hostmap(output: str) -> list[Observation]:
    """Parse `list-hostmap -json`: every peer with a live tunnel."""
    observations = []
    for entry in json.loads(output) or []:
        cert = entry.get("cert")
        if not cert:
            continue
        remote = entry.get("currentRemote") or None
        if remote == "invalid AddrPort":
            remote = None
        relayed = bool(entry.get("currentRelaysToMe"))
        observations.append(_certificate(cert, remote, relayed))
    return observations


def parse_self(output: str) -> Observation:
    """Parse `print-cert -json` without an address: the lighthouse's own cert."""
    cert = json.loads(output)
    if isinstance(cert, list):
        cert = cert[0]
    return _certificate(cert, None, False)


def dns_label(name: str) -> str | None:
    label = re.sub(r"[^a-z0-9-]+", "-", name.lower()).strip("-")[:63].strip("-")
    return label or None


def addresses(vpn_addrs: list[str] | tuple[str, ...]) -> list[str]:
    return [str(ipaddress.ip_interface(network).ip) for network in vpn_addrs]


class Registry:
    """Permanent peer history. Only the poll thread touches the database."""

    def __init__(self, db: sqlite3.Connection, offline_after: float) -> None:
        self.db = db
        self.offline_after = offline_after
        db.executescript(SCHEMA)
        # Liveness survives restarts: it is the latest online/offline event.
        self.online: dict[tuple[str, str], bool] = {
            (network, fingerprint): kind == "online"
            for network, fingerprint, kind in db.execute(
                """
                SELECT network, fingerprint, kind FROM events
                WHERE id IN (
                    SELECT max(id) FROM events
                    WHERE kind IN ('online', 'offline')
                    GROUP BY network, fingerprint
                )
                """
            )
        }

    def _event(
        self,
        now: float,
        network: str,
        fingerprint: str,
        kind: str,
        detail: str | None = None,
    ) -> None:
        self.db.execute(
            "INSERT INTO events (ts, network, fingerprint, kind, detail) VALUES (?, ?, ?, ?, ?)",
            (now, network, fingerprint, kind, detail),
        )

    def record(self, network: str, observations: list[Observation], now: float) -> None:
        with self.db:
            for obs in {o.fingerprint: o for o in observations}.values():
                row = self.db.execute(
                    "SELECT last_underlay FROM peers WHERE network = ? AND fingerprint = ?",
                    (network, obs.fingerprint),
                ).fetchone()
                if row is None:
                    self.db.execute(
                        """
                        INSERT INTO peers (network, fingerprint, name, vpn_addrs, groups, issuer,
                            not_before, not_after, first_seen, last_seen, last_underlay, relayed)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            network,
                            obs.fingerprint,
                            obs.name,
                            json.dumps(list(obs.vpn_addrs)),
                            json.dumps(list(obs.groups)),
                            obs.issuer,
                            obs.not_before,
                            obs.not_after,
                            now,
                            now,
                            obs.underlay,
                            int(obs.relayed),
                        ),
                    )
                    self._event(now, network, obs.fingerprint, "first_seen", obs.name)
                    previous = self.db.execute(
                        """
                        SELECT fingerprint FROM peers
                        WHERE network = ? AND name = ? AND fingerprint != ?
                        ORDER BY last_seen DESC LIMIT 1
                        """,
                        (network, obs.name, obs.fingerprint),
                    ).fetchone()
                    if previous:
                        self._event(
                            now,
                            network,
                            obs.fingerprint,
                            "cert_changed",
                            f"replaces {previous[0]}",
                        )
                else:
                    (last_underlay,) = row
                    if obs.underlay and last_underlay and obs.underlay != last_underlay:
                        self._event(
                            now,
                            network,
                            obs.fingerprint,
                            "address_changed",
                            f"{last_underlay} -> {obs.underlay}",
                        )
                    self.db.execute(
                        """
                        UPDATE peers SET last_seen = ?, last_underlay = coalesce(?, last_underlay), relayed = ?
                        WHERE network = ? AND fingerprint = ?
                        """,
                        (now, obs.underlay, int(obs.relayed), network, obs.fingerprint),
                    )
                if not self.online.get((network, obs.fingerprint)):
                    self._event(now, network, obs.fingerprint, "online", obs.underlay)
                    self.online[(network, obs.fingerprint)] = True

    def sweep(self, network: str, now: float) -> None:
        """Mark peers offline once they miss the configured number of polls."""
        with self.db:
            for fingerprint, last_seen in self.db.execute(
                "SELECT fingerprint, last_seen FROM peers WHERE network = ?", (network,)
            ).fetchall():
                key = (network, fingerprint)
                if self.online.get(key) and now - last_seen > self.offline_after:
                    self._event(now, network, fingerprint, "offline", None)
                    self.online[key] = False

    def prune(self, now: float, retention_days: int) -> None:
        with self.db:
            self.db.execute(
                "DELETE FROM events WHERE ts < ?",
                (now - retention_days * SECONDS_PER_DAY,),
            )

    def peers(self, network: str) -> list[dict[str, Any]]:
        rows = self.db.execute(
            """
            SELECT fingerprint, name, vpn_addrs, groups, issuer, not_before, not_after,
                first_seen, last_seen, last_underlay, relayed
            FROM peers WHERE network = ? ORDER BY name, last_seen
            """,
            (network,),
        ).fetchall()
        return [
            {
                "fingerprint": fingerprint,
                "name": name,
                "vpn_addrs": json.loads(vpn_addrs),
                "groups": json.loads(groups),
                "issuer": issuer,
                "not_before": not_before,
                "not_after": not_after,
                "first_seen": first_seen,
                "last_seen": last_seen,
                "last_underlay": last_underlay,
                "relayed": bool(relayed),
                "online": self.online.get((network, fingerprint), False),
            }
            for (
                fingerprint,
                name,
                vpn_addrs,
                groups,
                issuer,
                not_before,
                not_after,
                first_seen,
                last_seen,
                last_underlay,
                relayed,
            ) in rows
        ]


def dns_records(peers: list[dict[str, Any]]) -> dict[str, list[str]]:
    """Map DNS labels to addresses; the most recently seen certificate wins."""
    records: dict[str, list[str]] = {}
    for peer in sorted(peers, key=lambda p: p["last_seen"]):
        label = dns_label(peer["name"])
        if label:
            records[label] = addresses(peer["vpn_addrs"])
    return records


@dataclass(frozen=True)
class Snapshot:
    peers: list[dict[str, Any]]
    records: dict[str, list[str]]
    serial: int


@dataclass(frozen=True)
class Zone:
    domain: str
    address: str  # the lighthouse's overlay address on this network
    site: str | None  # HTTPS site name, answered with `address` on every network


def answer(query: DNSRecord, zone: Zone, snapshot: Snapshot) -> DNSRecord:
    reply = query.reply()
    qname = str(query.q.qname).rstrip(".").lower()
    qtype = query.q.qtype
    domain = zone.domain.lower()
    primary = f"{zone.site or 'ns.' + domain}."
    soa = RR(
        f"{domain}.",
        QTYPE.SOA,
        ttl=DNS_TTL,
        rdata=SOA(
            primary,
            f"hostmaster.{domain}.",
            (snapshot.serial, 3600, 600, 86400, DNS_TTL),
        ),
    )

    if zone.site and qname == zone.site.lower():
        found: list[str] | None = [zone.address]
    elif qname == domain:
        if qtype in (QTYPE.SOA, QTYPE.ANY):
            reply.add_answer(soa)
        if qtype in (QTYPE.NS, QTYPE.ANY):
            reply.add_answer(RR(f"{domain}.", QTYPE.NS, ttl=DNS_TTL, rdata=NS(primary)))
        if not reply.rr:
            reply.add_auth(soa)
        return reply
    elif qname.endswith("." + domain):
        label = qname[: -len(domain) - 1]
        found = None if "." in label else snapshot.records.get(label)
        if found is None:
            reply.header.rcode = RCODE.NXDOMAIN
            reply.add_auth(soa)
            return reply
    else:
        reply.header.aa = 0
        reply.header.rcode = RCODE.REFUSED
        return reply

    for address in found:
        ip = ipaddress.ip_address(address)
        if ip.version == 4 and qtype in (QTYPE.A, QTYPE.ANY):
            reply.add_answer(RR(query.q.qname, QTYPE.A, ttl=DNS_TTL, rdata=A(address)))
        elif ip.version == 6 and qtype in (QTYPE.AAAA, QTYPE.ANY):
            reply.add_answer(
                RR(query.q.qname, QTYPE.AAAA, ttl=DNS_TTL, rdata=AAAA(address))
            )
    if not reply.rr:
        reply.add_auth(soa)
    return reply


def find_caller(peers: list[dict[str, Any]], source: str) -> dict[str, Any] | None:
    matches = [p for p in peers if source in addresses(p["vpn_addrs"])]
    matches.sort(key=lambda p: (p["online"], p["last_seen"]))
    return matches[-1] if matches else None


def visible_peers(
    peers: list[dict[str, Any]], caller: dict[str, Any]
) -> list[dict[str, Any]]:
    """Peers with an address inside any network of the caller's certificate."""
    prefixes = [
        ipaddress.ip_network(network, strict=False) for network in caller["vpn_addrs"]
    ]
    return [
        peer
        for peer in peers
        if any(
            ipaddress.ip_address(a) in prefix
            for a in addresses(peer["vpn_addrs"])
            for prefix in prefixes
        )
    ]


def _when(ts: float | None) -> str:
    if ts is None:
        return ""
    return time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(ts))


def render_html(
    network: str, caller: dict[str, Any], peers: list[dict[str, Any]]
) -> str:
    rows = []
    for peer in peers:
        cells = [
            peer["name"],
            ", ".join(addresses(peer["vpn_addrs"])),
            "online" if peer["online"] else "offline",
            _when(peer["last_seen"]),
            _when(peer["first_seen"]),
            peer["last_underlay"] or "",
            "relayed" if peer["relayed"] else "direct",
            peer["not_after"] or "",
        ]
        state = "online" if peer["online"] else "offline"
        rows.append(
            f'<tr class="{state}">'
            + "".join(f"<td>{html.escape(str(c))}</td>" for c in cells)
            + "</tr>"
        )
    headers = [
        "Name",
        "Overlay IP",
        "State",
        "Last seen",
        "First seen",
        "Underlay",
        "Path",
        "Cert expires",
    ]
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Nebula {html.escape(network)}</title>
<style>
body {{ font-family: sans-serif; margin: 2rem; }}
table {{ border-collapse: collapse; }}
th, td {{ padding: .3rem .8rem; border-bottom: 1px solid #ccc; text-align: left; }}
tr.offline {{ color: #888; }}
</style></head><body>
<h1>Nebula network <code>{html.escape(network)}</code></h1>
<p>Viewing as <strong>{html.escape(caller["name"])}</strong>
({html.escape(", ".join(caller["vpn_addrs"]))})</p>
<table><thead><tr>{"".join(f"<th>{h}</th>" for h in headers)}</tr></thead>
<tbody>
{chr(10).join(rows)}
</tbody></table></body></html>
"""


class State:
    """Latest snapshot per network, swapped atomically by the poll thread."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._snapshots: dict[str, Snapshot] = {}

    def set(self, network: str, snapshot: Snapshot) -> None:
        with self._lock:
            self._snapshots[network] = snapshot

    def get(self, network: str) -> Snapshot:
        with self._lock:
            return self._snapshots.get(network, Snapshot([], {}, 1))


def _freebind(sock: socket.socket) -> None:
    sock.setsockopt(socket.IPPROTO_IP, IP_FREEBIND, 1)


class DnsUdpServer(socketserver.ThreadingUDPServer):
    daemon_threads = True

    def server_bind(self) -> None:
        _freebind(self.socket)
        super().server_bind()


class DnsTcpServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self) -> None:
        _freebind(self.socket)
        super().server_bind()


def dns_handler(
    network: str, zone: Zone, state: State, tcp: bool
) -> type[socketserver.BaseRequestHandler]:
    def respond(data: bytes) -> bytes | None:
        try:
            query = DNSRecord.parse(data)
        except DNSError:
            return None
        return answer(query, zone, state.get(network)).pack()

    class UdpHandler(socketserver.BaseRequestHandler):
        def handle(self) -> None:
            data, sock = self.request
            response = respond(data)
            if response:
                sock.sendto(response, self.client_address)

    class TcpHandler(socketserver.StreamRequestHandler):
        timeout = 10

        def handle(self) -> None:
            while True:
                length = self.rfile.read(2)
                if len(length) < 2:
                    return
                response = respond(self.rfile.read(int.from_bytes(length, "big")))
                if not response:
                    return
                self.wfile.write(len(response).to_bytes(2, "big") + response)

    return TcpHandler if tcp else UdpHandler


class HttpsServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self) -> None:
        _freebind(self.socket)
        super().server_bind()

    def handle_error(self, request: Any, client_address: Any) -> None:
        # Failed TLS handshakes and dropped clients are routine; stay quiet.
        pass


def https_handler(network: str, state: State) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "nebula-registry"
        timeout = 10

        def setup(self) -> None:
            # The listening socket defers handshakes so a slow client cannot
            # stall accept(); finish it here, in this request's thread.
            self.request.settimeout(self.timeout)
            self.request.do_handshake()
            super().setup()

        def _send(self, status: int, content_type: str, body: str) -> None:
            payload = body.encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self) -> None:  # noqa: N802
            snapshot = state.get(network)
            caller = find_caller(snapshot.peers, self.client_address[0])
            if caller is None:
                self._send(403, "text/plain; charset=utf-8", "unknown overlay peer\n")
                return
            peers = visible_peers(snapshot.peers, caller)
            path = self.path.split("?", 1)[0]
            if path == "/api/peers":
                body = json.dumps(
                    {"network": network, "caller": caller["name"], "peers": peers},
                    indent=2,
                )
                self._send(200, "application/json", body + "\n")
            elif path == "/":
                self._send(
                    200, "text/html; charset=utf-8", render_html(network, caller, peers)
                )
            else:
                self._send(404, "text/plain; charset=utf-8", "not found\n")

        def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
            pass

    return Handler


class Console:
    """Nebula's debug SSH console for one network, bound to localhost."""

    def __init__(
        self, ssh: str, key: Path, known_hosts: Path, user: str, port: int
    ) -> None:
        self.command = [
            ssh,
            "-F",
            "/dev/null",
            "-i",
            str(key),
            "-p",
            str(port),
            "-o",
            "BatchMode=yes",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            f"UserKnownHostsFile={known_hosts}",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "ConnectTimeout=5",
            f"{user}@127.0.0.1",
        ]

    def run(self, *args: str) -> str:
        return subprocess.run(
            [*self.command, " ".join(args)],
            check=True,
            capture_output=True,
            text=True,
            timeout=20,
        ).stdout


def serve(server: socketserver.BaseServer) -> None:
    threading.Thread(target=server.serve_forever, daemon=True).start()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())

    state_dir = Path(config["stateDir"])
    interval = config["pollInterval"]
    db = sqlite3.connect(state_dir / "registry.db")
    db.execute("PRAGMA journal_mode=WAL")
    registry = Registry(db, offline_after=interval * config["offlineAfterPolls"])
    state = State()
    tls_config = config.get("tls")

    tls = None
    if tls_config and Path(tls_config["certFile"]).exists():
        tls = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        tls.load_cert_chain(tls_config["certFile"], tls_config["keyFile"])
    elif tls_config:
        log(
            f"no certificate at {tls_config['certFile']}; HTTPS disabled until it exists"
        )

    consoles = {}
    for network, net in config["networks"].items():
        zone = Zone(net["domain"], net["address"], net.get("site"))
        dns_address = (net["address"], net.get("dnsPort", 53))
        serve(DnsUdpServer(dns_address, dns_handler(network, zone, state, tcp=False)))
        serve(DnsTcpServer(dns_address, dns_handler(network, zone, state, tcp=True)))
        if tls:
            https = HttpsServer(
                (net["address"], tls_config["port"]), https_handler(network, state)
            )
            https.socket = tls.wrap_socket(
                https.socket, server_side=True, do_handshake_on_connect=False
            )
            serve(https)
        consoles[network] = Console(
            config["ssh"],
            state_dir / "client_key",
            state_dir / "known_hosts",
            config["consoleUser"],
            net["consolePort"],
        )

    failing: set[str] = set()
    next_prune = 0.0
    while True:
        now = time.time()
        for network, console in consoles.items():
            try:
                observations = [parse_self(console.run("print-cert", "-json"))]
                observations += parse_hostmap(console.run("list-hostmap", "-json"))
            except (subprocess.SubprocessError, OSError, ValueError, KeyError) as error:
                if network not in failing:
                    detail = getattr(error, "stderr", None) or error
                    log(f"{network}: console poll failed: {str(detail).strip()}")
                    failing.add(network)
            else:
                if network in failing:
                    log(f"{network}: console poll recovered")
                    failing.discard(network)
                registry.record(network, observations, now)
            registry.sweep(network, now)
            peers = registry.peers(network)
            state.set(network, Snapshot(peers, dns_records(peers), int(now)))
        if now >= next_prune:
            registry.prune(now, config["eventRetentionDays"])
            next_prune = now + 3600
        time.sleep(max(0.0, interval - (time.time() - now)))


if __name__ == "__main__":
    main()
