"""Per-binding keyed-relay rendezvous proof: the Python binding cold-dials a
non-listening peer by its key designator through the reference relay's
rendezvous bridge (ADR-0088). The core classifies the locator as the
``rendezvous`` dial shape; the binding opens the WebSocket leg the locator's
``rendezvous-relay`` hint names, the one rendezvous routing authority.

Run via ``zig build python-keyed-relay-rendezvous`` (the harness passes
``<locator>``). Needs the optional ``websockets`` extra, which
the build step supplies from ``bindings/python/uv.lock``.
"""

from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "interop" / "_common" / "python"))
from helpers import fail, insert_bindings_path  # noqa: E402

insert_bindings_path()

from pancake import CarrierPhase, Host, PancakeError, Runtime, parse_locator  # noqa: E402
from pancake.relay import RelayConfig, connector, keyed, provider  # noqa: E402


async def expect_native_refusal(partner, route: str, trust_pem: bytes | None, cause: str) -> None:
    async with Runtime.open(
        provider=provider(RelayConfig(route, trust_pem=trust_pem))
    ) as runtime:
        refused: PancakeError | None = None
        session = None
        try:
            session = await runtime.connect(keyed.locator(partner.designator, route))
        except PancakeError as error:
            refused = error
        if session is not None:
            await session.close()
            fail("keyed-relay-rendezvous", f"native WSS unexpectedly accepted {cause}")
        if refused is None:
            fail("keyed-relay-rendezvous", f"native WSS did not return {cause}")
        carrier = refused.carrier_failure
        if (
            carrier is None
            or carrier.phase is not CarrierPhase.SECURE_HANDSHAKE
            or carrier.verification_flags == 0
        ):
            fail(
                "keyed-relay-rendezvous",
                f"native WSS omitted secure-handshake verification detail: {refused}",
            )
        if cause not in str(refused):
            fail(
                "keyed-relay-rendezvous",
                f"native WSS reported {refused!s}, expected {cause}",
            )


async def main() -> None:
    if len(sys.argv) < 2:
        fail("keyed-relay-rendezvous", "usage: python_client.py <locator>")
    locator = sys.argv[-1]
    partner = parse_locator(locator)
    native_relay_url = os.environ.get("PANCAKE_PROOF_NATIVE_RELAY_URL")
    native_ca_file = os.environ.get("PANCAKE_PROOF_NATIVE_RELAY_CA_FILE")

    host = Host()
    if native_relay_url is None:
        transport = {"connector": connector("ws://127.0.0.1:1/relay")}
    else:
        if native_ca_file is None:
            fail(
                "keyed-relay-rendezvous",
                "native WSS proof needs PANCAKE_PROOF_NATIVE_RELAY_CA_FILE",
            )
        pem = Path(native_ca_file).read_bytes()
        wrong_host = native_relay_url.replace("//localhost:", "//127.0.0.1:", 1)
        await expect_native_refusal(partner, wrong_host, pem, "CertificateNameMismatch")
        await expect_native_refusal(partner, native_relay_url, None, "CertificateUntrusted")
        transport = {
            "provider": provider(RelayConfig(native_relay_url, trust_pem=pem))
        }
    async with Runtime.open(
        **transport,
        adopt_host=host,
    ) as runtime:
        session = await runtime.connect(partner)
        try:
            greeter = await session.fetch("greeter")
            reply = await session.send(greeter, "greet", ["python"])
            expected = "hello python, cold-dialed by rendezvous"
            if reply != expected:
                fail("keyed-relay-rendezvous", f"unexpected greeting: {reply!r}")
        finally:
            await session.close()
    print(
        "PASS: the Python binding cold-dialed a registered peer by rendezvous — "
        "the locator's rendezvous-relay route carried the dial "
        "and the keyed session answered"
    )


asyncio.run(main())
