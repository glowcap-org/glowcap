"""A KERI-shaped identity for the demo's Python caller.

The host will not attribute an Episode to an AID unless the caller can show that
its signing key belongs to that AID, so a caller needs more than a keypair: it
needs an inception event whose digest *is* its AID, a rotation that names the
event before it, and the log of both to hand over with the request. That is what
this module builds, matching ``zig/identity.zig`` field for field.

Ed25519 comes from PyNaCl. Blake3 lives in ``blake3.py`` because the standard
library does not carry it.
"""

from __future__ import annotations

import base64
from dataclasses import dataclass

from nacl.signing import SigningKey

from blake3 import blake3

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _coded(code: str, raw: bytes) -> str:
    """A CESR-shaped primitive: a one-character derivation code and 43 base64 chars."""
    return code + b64url(raw)


SAID_LEN = 44
SIG_LEN = 86

BLANK_SAID = "#" * SAID_LEN
BLANK_SIG = "#" * SIG_LEN


@dataclass(frozen=True)
class Signer:
    """One key this identity has held, and the coded verkey it goes by."""

    key: SigningKey

    @property
    def verkey(self) -> str:
        """The ``D``-coded verkey the host reads."""
        return _coded("D", bytes(self.key.verify_key))

    def sign(self, payload: str) -> bytes:
        """Sign ``payload``, returning the raw 64 signature bytes."""
        return self.key.sign(payload.encode()).signature


def _next_key_digest(next_key: SigningKey) -> str:
    """The next-key commitment.

    A digest over the key that will become current at the next rotation.
    Committing to it before it is ever exposed is pre-rotation.
    """
    return _coded("E", blake3(bytes(next_key.verify_key)))


def _said_of(draft: str) -> str:
    """The SAID of a key event: the digest of the event's own bytes.

    The fields the digest cannot cover are filled with placeholder runs. The event
    carries its own SAID, and a rotation carries a signature computed from that
    SAID, so both slots are blanked while the digest is taken. The host blanks the
    same two slots when it re-derives, which is how the two sides arrive at the
    same bytes.
    """
    return _coded("E", blake3(draft.encode()))


def _render_inception(said: str, verkey: str, next_digest: str) -> str:
    return (
        f'{{"v":"KERIa","t":"icp","d":"{said}","i":"{said}","s":"0",'
        f'"kt":"1","k":["{verkey}"],"nt":"1","n":["{next_digest}"]}}'
    )


def _render_rotation(
    said: str,
    aid: str,
    sn: int,
    prior: str,
    verkey: str,
    next_digest: str,
    sig: str,
) -> str:
    return (
        f'{{"v":"KERIa","t":"rot","d":"{said}","i":"{aid}","s":"{sn}",'
        f'"p":"{prior}","kt":"1","k":["{verkey}"],"nt":"1","n":["{next_digest}"],'
        f'"sig":"{sig}"}}'
    )


class Identity:
    """A KERI-anchored identity: an AID, the key that speaks for it now, the key
    it has committed to next, and the log of how it got here."""

    def __init__(self) -> None:
        """Incept: draw the current key and the pre-rotated next key, and derive the
        AID from the inception event that commits to both.

        The AID is the digest of that event, which is what makes it
        self-certifying: no registry says this key belongs to this identifier, the
        identifier is built out of it.
        """
        self.current = Signer(SigningKey.generate())
        self._next = SigningKey.generate()
        self._sn = 0
        self.retired: Signer | None = None

        next_digest = _next_key_digest(self._next)
        said = _said_of(_render_inception(BLANK_SAID, self.current.verkey, next_digest))
        self.aid = said
        self._said = said
        self._events = [_render_inception(said, self.current.verkey, next_digest)]

    def rotate(self) -> None:
        """Rotate: the committed next key becomes current, a fresh next key is drawn
        and committed, and the event recording it is signed by the key it retires.

        The retired key stays reachable so a caller can demonstrate that a host
        refuses it.
        """
        retiring = self.current
        new_current = Signer(self._next)
        new_next = SigningKey.generate()
        next_digest = _next_key_digest(new_next)

        prior = self._said
        self._sn += 1

        # Two passes: the first renders the draft, with the SAID and the signature
        # blanked, and hashes it; the second fills both in.
        said = _said_of(
            _render_rotation(
                BLANK_SAID,
                self.aid,
                self._sn,
                prior,
                new_current.verkey,
                next_digest,
                BLANK_SIG,
            )
        )
        # The rotation is signed by the key it retires, proving that the holder of
        # the old key authorized the handover. The SAID is a digest over every
        # other field, so signing these three commits to the whole event.
        sig = b64url(retiring.sign(f"{said}|{new_current.verkey}|{next_digest}"))

        self._events.append(
            _render_rotation(
                said,
                self.aid,
                self._sn,
                prior,
                new_current.verkey,
                next_digest,
                sig,
            )
        )
        self._next = new_next
        self._said = said
        self.retired = retiring
        self.current = new_current

    @property
    def kel(self) -> str:
        """The key event log as it goes on the wire: one JSON event per line."""
        return "\n".join(self._events) + "\n"
