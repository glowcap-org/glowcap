//! Private ABI constants mirrored from `pancake_ocapn.h`.

#![allow(dead_code)]

use core::ffi::{c_int, c_uint};

/// `codec` for `pancake_peer_new_negotiated` and the tcp endpoints; mirrors
/// `PANCAKE_CODEC_*` in `pancake_ocapn.h`.
pub const CODEC_SYRUP: c_uint = 0;
pub const CODEC_CAPNP: c_uint = 1;

pub const ERR_NULL_POINTER: c_int = -1;
// -2 retired (was ERR_INVALID_HANDLE); the value is never reused.
pub const ERR_INVALID_ARGUMENT: c_int = -3;
pub const ERR_SESSION: c_int = -4;
pub const ERR_CODEC: c_int = -5;
pub const ERR_INTERNAL: c_int = -6;
pub const ERR_CLOSED: c_int = -8;
pub const ERR_IO: c_int = -9;
pub const ERR_MALFORMED: c_int = -10;
pub const ERR_FRAME_TOO_LARGE: c_int = -11;
// -12 retired (was ERR_WRONG_EVENT); the value is never reused.
pub const ERR_UNSUPPORTED_VALUE: c_int = -13;
pub const ERR_BROKEN: c_int = -14;
pub const ERR_NOT_FOUND: c_int = -15;

pub const OK: c_int = 0;
pub const WOULD_BLOCK: c_int = -7;
pub const FRAME_SHAPE_BYTE: c_uint = 0;

pub const EVENT_NONE: c_int = 0;
pub const EVENT_DELIVER: c_int = 1;
pub const EVENT_RESOLVE: c_int = 2;
pub const EVENT_GC_EXPORT: c_int = 3;
pub const EVENT_GC_ANSWER: c_int = 4;
pub const EVENT_HANDOFF: c_int = 5;
pub const EVENT_START_SESSION: c_int = 6;
pub const EVENT_ABORT: c_int = 7;
pub const EVENT_LISTEN: c_int = 8;
pub const EVENT_GET: c_int = 9;
pub const EVENT_INDEX: c_int = 10;
pub const EVENT_UNTAG: c_int = 11;

pub const REF_NEAR: c_uint = 0;
pub const REF_FAR: c_uint = 1;
pub const REF_PROMISE: c_uint = 2;
pub const REF_STURDY: c_uint = 3;
pub const REF_BROKEN: c_uint = 4;
pub const REF_SUB_OBJECT: c_uint = 0;
pub const REF_SUB_PROMISE: c_uint = 1;

pub const ARG_INTEGER: c_uint = 0;
pub const ARG_FLOAT64: c_uint = 1;
pub const ARG_BOOLEAN: c_uint = 2;
pub const ARG_BYTES: c_uint = 3;
pub const ARG_STRING: c_uint = 4;
pub const ARG_SYMBOL: c_uint = 5;
pub const ARG_VOID: c_uint = 6;
pub const ARG_REFERENCE: c_uint = 7;
pub const ARG_LIST: c_uint = 8;
pub const ARG_SET: c_uint = 9;
pub const ARG_TAGGED: c_uint = 10;
pub const ARG_KEYWORD: c_uint = 11;
pub const ARG_BIG_INTEGER: c_uint = 12;

pub const RESOLUTION_FULFILL: c_uint = 0;
pub const RESOLUTION_BREAK: c_uint = 1;
pub const RESOLUTION_HANDOFF: c_uint = 2;

/// `PancakeAnyEvent.projection`: which arm of a polled event is live; mirrors
/// `PANCAKE_PROJECTION_*` in `pancake_ocapn.h`.
pub const PROJECTION_NONE: c_uint = 0;
pub const PROJECTION_DELIVER: c_uint = 1;
pub const PROJECTION_RESOLVE: c_uint = 2;
pub const PROJECTION_FRAME: c_uint = 3;

/// `PancakeNodeAction.kind`: what the host must do next for the node's serve
/// step; mirrors `PANCAKE_NODE_ACTION_*` in `pancake_ocapn.h`.
pub const NODE_ACTION_DIAL: c_uint = 1;
pub const NODE_ACTION_FLUSH: c_uint = 2;
pub const NODE_ACTION_SETTLE: c_uint = 3;
pub const NODE_ACTION_FAIL: c_uint = 4;
pub const NODE_ACTION_NEED_GIFT_ID: c_uint = 5;

/// `pancake_node_claim_resolve` outcome; mirrors `PANCAKE_REDEEM_OUTCOME_*` in
/// `pancake_ocapn.h`.
pub const REDEEM_OUTCOME_FAR: c_uint = 0;
pub const REDEEM_OUTCOME_BROKEN: c_uint = 1;
pub const REDEEM_OUTCOME_NOT_CAPABILITY: c_uint = 2;

/// Wire spelling of the empty locator hints in `pancake_peer_start_session`;
/// mirrors `PANCAKE_HINTS_EMPTY_MAP` / `PANCAKE_HINTS_EMPTY_FALSE` in `pancake_ocapn.h`.
pub const HINTS_EMPTY_MAP: c_uint = 0;
pub const HINTS_EMPTY_FALSE: c_uint = 1;

/// The well-known bootstrap export position every OCapN peer answers `fetch`
/// on; mirrors `PANCAKE_BOOTSTRAP_POSITION` in `pancake_ocapn.h`.
pub const BOOTSTRAP_POSITION: u64 = 0;

/// The reserved redeemed-handoff-token far-id range (ADR-0066): far ids at or
/// above this are node-minted tokens, never wire imports; mirrors
/// `PANCAKE_REDEEMED_TOKEN_BASE` in `pancake_ocapn.h`.
pub const REDEEMED_TOKEN_BASE: u64 = 1152921504606846976;

/// `captp_version` for `pancake_peer_new_negotiated`; mirrors
/// `PANCAKE_CAPTP_VERSION_*` in `pancake_ocapn.h`.
pub const CAPTP_VERSION_V1_0: c_uint = 0;
pub const CAPTP_VERSION_PRE_SPEC: c_uint = 1;

/// `PancakeEnlivenStart.status` / `pancake_peer_record_enlivenment` outcome;
/// mirrors `PANCAKE_ENLIVEN_*` in `pancake_ocapn.h`.
pub const ENLIVEN_FRESH: c_uint = 0;
pub const ENLIVEN_CACHED: c_uint = 1;
pub const ENLIVEN_IN_FLIGHT: c_uint = 2;
pub const ENLIVEN_OUTCOME_FULFILLED: c_uint = 0;
pub const ENLIVEN_OUTCOME_BROKEN: c_uint = 1;

/// `PancakeLastAbort.domain`; mirrors `PANCAKE_ABORT_DOMAIN_*` in `pancake_ocapn.h`.
pub const ABORT_DOMAIN_CODEC: c_uint = 0;
pub const ABORT_DOMAIN_SESSION: c_uint = 1;
pub const ABORT_DOMAIN_FOREIGN: c_uint = 2;
