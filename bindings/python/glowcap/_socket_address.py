"""Private socket-address spelling shared by transport adapters."""

from __future__ import annotations


def address_designator(host: str, port: int) -> str:
    """Render ``host:port``, bracketing IPv6 hosts."""
    if ":" in host and not (host.startswith("[") and host.endswith("]")):
        return f"[{host}]:{port}"
    return f"{host}:{port}"
