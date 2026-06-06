#!/usr/bin/env python3
"""Query a TXT record over DNS-over-HTTPS (RFC 8484 wire format) against multiple
resolvers and require them to agree.

Usage:
    doh_query.py <name>

Resolvers are read from the DOH_RESOLVERS environment variable (newline- or
comma-separated list of DoH endpoint URLs). If unset, a built-in default list is
used (Google, Cloudflare, Quad9, ControlD).

On success (every resolver reachable AND all returning the same set of TXT
records) prints a JSON object to stdout:
    {"agree": true, "records": ["<txt1>", "<txt2>", ...], "resolvers": [...]}
The "records" are the raw TXT character-strings (one string per TXT RR, multiple
character-strings within an RR concatenated per RFC 1035). Order is sorted for
stable comparison.

If resolvers disagree or any resolver fails, prints {"agree": false, ...} with a
"reason" and exits non-zero.
"""

import json
import os
import struct
import subprocess
import sys

DEFAULT_RESOLVERS = [
    "https://dns.google/dns-query",
    "https://cloudflare-dns.com/dns-query",
    "https://dns.quad9.net/dns-query",
    "https://freedns.controld.com/p0",
]

TIMEOUT = 20


def build_query(name: str) -> bytes:
    """Build a minimal DNS query for <name> TXT (IN) with EDNS0 DO=1."""
    # Header: id=0, flags=0x0100 (RD), qd=1, an=0, ns=0, ar=1 (OPT)
    header = struct.pack(">HHHHHH", 0, 0x0100, 1, 0, 0, 1)
    qname = b""
    for label in name.rstrip(".").split("."):
        lb = label.encode("idna") if any(ord(c) > 127 for c in label) else label.encode("ascii")
        qname += struct.pack(">B", len(lb)) + lb
    qname += b"\x00"
    question = qname + struct.pack(">HH", 16, 1)  # TXT, IN
    # EDNS0 OPT: name=root, type=41, udpsize=4096, ext-rcode/flags with DO bit set
    opt = struct.pack(">B", 0) + struct.pack(">HHIH", 41, 4096, 0x00008000, 0)
    return header + question + opt


def parse_name(msg: bytes, off: int):
    """Parse a (possibly compressed) DNS name; return (next_offset)."""
    while True:
        if off >= len(msg):
            raise ValueError("name overruns message")
        length = msg[off]
        if length == 0:
            return off + 1
        if length & 0xC0 == 0xC0:
            return off + 2  # compression pointer terminates the name here
        off += 1 + length


def parse_txt_records(msg: bytes):
    """Return the list of TXT character-string payloads from the answer section."""
    if len(msg) < 12:
        raise ValueError("short DNS message")
    qd, an = struct.unpack(">HH", msg[4:8])
    off = 12
    for _ in range(qd):
        off = parse_name(msg, off)
        off += 4  # qtype + qclass
    records = []
    for _ in range(an):
        off = parse_name(msg, off)
        rtype, _rclass, _ttl, rdlen = struct.unpack(">HHIH", msg[off:off + 10])
        off += 10
        rdata = msg[off:off + rdlen]
        off += rdlen
        if rtype != 16:  # TXT
            continue
        # rdata is one or more <len><bytes> character-strings; concatenate them.
        s = b""
        i = 0
        while i < len(rdata):
            clen = rdata[i]
            s += rdata[i + 1:i + 1 + clen]
            i += 1 + clen
        records.append(s.decode("utf-8", "replace"))
    return records


def query(endpoint: str, name: str):
    wire = build_query(name)
    # RFC 8484 POST over HTTP/2 via curl (some resolvers, e.g. Quad9, require HTTP/2).
    proc = subprocess.run(
        [
            "curl", "-sS", "--http2", "--max-time", str(TIMEOUT),
            "--fail",
            "-H", "content-type: application/dns-message",
            "-H", "accept: application/dns-message",
            "-A", "verified-apps-doh/1",
            "--data-binary", "@-",
            endpoint,
        ],
        input=wire,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=TIMEOUT + 5,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"curl failed ({proc.returncode}): {proc.stderr.decode('utf-8', 'replace').strip()}")
    return parse_txt_records(proc.stdout)


def main():
    if len(sys.argv) != 2:
        print(json.dumps({"agree": False, "reason": "usage: doh_query.py <name>"}))
        return 2
    name = sys.argv[1]
    env = os.environ.get("DOH_RESOLVERS", "").replace(",", "\n")
    resolvers = [r.strip() for r in env.splitlines() if r.strip()] or DEFAULT_RESOLVERS

    sets = {}
    for r in resolvers:
        try:
            recs = sorted(set(query(r, name)))
        except Exception as exc:  # noqa: BLE001
            print(json.dumps({"agree": False, "reason": f"resolver {r} failed: {exc}", "resolvers": resolvers}))
            return 1
        sets[r] = recs

    first = sets[resolvers[0]]
    for r in resolvers[1:]:
        if sets[r] != first:
            print(json.dumps({
                "agree": False,
                "reason": "resolvers disagree",
                "resolvers": resolvers,
                "perResolver": sets,
            }))
            return 1

    print(json.dumps({"agree": True, "records": first, "resolvers": resolvers}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
