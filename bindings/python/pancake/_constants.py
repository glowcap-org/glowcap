"""Private ABI constants for the Python pancake binding.

Each family mirrors its ``PANCAKE_*`` enum in ``pancake_ocapn.h`` (the
``HOST_ACTION_*`` family mirrors ``pancake_driver.h``), and a mirrored family
is kept whole: a member that rounds out its enum stays even while no wrapper
reads it, the same posture the Rust ``abi_constants`` and Racket
``constants.rkt`` mirrors hold.
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

# PancakeHostAction.kind: what the embedder must do next for the byte-fed host
# (ADR-0072); mirrors PANCAKE_HOST_ACTION_* in pancake_driver.h.
HOST_ACTION_DIAL = 0
HOST_ACTION_FLUSH = 1
HOST_ACTION_NEED_GIFT_ID = 2
HOST_ACTION_SETTLE = 3
HOST_ACTION_FAIL = 4
HOST_ACTION_CLOSE = 5

# `codec` for pancake_host_new and the tcp/inproc endpoints; mirrors
# PANCAKE_CODEC_* in pancake_ocapn.h.
CODEC_SYRUP = 0
CODEC_CAPNP = 1

# The reserved fetched-capability token far-id range (ADR-0069): far ids at or
# above this are node-minted tokens the host routes to their home connection,
# never wire imports; mirrors PANCAKE_REDEEMED_TOKEN_BASE in pancake_ocapn.h.
REDEEMED_TOKEN_BASE = 1152921504606846976

# PancakeLastAbort.domain; mirrors PANCAKE_ABORT_DOMAIN_* in pancake_ocapn.h.
ABORT_DOMAIN_CODEC = 0
ABORT_DOMAIN_SESSION = 1
ABORT_DOMAIN_FOREIGN = 2
