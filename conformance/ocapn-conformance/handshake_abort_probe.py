"""Assert the pancake peer aborts a malformed `op:start-session` handshake.

The upstream suite's `tests.op_start_session` module is the authority, but its
two `crossed_hellos` cases sort alphabetically before the invalid-signature /
invalid-version cases and block on the suite's per-receive timeout (crossed-hellos
mitigation is a separate, unimplemented gap). This probe drives the same two
checks the suite's `test_start_session_with_invalid_signature` and
`test_start_session_with_invalid_version` make — using the suite's own netlayer
and message types — so the orchestrator can gate on them without waiting out the
crossed-hellos timeouts.

Run under the same `uv` environment as `run.sh`; it adds the suite's `upstream/`
to `sys.path` itself, so it works from any cwd.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "upstream"))

from contrib.syrup import syrup_encode, Record, Symbol  # noqa: E402
from utils.ocapn_uris import OCapNPeer  # noqa: E402
from utils.captp_types import OpStartSession, OpAbort, CapTPPublicKey  # noqa: E402
from netlayers.testing_only_tcp import TestingOnlyTCPNetlayer  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402

URL = "ocapn://JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ.tcp-testing-only?host=127.0.0.1&port=22055"
CAPTP_VERSION = "1.0"


def case_invalid_signature(netlayer, uri):
    """A valid key + location, but the signature covers the wrong bytes."""
    remote = netlayer.connect(uri)
    private_key = Ed25519PrivateKey.generate()
    public_key = CapTPPublicKey.from_private_key(private_key)
    location = netlayer.location
    invalid_location_sig = private_key.sign(b"i am invalid")
    remote.send_message(OpStartSession(CAPTP_VERSION, public_key, location, invalid_location_sig))
    abort = remote.expect_message_type(OpAbort)
    remote.close()
    return abort


def case_invalid_version(netlayer, uri):
    """A correctly-signed location, but an unrecognized captp-version."""
    remote = netlayer.connect(uri)
    private_key = Ed25519PrivateKey.generate()
    public_key = CapTPPublicKey.from_private_key(private_key)
    location = netlayer.location
    location_sig = private_key.sign(
        syrup_encode(Record(Symbol("my-location"), [location.to_syrup_record()]))
    )
    remote.send_message(OpStartSession("invalid-version-number", public_key, location, location_sig))
    abort = remote.expect_message_type(OpAbort)
    remote.close()
    return abort


def main():
    uri = OCapNPeer.from_uri(URL)
    netlayer = TestingOnlyTCPNetlayer(uri.hints.get("host"))
    ok = True
    for name, fn in (
        ("invalid-signature", case_invalid_signature),
        ("invalid-version", case_invalid_version),
    ):
        try:
            abort = fn(netlayer, uri)
            print(f"handshake-abort-probe: {name} -> pancake aborted: {abort!r}")
        except Exception as exc:  # noqa: BLE001 - the probe reports any failure as a gate failure
            ok = False
            print(f"handshake-abort-probe: {name} -> FAILED ({type(exc).__name__}: {exc})")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
