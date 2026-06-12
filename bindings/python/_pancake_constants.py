"""Private ABI constants for the Python pancake binding."""

OK = 0
ERR_INVALID_ARGUMENT = -3
WOULD_BLOCK = -7
ERR_CLOSED = -8
ERR_UNSUPPORTED_VALUE = -13
FRAME_SHAPE_BYTE = 0
EVENT_NONE = 0
EVENT_DELIVER = 1
EVENT_RESOLVE = 2

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
# Wire spelling of the empty locator hints in pancake_peer_start_session;
# mirrors PANCAKE_HINTS_EMPTY_MAP / PANCAKE_HINTS_EMPTY_FALSE in pancake.h.
HINTS_EMPTY_MAP = 0
HINTS_EMPTY_FALSE = 1

# The well-known bootstrap export position every OCapN peer answers `fetch`
# on; mirrors PANCAKE_BOOTSTRAP_POSITION in pancake.h.
BOOTSTRAP_POSITION = 0

# `captp_version` for pancake_peer_new_negotiated; mirrors
# PANCAKE_CAPTP_VERSION_* in pancake.h.
CAPTP_VERSION_V1_0 = 0
CAPTP_VERSION_PRE_SPEC = 1

# `codec` for pancake_peer_new_negotiated and the tcp endpoints; mirrors
# PANCAKE_CODEC_* in pancake.h.
CODEC_SYRUP = 0
CODEC_CAPNP = 1

# PancakeLastAbort.domain; mirrors PANCAKE_ABORT_DOMAIN_* in pancake.h.
ABORT_DOMAIN_CODEC = 0
ABORT_DOMAIN_SESSION = 1
ABORT_DOMAIN_FOREIGN = 2
