// Private ABI constants for the Deno pancake binding.

export const OK = 0;
export const INVALID_ARGUMENT = -3;
export const WOULD_BLOCK = -7;
export const CLOSED = -8;
export const UNSUPPORTED_VALUE = -13;
export const BROKEN = -14;
export const FRAME_SHAPE_BYTE = 0;
export const EVENT_NONE = 0;
export const EVENT_DELIVER = 1;
export const EVENT_RESOLVE = 2;

export const REF_NEAR = 0;
export const REF_FAR = 1;
export const REF_PROMISE = 2;
export const REF_STURDY = 3;
export const REF_BROKEN = 4;
export const REF_SUB_OBJECT = 0;
export const REF_SUB_PROMISE = 1;

export const ARG_INTEGER = 0;
export const ARG_FLOAT64 = 1;
export const ARG_BOOLEAN = 2;
export const ARG_BYTES = 3;
export const ARG_STRING = 4;
export const ARG_SYMBOL = 5;
export const ARG_VOID = 6;
export const ARG_REFERENCE = 7;
export const ARG_LIST = 8;
export const ARG_SET = 9;
export const ARG_TAGGED = 10;
export const ARG_KEYWORD = 11;
export const ARG_BIG_INTEGER = 12;

export const RESOLUTION_FULFILL = 0;
export const RESOLUTION_BREAK = 1;

// Wire spelling of the empty locator hints in pancake_peer_start_session;
// mirrors PANCAKE_HINTS_EMPTY_MAP / PANCAKE_HINTS_EMPTY_FALSE in pancake.h.
export const HINTS_EMPTY_MAP = 0;
export const HINTS_EMPTY_FALSE = 1;

// The well-known bootstrap export position every OCapN peer answers `fetch`
// on; mirrors PANCAKE_BOOTSTRAP_POSITION in pancake.h.
export const BOOTSTRAP_POSITION = 0n;

// `captp_version` for pancake_peer_new_negotiated; mirrors
// PANCAKE_CAPTP_VERSION_* in pancake.h.
export const CAPTP_VERSION_V1_0 = 0;
export const CAPTP_VERSION_PRE_SPEC = 1;

// `codec` for pancake_peer_new_negotiated and the tcp endpoints; mirrors
// PANCAKE_CODEC_* in pancake.h.
export const CODEC_SYRUP = 0;
export const CODEC_CAPNP = 1;

// PancakeLastAbort.domain; mirrors PANCAKE_ABORT_DOMAIN_* in pancake.h.
export const ABORT_DOMAIN_CODEC = 0;
export const ABORT_DOMAIN_SESSION = 1;
export const ABORT_DOMAIN_FOREIGN = 2;

export const ARG_SIZE = 72; // sizeof(PancakeArgument), LP64
export const REF_SIZE = 16;
