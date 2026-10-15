#!/usr/bin/env python3
"""One bounded WSS or refusal TCP fixture for the relay TLS carrier."""

from __future__ import annotations

import argparse
import base64
import hashlib
import os
import socket
import ssl
from pathlib import Path


def upgrade(conn: ssl.SSLSocket) -> None:
    request = bytearray()
    while b"\r\n\r\n" not in request:
        chunk = conn.recv(4096)
        if not chunk:
            raise RuntimeError("client closed before the WebSocket upgrade")
        request.extend(chunk)
        if len(request) > 64 * 1024:
            raise RuntimeError("WebSocket upgrade exceeded fixture bound")

    headers: dict[bytes, bytes] = {}
    lines = bytes(request).split(b"\r\n")
    if not lines[0].startswith(b"GET /relay?"):
        raise RuntimeError(f"unexpected request target: {lines[0]!r}")
    for line in lines[1:]:
        if b":" not in line:
            continue
        name, value = line.split(b":", 1)
        headers[name.strip().lower()] = value.strip()
    key = headers.get(b"sec-websocket-key")
    if key is None:
        raise RuntimeError("missing Sec-WebSocket-Key")
    accept = base64.b64encode(
        hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest()
    )
    conn.sendall(
        b"HTTP/1.1 101 Switching Protocols\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n"
        b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n"
    )


def recv_exact(conn: ssl.SSLSocket, length: int) -> bytes:
    value = bytearray()
    while len(value) != length:
        chunk = conn.recv(length - len(value))
        if not chunk:
            raise RuntimeError(f"stream ended after {len(value)} of {length} bytes")
        value.extend(chunk)
    return bytes(value)


def clean_close(conn: ssl.SSLSocket) -> None:
    header = recv_exact(conn, 2)
    if header[0] != 0x88 or header[1] != 0x80:
        raise RuntimeError(f"expected one masked empty WebSocket close: {header!r}")
    recv_exact(conn, 4)
    conn.sendall(b"\x88\x00")
    try:
        raw = conn.unwrap()
    except BrokenPipeError:
        # `unwrap` only reaches its reply write after accepting the peer's
        # close-notify. Glowcap owns a one-way TLS shutdown barrier and may
        # retire the TCP leg immediately after that record is delivered.
        # Keep SSLEOFError fatal: an unnotified/truncated peer must not pass.
        conn.close()
        return
    raw.close()


def tls_context(args: argparse.Namespace) -> ssl.SSLContext:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.cert, args.key)
    if args.mode in {"sni-refusal", "peer-alert"}:
        alert = (
            ssl.ALERT_DESCRIPTION_UNRECOGNIZED_NAME
            if args.mode == "sni-refusal"
            else ssl.ALERT_DESCRIPTION_ACCESS_DENIED
        )

        def refuse_sni(
            _socket: ssl.SSLSocket,
            _server_name: str | None,
            _context: ssl.SSLContext,
        ) -> int:
            return alert

        context.set_servername_callback(refuse_sni)
    return context


def serve_one(raw: socket.socket, args: argparse.Namespace) -> None:
    if args.mode == "malformed":
        raw.sendall(b"this is not a TLS record\r\n")
        return

    context = tls_context(args)
    expected_refusal = args.mode in {
        "tls-refusal",
        "sni-refusal",
        "peer-alert",
    }
    try:
        conn = context.wrap_socket(raw, server_side=True)
    except ssl.SSLError:
        if expected_refusal:
            return
        raise
    if expected_refusal:
        conn.close()
        raise RuntimeError(f"{args.mode} unexpectedly completed its TLS handshake")
    if args.mode == "abrupt":
        upgrade(conn)
        os.close(conn.detach())
        return
    if args.mode == "clean-close":
        upgrade(conn)
        clean_close(conn)
        return
    with conn:
        upgrade(conn)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        choices=(
            "upgrade",
            "clean-close",
            "tls-refusal",
            "sni-refusal",
            "peer-alert",
            "malformed",
            "abrupt",
        ),
        required=True,
    )
    parser.add_argument("--cert")
    parser.add_argument("--key")
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()
    if args.mode != "malformed" and (args.cert is None or args.key is None):
        parser.error(f"{args.mode} requires --cert and --key")

    with socket.create_server(("127.0.0.1", 0)) as listener:
        listener.settimeout(15)
        port_file = Path(args.port_file)
        temporary = port_file.with_suffix(".tmp")
        temporary.write_text(str(listener.getsockname()[1]), encoding="ascii")
        temporary.replace(port_file)
        raw, _ = listener.accept()
        raw.settimeout(10)
        with raw:
            serve_one(raw, args)


if __name__ == "__main__":
    main()
