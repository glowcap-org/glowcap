"""Python caller for the accountability-on-glowcap cross-seam demo.

Connects to a running Zig host, builds a KERI-anchored identity with a real key
event log (``identity.py``), rotates it once, then invokes the Affordance capability:
it signs the attestation preimage ``invoke|<subject>|<request>`` and hands over
the log that binds its signing key to the AID it claims. Three paths are
exercised, because all three are the contract:

* a legitimate invocation, which the host attests, binds, and acks;
* a corrupted signature, which the host cannot attest;
* a key the log has already rotated away from, which the host can attest but will
  not bind to the claimed AID.

    python3 caller.py <port>

Or driven by the demo.ts orchestrator, which starts the Zig host first.
"""

from __future__ import annotations

import asyncio
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "_demo"))
from python_path import add_bindings_path  # noqa: E402

add_bindings_path()

from identity import Identity, b64url  # noqa: E402
from glowcap import Runtime, VowBroken, tcp  # noqa: E402

async def run(port: int) -> None:
    print("accountability-on-glowcap python caller")
    print(f"  connecting to 127.0.0.1:{port}…")

    # `connect` completes the keyed op:start-session handshake before returning.
    runtime = await Runtime.open(provider=tcp.provider())
    session = await runtime.connect(tcp.locator("127.0.0.1", port))
    # `fetch`/`send` drive the inbound loop themselves, no separate serve() call.
    affordance = await session.fetch("affordance")

    # Incept an identity above glowcap, like the Zig/Deno sides, then rotate it
    # once so the log the host reads is a chain and not a lone inception event.
    caller = Identity()
    caller.rotate()
    retired = caller.retired
    if retired is None:
        print("  FAIL: rotation left no retired key", file=sys.stderr)
        sys.exit(1)

    print(f"  subject (AID): {caller.aid}")

    # --- Legitimate invocation ------------------------------------------------
    request = "read-thermostat"
    # The subject is in the signed bytes so the host can tell that this caller
    # really is claiming this AID, and not borrowing someone else's. The log rides
    # alongside so the host can check that this key speaks for that AID.
    preimage = f"invoke|{caller.aid}|{request}"
    sig_raw = caller.current.sign(preimage)

    print("  sending legitimate invoke…")
    result = await session.send(
        affordance,
        "invoke",
        [caller.aid, caller.current.verkey, request, b64url(sig_raw), caller.kel],
    )
    if not isinstance(result, str) or not result.startswith("ack:"):
        print(f"  FAIL: unexpected result: {result!r}", file=sys.stderr)
        sys.exit(1)
    print(f"  result: {result}")

    # --- Tampered signature (should be refused) -------------------------------
    print("  sending tampered invoke (should be refused)…")
    bad_sig = bytearray(sig_raw)
    bad_sig[0] ^= 0xFF

    tampered = await refusal(
        session,
        affordance,
        [caller.aid, caller.current.verkey, request, b64url(bytes(bad_sig)), caller.kel],
    )
    if tampered is None:
        print("  FAIL: tampered invoke was NOT refused", file=sys.stderr)
        sys.exit(1)
    print(f"  correctly refused: {tampered}")

    # --- Retired key (should be refused) --------------------------------------
    # This signature is genuine: the caller really held this key, and it really
    # signed this subject and request. What fails is the binding, because the log
    # the caller hands over rotated past that key.
    print("  sending invoke signed by a retired key (should be refused)…")
    stale = await refusal(
        session,
        affordance,
        [caller.aid, retired.verkey, request, b64url(retired.sign(preimage)), caller.kel],
    )
    if stale is None:
        print("  FAIL: a retired pre-rotation key was NOT refused", file=sys.stderr)
        sys.exit(1)
    print(f"  correctly refused: {stale}")

    await session.close()
    await runtime.close()
    print("\naccountability-on-glowcap python caller OK: same application, two languages.")


async def refusal(session, affordance, args) -> str | None:
    """Invoke expecting a broken promise; the reason, or None if it settled."""
    try:
        await session.send(affordance, "invoke", args)
    except VowBroken as exc:
        return str(exc)
    return None


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
