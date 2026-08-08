"""Assert pancake rejects malformed setup and honors pre-setup `op:abort`.

The upstream suite's `tests.op_start_session` module is the authority and
passes in full (crossed-hellos resolution included; the peer routes it through
the host's tiebreak). But its two `crossed_hellos` cases sort alphabetically
before the invalid-signature / invalid-version cases and each drives a real
enliven dial plus the suite's per-receive waits, consuming most of the
wrapper's 5s module cap. This probe drives the same two abort checks the
suite's `test_start_session_with_invalid_signature` and
`test_start_session_with_invalid_version` make, using the suite's own netlayer
and message types, so the orchestrator gates on them on a tight budget without
waiting out the crossed-hellos legs first.

The suite's `tests.op_abort` accepts timeout or clean EOF after sending more
data, but Linux reports a TCP reset when the peer closes with those extra bytes
unread. The pre-setup case here accepts the equivalent EOF/reset/broken-pipe
outcomes and rejects timeout: the check must observe that the connection was
actually severed.

Run under the same `uv` environment as `run.sh`; it adds the suite's `upstream/`
to `sys.path` itself, so it works from any cwd.

Port: `--port=N` or env `PANCAKE_OCAPN_CONFORMANCE_PORT` (default 22055), matching
`run-against-pancake.sh`.
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "upstream"))

from contrib.syrup import syrup_encode, Record, Symbol  # noqa: E402
from utils.ocapn_uris import OCapNPeer  # noqa: E402
from utils.captp_types import OpStartSession, OpAbort, CapTPPublicKey  # noqa: E402
from netlayers.testing_only_tcp import TestingOnlyTCPNetlayer  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402

CAPTP_VERSION = "1.0"
OBJECT_TO_FETCH = b"VMDDd1voKWarCe2GvgLbxbVFysNzRPzx"


def peer_url(port: int) -> str:
    return (
        "ocapn://JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ.tcp-testing-only"
        f"?host=127.0.0.1&port={port}"
    )


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


def case_pre_setup_abort(netlayer, uri):
    """An abort before setup must make a subsequent setup unusable."""
    remote = netlayer.connect(uri)
    remote.send_message(OpAbort("test-abort-before-setup"))
    try:
        remote.setup_session(CAPTP_VERSION)
        # The peer's hello may already be buffered before it reads our abort,
        # so setup can finish locally. The first operation must still prove the
        # connection unusable.
        remote.fetch_object(OBJECT_TO_FETCH)
    except (ConnectionAbortedError, ConnectionResetError, BrokenPipeError) as exc:
        return f"connection severed ({type(exc).__name__})"
    except TimeoutError as exc:
        raise AssertionError("pre-setup abort did not produce observable teardown") from exc
    finally:
        remote.close()
    raise AssertionError("session setup succeeded after pre-setup abort")


def main():
    parser = argparse.ArgumentParser(description="Handshake abort probe against pancake peer")
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("PANCAKE_OCAPN_CONFORMANCE_PORT", "22055")),
        help="TCP port of the running pancake-ocapn-peer (default: 22055 or env)",
    )
    args = parser.parse_args()
    uri = OCapNPeer.from_uri(peer_url(args.port))
    netlayer = TestingOnlyTCPNetlayer(uri.hints.get("host"))
    ok = True
    for name, fn in (
        ("invalid-signature", case_invalid_signature),
        ("invalid-version", case_invalid_version),
        ("pre-setup-abort", case_pre_setup_abort),
    ):
        try:
            result = fn(netlayer, uri)
            print(f"handshake-abort-probe: {name} -> {result!r}")
        except Exception as exc:  # noqa: BLE001 - the probe reports any failure as a gate failure
            ok = False
            print(f"handshake-abort-probe: {name} -> FAILED ({type(exc).__name__}: {exc})")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
