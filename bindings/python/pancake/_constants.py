"""Private ABI constants for the Python pancake binding.

The reflected integer families (return codes, reference and argument kinds,
codec, abort domains, the dial plan, and the caps) are generated into
``_constants_gen`` from the C ABI and re-exported here, so a value is mirrored
once and ``zig build gen-binding-constants-check`` rejects a stale copy. This
module adds the transport string symbols, which mirror ``model.transport`` (a
different authority, guarded by ``meta-check`` name-presence) rather than a
``pancake_*.h`` value. ``HOST_ACTION_*`` lives in the generated
``_host_action_gen`` module.
"""

from ._constants_gen import *  # noqa: F401,F403

# Cycle break message when a local Forward chain exceeds the hop cap.
FORWARD_CYCLE_MESSAGE = "forward cycle: the local forward chain never terminates"

# Locator hint name for dial addresses when the designator is a key
# (keyed-tcp, iroh); mirrors model.transport.hint_direct_addresses.
HINT_DIRECT_ADDRESSES = "direct-addresses"

# OCapN transport symbols; mirrors model.transport.*.
TRANSPORT_TCP = "tcp"
TRANSPORT_KEYED_TCP = "keyed-tcp"
TRANSPORT_INPROC = "inproc"
TRANSPORT_IROH = "iroh"
