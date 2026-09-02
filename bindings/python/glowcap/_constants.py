"""Private constants for the Python glowcap binding.

Reflected ABI constants, model-owned transport vocabulary, and shared binding
policy are generated into ``_constants_gen`` and re-exported here. ``zig build
gen-binding-constants-check`` rejects stale mirrors. ``HOST_ACTION_*`` lives in
the generated ``_host_action_gen`` module.

:class:`DurableProvenance` lives here too, beside the
``DURABLE_PROVENANCE_*`` integers it names. Two surfaces read the same fact
about the same partner -- :meth:`Session.partner_identity` and the live trace
-- and the session layer is not the authority for a value the trace producer
also needs, so putting it in the session module would make the trace import
the whole session layer.
"""

import enum

from ._constants_gen import *  # noqa: F401,F403
from ._constants_gen import (
    DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT,
    DURABLE_PROVENANCE_UNAUTHENTICATED,
)


class DurableProvenance(enum.Enum):
    """How a partner's advertised durable identity was authenticated, the third
    fact :class:`PartnerIdentity` reports beside session key and designator
    (ADR-0097, ADR-0105).

    The answer is a property of the connection rather than of its transport
    name. The same transport symbol reaches this peer over code that can prove
    something and code that cannot, so no list of transports belongs here.

    ``AUTHENTICATED_TRANSPORT`` means the code that realized this connection
    verified the far end of the byte channel holds a durable key, and the
    partner claimed that same key. ``UNAUTHENTICATED`` means no durable identity was
    proved: an address transport designates a socket address rather than a key,
    and a partner that advertised an address on a key transport claimed no
    durable identity.
    """

    AUTHENTICATED_TRANSPORT = DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT
    UNAUTHENTICATED = DURABLE_PROVENANCE_UNAUTHENTICATED

    @property
    def spoken(self) -> str:
        """This provenance as the trace records spell it.

        The trace reports the same provenance fact about the same partner as
        :meth:`Session.partner_identity`, so the spelling lives here once
        rather than at each surface that says it.
        """
        return _SPOKEN[self]


_SPOKEN = {
    DurableProvenance.AUTHENTICATED_TRANSPORT: "authenticated-transport",
    DurableProvenance.UNAUTHENTICATED: "unauthenticated",
}


def _provenance_from_abi(raw: int) -> DurableProvenance:
    """The enum named by a C ``provenance`` word.

    Unknown values are ABI failures; they must not be weakened into an
    unauthenticated claim, which is a real and distinct native fact.
    """
    try:
        return DurableProvenance(raw)
    except ValueError as error:
        raise ValueError(
            f"glowcap ABI returned unknown durable provenance {raw}"
        ) from error


# Cycle break message when a local Forward chain exceeds the hop cap.
FORWARD_CYCLE_MESSAGE = "forward cycle: the local forward chain never terminates"

# How long a partner has to finish the keyed handshake once its byte channel is
# open. The value itself is the C ABI's (``GLOWCAP_HANDSHAKE_TIMEOUT_MS``),
# arriving through the generated re-export above, so the four bindings promise
# one number rather than four. Something finite is the point: this project's
# rule for CapTP waits is that an unbounded one is a hang rather than a slow
# success, and a dialer inherits that from every peer it reaches just as a
# listener does from every partner it accepts.
