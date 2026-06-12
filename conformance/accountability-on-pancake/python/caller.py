"""Python caller for the accountability-on-pancake cross-seam demo.

Connects to a running Zig host, generates an Ed25519 identity with PyNaCl,
signs the request with the attestation preimage ``invoke|<request>``, and
invokes the Affordance capability. The host verifies the attestation and
returns an ack — or refuses an unattested call with a broken promise.

    python3 caller.py <port>

Or driven by the demo.ts orchestrator, which starts the Zig host first.
"""

from __future__ import annotations

import asyncio
import base64
import pathlib
import sys

# The binding lives in bindings/python; add it to the path.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "bindings" / "python"))

from nacl.signing import SigningKey  # noqa: E402
from pancake import VowBroken, connect  # noqa: E402


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


async def run(port: int) -> None:
    print("accountability-on-pancake python caller")
    print(f"  connecting to 127.0.0.1:{port}…")

    # `connect` completes the keyed op:start-session handshake before returning.
    conn = await connect("127.0.0.1", port)
    # `fetch`/`send` drive the inbound loop themselves — no separate serve() call.
    affordance = await conn.fetch("affordance")

    # Generate an Ed25519 identity (above pancake, like the Zig/Deno sides).
    signing_key = SigningKey.generate()
    verify_key = signing_key.verify_key
    pub_raw = bytes(verify_key)
    subject = "E" + b64url(pub_raw)
    verkey = "D" + b64url(pub_raw)

    print(f"  subject (AID): {subject}")

    # --- Legitimate invocation ------------------------------------------------
    request = "read-thermostat"
    preimage = f"invoke|{request}".encode()
    sig_raw = signing_key.sign(preimage).signature
    sig_b64 = b64url(sig_raw)

    print("  sending legitimate invoke…")
    result = await conn.send(affordance, "invoke", [subject, verkey, request, sig_b64])
    if not isinstance(result, str) or not result.startswith("ack:"):
        print(f"  FAIL: unexpected result: {result!r}", file=sys.stderr)
        sys.exit(1)
    print(f"  result: {result}")

    # --- Tampered invocation (should be refused) ------------------------------
    print("  sending tampered invoke (should be refused)…")
    bad_sig = bytearray(sig_raw)
    bad_sig[0] ^= 0xFF
    bad_sig_b64 = b64url(bytes(bad_sig))

    refused = False
    break_msg = ""
    try:
        await conn.send(affordance, "invoke", [subject, verkey, request, bad_sig_b64])
    except VowBroken as exc:
        refused = True
        break_msg = str(exc)

    if not refused:
        print("  FAIL: tampered invoke was NOT refused", file=sys.stderr)
        sys.exit(1)
    print(f"  correctly refused: {break_msg}")

    await conn.close()
    print("\naccountability-on-pancake python caller OK: same application, two languages.")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: caller.py <port>", file=sys.stderr)
        return 2
    port = int(sys.argv[1])
    try:
        asyncio.run(run(port))
        return 0
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
