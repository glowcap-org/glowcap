//! Private ABI constants mirrored from `pancake_ocapn.h` and `pancake_driver.h`.

#![allow(dead_code)]

use core::ffi::{c_int, c_uint};

/// `codec` for `pancake_host_new` and the tcp endpoints; mirrors
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

/// `PancakeHostAction.kind`: what the embedder must do next for the byte-fed
/// host; mirrors `PANCAKE_HOST_ACTION_*` in `pancake_driver.h`.
pub const HOST_ACTION_DIAL: c_uint = 0;
pub const HOST_ACTION_FLUSH: c_uint = 1;
pub const HOST_ACTION_NEED_GIFT_ID: c_uint = 2;
pub const HOST_ACTION_SETTLE: c_uint = 3;
pub const HOST_ACTION_FAIL: c_uint = 4;
pub const HOST_ACTION_CLOSE: c_uint = 5;

/// The reserved node-unique token far-id range (ADR-0069): far ids at or
/// above this are host-minted tokens the application holds — the ids the GC
/// death rite tracks — never raw wire imports; mirrors
/// `PANCAKE_REDEEMED_TOKEN_BASE` in `pancake_ocapn.h`.
pub const REDEEMED_TOKEN_BASE: u64 = 1152921504606846976;

/// `PancakeLastAbort.domain`; mirrors `PANCAKE_ABORT_DOMAIN_*` in `pancake_ocapn.h`.
pub const ABORT_DOMAIN_CODEC: c_uint = 0;
pub const ABORT_DOMAIN_SESSION: c_uint = 1;
pub const ABORT_DOMAIN_FOREIGN: c_uint = 2;
