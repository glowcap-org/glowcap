/**
 * constants.ts — the `PANCAKE_*` ABI vocabulary, mirrored from the C
 * headers (`pancake_abi.h`, `pancake.h`, `pancake_net_tcp.h`).
 *
 * The Rust enums are the source of truth; if these drift, the typed
 * accessors lie. Each block cites the header that defines it.
 */

// ─── Return codes (pancake_abi.h) ──────────────────────────────────
export const PANCAKE_OK = 0;
export const PANCAKE_ERR_NULL_POINTER = -1;
export const PANCAKE_ERR_INVALID_HANDLE = -2;
export const PANCAKE_ERR_PEER_CLOSED = -3;
export const PANCAKE_ERR_SESSION = -4;
export const PANCAKE_ERR_CODEC = -5;
export const PANCAKE_ERR_INTERNAL = -6;
export const PANCAKE_ERR_INVALID_UTF8 = -7;
export const PANCAKE_ERR_INVALID_CODEC = -8;
export const PANCAKE_ERR_HANDSHAKE_INCOMPLETE = -9;
export const PANCAKE_ERR_PANIC = -100;

// Netlayer endpoint return codes (pancake_abi.h).
export const PANCAKE_ENDPOINT_ERR_IO = -20;
export const PANCAKE_ENDPOINT_ERR_MALFORMED = -21;
export const PANCAKE_ENDPOINT_ERR_CLOSED = -22;
export const PANCAKE_ENDPOINT_ERR_WOULD_BLOCK = -23;

// ─── Codec selector (pancake.h) ────────────────────────────────────
export const PANCAKE_CODEC_CAPNP = 0;
export const PANCAKE_CODEC_SYRUP = 1;

// ─── CaptpVersion selector (pancake.h) ─────────────────────────────
export const PANCAKE_CAPTP_VERSION_PRESPEC = 0;
export const PANCAKE_CAPTP_VERSION_V1_0 = 1;

// ─── Step outcome (pancake.h) ──────────────────────────────────────
export const PANCAKE_STEP_MORE_WORK = 0;
export const PANCAKE_STEP_IDLE = 1;
export const PANCAKE_STEP_CLOSED = 2;

// ─── Session state (pancake.h) ─────────────────────────────────────
export const PANCAKE_SESSION_NEGOTIATING = 0;
export const PANCAKE_SESSION_OPEN = 1;
export const PANCAKE_SESSION_CLOSED = 2;

// ─── Reference kinds (pancake.h) ───────────────────────────────────
export const PANCAKE_REF_NEAR = 0;
export const PANCAKE_REF_FAR = 1;
export const PANCAKE_REF_PROMISE = 2;
export const PANCAKE_REF_STURDY = 3;
export const PANCAKE_REF_BROKEN = 4;

// ─── Argument kinds (pancake.h) ────────────────────────────────────
export const PANCAKE_ARG_SYMBOL = 0;
export const PANCAKE_ARG_BYTES = 1;
export const PANCAKE_ARG_REFERENCE = 2;
export const PANCAKE_ARG_INTEGER = 3;
export const PANCAKE_ARG_BOOL = 4;
export const PANCAKE_ARG_STRING = 5;
export const PANCAKE_ARG_VOID = 6;
export const PANCAKE_ARG_LIST = 7;

// ─── Resolution kinds (pancake.h) ──────────────────────────────────
export const PANCAKE_RES_FULFILL = 0;
export const PANCAKE_RES_BREAK = 1;

// ─── Abort reason kinds (pancake.h) ────────────────────────────────
export const PANCAKE_ABORT_REASON_GRACEFUL_SHUTDOWN = 0;
export const PANCAKE_ABORT_REASON_VERSION_MISMATCH = 1;
export const PANCAKE_ABORT_REASON_MALFORMED_FRAME = 2;
export const PANCAKE_ABORT_REASON_PROTOCOL_ERROR = 3;
export const PANCAKE_ABORT_REASON_RESOURCE_EXHAUSTED = 4;
export const PANCAKE_ABORT_REASON_INVALID_START_SESSION_SIGNATURE = 5;
export const PANCAKE_ABORT_REASON_CROSSED_HELLOS = 6;
export const PANCAKE_ABORT_REASON_CONNECTION_LOST = 7;
export const PANCAKE_ABORT_REASON_OTHER = 0xffffffff;

// ─── Event kinds (pancake.h `PancakeEventKind`, #[repr(u32)]) ──────
export const PANCAKE_EVENT_KIND_PEER_READY = 0;
export const PANCAKE_EVENT_KIND_PEER_CLOSED = 1;
export const PANCAKE_EVENT_KIND_SESSION_ESTABLISHED = 2;
export const PANCAKE_EVENT_KIND_SESSION_ABORTED = 3;
export const PANCAKE_EVENT_KIND_DELIVER_RECEIVED = 4;
export const PANCAKE_EVENT_KIND_RESOLVE_RECEIVED = 5;
export const PANCAKE_EVENT_KIND_ABORT_RECEIVED = 6;

// ─── Syrup frame-probe outcomes (pancake.h) ───────────────────────
export const PANCAKE_FRAME_COMPLETE = 1;
export const PANCAKE_FRAME_INCOMPLETE = 0;
export const PANCAKE_FRAME_MALFORMED = -1;

// ─── Fixed-size tagged-union layout (LP64, 64-bit pointers) ────────
//
// Each typed-value struct is `kind: u32` + 4 bytes padding + a payload
// union. The payload sizes are dictated by the largest variant:
//   - Reference payload = 32 bytes (Sturdy: ptr+len+ptr+len).
//   - Argument payload  = 40 bytes (embedded Reference = 8 + 32).
//   - Resolution payload = 48 bytes (embedded Argument = 8 + 40).
// `payload` begins at offset 8 in every struct (after kind + padding).
export const PAYLOAD_OFFSET = 8;
export const REFERENCE_PAYLOAD_SIZE = 32;
export const ARGUMENT_PAYLOAD_SIZE = 40;
export const RESOLUTION_PAYLOAD_SIZE = 48;
export const REFERENCE_SIZE = PAYLOAD_OFFSET + REFERENCE_PAYLOAD_SIZE; // 40
export const ARGUMENT_SIZE = PAYLOAD_OFFSET + ARGUMENT_PAYLOAD_SIZE; // 48
export const RESOLUTION_SIZE = PAYLOAD_OFFSET + RESOLUTION_PAYLOAD_SIZE; // 56

// PancakeFrame { bytes: *u8, len: usize } — two pointer-sized fields.
export const FRAME_SIZE = 16;
// PancakeManagedFrame { bytes: *u8, len: usize, release: fnptr, private_data: *void } — 32.
export const MANAGED_FRAME_SIZE = 32;
// PancakeStepOutcome { kind: u32, next_deadline_ms: u64 } — 8-aligned → 16.
export const STEP_OUTCOME_SIZE = 16;
// PancakeOcapnUri { transport, designator, swissnum_ptr, swissnum_len } — 32.
export const OCAPN_URI_SIZE = 32;
