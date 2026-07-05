"""Private ABI constants for the Python pancake binding.

Each family mirrors its ``PANCAKE_*`` enum in ``pancake_ocapn.h``, and a
mirrored family is kept whole: a member that rounds out its enum (e.g.
``ENLIVEN_FRESH``, ``PROJECTION_FRAME``) stays even while no wrapper reads it,
the same posture the Rust ``abi_constants`` and Racket ``constants.rkt``
mirrors hold.
"""

OK = 0
ERR_INVALID_ARGUMENT = -3
WOULD_BLOCK = -7
ERR_CLOSED = -8
ERR_UNSUPPORTED_VALUE = -13
FRAME_SHAPE_BYTE = 0

REF_NEAR = 0
REF_FAR = 1
REF_PROMISE = 2
REF_STURDY = 3
REF_BROKEN = 4
REF_SUB_OBJECT = 0
REF_SUB_PROMISE = 1

ARG_INTEGER = 0
ARG_FLOAT64 = 1
ARG_BOOLEAN = 2
ARG_BYTES = 3
ARG_STRING = 4
ARG_SYMBOL = 5
ARG_VOID = 6
ARG_REFERENCE = 7
ARG_LIST = 8
ARG_SET = 9
ARG_TAGGED = 10
ARG_KEYWORD = 11
ARG_BIG_INTEGER = 12

RESOLUTION_FULFILL = 0
RESOLUTION_BREAK = 1
RESOLUTION_HANDOFF = 2

# PancakeAnyEvent.projection: which arm of the polled event is live; mirrors
# PANCAKE_PROJECTION_* in pancake_ocapn.h.
PROJECTION_DELIVER = 1
PROJECTION_RESOLVE = 2
PROJECTION_FRAME = 3

# PancakeNodeAction.kind: what the host must do next for the node's serve
# step; mirrors PANCAKE_NODE_ACTION_* in pancake_ocapn.h.
NODE_ACTION_DIAL = 1
NODE_ACTION_FLUSH = 2
NODE_ACTION_SETTLE = 3
NODE_ACTION_FAIL = 4
NODE_ACTION_NEED_GIFT_ID = 5

# pancake_node_claim_resolve outcome; mirrors PANCAKE_REDEEM_OUTCOME_* in
# pancake_ocapn.h.
REDEEM_OUTCOME_FAR = 0
REDEEM_OUTCOME_BROKEN = 1
REDEEM_OUTCOME_NOT_CAPABILITY = 2
# Wire spelling of the empty locator hints in pancake_peer_start_session;
# mirrors PANCAKE_HINTS_EMPTY_MAP / PANCAKE_HINTS_EMPTY_FALSE in pancake_ocapn.h.
HINTS_EMPTY_MAP = 0
HINTS_EMPTY_FALSE = 1

# `captp_version` for pancake_peer_new_negotiated; mirrors
# PANCAKE_CAPTP_VERSION_* in pancake_ocapn.h.
CAPTP_VERSION_V1_0 = 0
CAPTP_VERSION_PRE_SPEC = 1

# `codec` for pancake_peer_new_negotiated and the tcp endpoints; mirrors
# PANCAKE_CODEC_* in pancake_ocapn.h.
CODEC_SYRUP = 0
CODEC_CAPNP = 1

# PancakeEnlivenStart.status / pancake_peer_record_enlivenment outcome; mirrors
# PANCAKE_ENLIVEN_* in pancake_ocapn.h.
ENLIVEN_FRESH = 0
ENLIVEN_CACHED = 1
ENLIVEN_IN_FLIGHT = 2
ENLIVEN_OUTCOME_FULFILLED = 0
ENLIVEN_OUTCOME_BROKEN = 1

# The reserved redeemed-handoff-token far-id range (ADR-0066): far ids at or
# above this are node-minted tokens, never wire imports; mirrors
# PANCAKE_REDEEMED_TOKEN_BASE in pancake_ocapn.h.
REDEEMED_TOKEN_BASE = 1152921504606846976

# PancakeLastAbort.domain; mirrors PANCAKE_ABORT_DOMAIN_* in pancake_ocapn.h.
ABORT_DOMAIN_CODEC = 0
ABORT_DOMAIN_SESSION = 1
ABORT_DOMAIN_FOREIGN = 2
