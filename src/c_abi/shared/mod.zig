//! Shared C-ABI vocabulary: the C-visible frame/context types, the OCapN value
//! types (`PancakeReference`/`PancakeArgument` and their model<->C
//! marshalling), the return and codec codes, the allocation policy,
//! the managed-frame machinery, the stream-shaped connection helpers
//! (`ConnLifecycle`, `ConnFrameOps`), and the per-thread last-error slot that
//! `libpancake_ocapn`'s handle families, the tcp/inproc transport families, and
//! the out-of-graph iroh C ABI (`src/c_abi/net_transport/iroh/mod.zig`) all speak.
//!
//! This leaf declares **no `export fn`**. The public `pancake_*` entry points
//! live in the `c_abi/ocapn` families (context, frame, uri), the Host, and
//! the `c_abi/net_transport/{tcp,inproc}` transport families, and the
//! `pancake_iroh_*` entry points in `c_abi_net_transport_iroh`; all reach this
//! vocabulary through `@import("c_abi_shared")`. Because importing the leaf pulls the
//! vocabulary without pulling either library's exported surface, `libpancake_ocapn`
//! carries the core families and `libpancake_net_transport_iroh` carries only
//! the iroh family, each reusing these types, and each from `pancake_ocapn.h`
//! on the C side
//! (ADR-0055 companion split). The two artifacts therefore share no exported
//! core symbol; they share the *layout* of these types, exactly as a C consumer
//! including both headers does.

const std = @import("std");
const builtin = @import("builtin");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");

/// The one cross-archive schema and bounded mechanics for failures with no
/// remaining return recipient (ADR-0115). This leaf owns no mutable global;
/// storage belongs to an explicit Context, Host, or driver owner.
pub const failure_diagnostics = @import("failure_diagnostics.zig");
pub const PancakeFailureEvent = failure_diagnostics.PancakeFailureEvent;
pub const PancakeFailureReport = failure_diagnostics.PancakeFailureReport;
pub const PANCAKE_FAILURE_EVENT_ABI_VERSION = failure_diagnostics.abi_version;
pub const PANCAKE_FAILURE_LAYER_CORE: u32 = @intFromEnum(failure_diagnostics.Layer.core);
pub const PANCAKE_FAILURE_LAYER_DRIVER: u32 = @intFromEnum(failure_diagnostics.Layer.driver);
pub const PANCAKE_FAILURE_LAYER_TRANSPORT: u32 = @intFromEnum(failure_diagnostics.Layer.transport);
pub const PANCAKE_FAILURE_LAYER_BINDING: u32 = @intFromEnum(failure_diagnostics.Layer.binding);
pub const PANCAKE_FAILURE_LAYER_APPLICATION_OBSERVER: u32 = @intFromEnum(failure_diagnostics.Layer.application_observer);
pub const PANCAKE_FAILURE_SCOPE_PROCESS: u32 = @intFromEnum(failure_diagnostics.ScopeKind.process);
pub const PANCAKE_FAILURE_SCOPE_CONTEXT: u32 = @intFromEnum(failure_diagnostics.ScopeKind.context);
pub const PANCAKE_FAILURE_SCOPE_HOST: u32 = @intFromEnum(failure_diagnostics.ScopeKind.host);
pub const PANCAKE_FAILURE_SCOPE_SESSION: u32 = @intFromEnum(failure_diagnostics.ScopeKind.session);
pub const PANCAKE_FAILURE_SCOPE_LISTENER: u32 = @intFromEnum(failure_diagnostics.ScopeKind.listener);
pub const PANCAKE_FAILURE_SCOPE_TRANSPORT: u32 = @intFromEnum(failure_diagnostics.ScopeKind.transport);
pub const PANCAKE_FAILURE_SCOPE_OPERATION: u32 = @intFromEnum(failure_diagnostics.ScopeKind.operation);
pub const PANCAKE_FAILURE_TRUNCATED_OPERATION = failure_diagnostics.truncated_operation;
pub const PANCAKE_FAILURE_TRUNCATED_PRIMARY_NAME = failure_diagnostics.truncated_primary_name;
pub const PANCAKE_FAILURE_TRUNCATED_PRIMARY_MESSAGE = failure_diagnostics.truncated_primary_message;
pub const PANCAKE_FAILURE_TRUNCATED_SECONDARY_NAME = failure_diagnostics.truncated_secondary_name;
pub const PANCAKE_FAILURE_TRUNCATED_SECONDARY_MESSAGE = failure_diagnostics.truncated_secondary_message;

// ── Return codes ─────────────────────────────────────────────────────────────

/// The annotated-symbol vocabulary the per-archive inventories share
/// (`symbols.zig`): crossing semantics per export, for the binding FFI-table
/// generators.
pub const symbols = @import("symbols.zig");
pub const archive_contract = @import("archive_contract.zig");

/// The multiplexed-transport table layout (ADR-0112): how a sidecar transport
/// archive plugs its multiplexed transport into the driver archive.
/// Layout only, no exports, like everything in this leaf.
pub const multiplexed_transport = @import("multiplexed_transport.zig");
pub const close = @import("close.zig");
pub const locator = @import("locator.zig");
pub const locator_adapter = @import("locator_adapter.zig");
pub const transport_provider = @import("transport_provider.zig");
pub const PancakeMultiplexedTransport = multiplexed_transport.PancakeMultiplexedTransport;
pub const PancakeMultiplexedReadyEvent = multiplexed_transport.PancakeMultiplexedReadyEvent;
pub const PancakeCloseOptions = close.PancakeCloseOptions;
pub const PancakeListenResult = transport_provider.PancakeListenResult;
pub const PancakeStreamTransport = transport_provider.PancakeStreamTransport;
pub const PancakeLocatorHintView = locator.PancakeLocatorHintView;
pub const PancakeLocatorView = locator.PancakeLocatorView;
pub const PancakeTransportProfile = transport_provider.PancakeTransportProfile;
pub const PancakeTransportOperationOptions = transport_provider.PancakeTransportOperationOptions;
pub const PancakeProviderFailure = transport_provider.PancakeProviderFailure;
pub const PancakeTransportProviderEntry = transport_provider.PancakeTransportProviderEntry;
pub const PancakeTransportProvider = transport_provider.PancakeTransportProvider;
pub const PancakeStreamStartConnectFn = transport_provider.PancakeStreamStartConnectFn;
pub const PancakeStreamFinishConnectFn = transport_provider.PancakeStreamFinishConnectFn;
pub const PancakeStreamCancelConnectFn = transport_provider.PancakeStreamCancelConnectFn;
pub const PancakeStreamListenFn = transport_provider.PancakeStreamListenFn;
pub const PancakeStreamFinishListenFn = transport_provider.PancakeStreamFinishListenFn;
pub const PancakeStreamCancelListenFn = transport_provider.PancakeStreamCancelListenFn;
pub const PANCAKE_LISTEN_READY = transport_provider.PANCAKE_LISTEN_READY;
pub const PANCAKE_LISTEN_PENDING = transport_provider.PANCAKE_LISTEN_PENDING;
pub const PancakeStreamListenerWaitFn = transport_provider.PancakeStreamListenerWaitFn;
pub const PancakeStreamListenerReadinessFdFn = transport_provider.PancakeStreamListenerReadinessFdFn;
pub const PancakeLocatorSinkFn = locator.PancakeLocatorSinkFn;
pub const PancakeTransportListenerRestorationStateFn = transport_provider.PancakeTransportListenerRestorationStateFn;
pub const PancakeTransportListenerLocatorFn = transport_provider.PancakeTransportListenerLocatorFn;
pub const PancakeTransportListenerAdvertiseFn = transport_provider.PancakeTransportListenerAdvertiseFn;
pub const PancakeStreamAcceptFn = transport_provider.PancakeStreamAcceptFn;
pub const PancakeStreamListenerCloseFn = transport_provider.PancakeStreamListenerCloseFn;
pub const PancakeStreamReadFn = transport_provider.PancakeStreamReadFn;
pub const PancakeStreamWriteAllFn = transport_provider.PancakeStreamWriteAllFn;
pub const PancakeStreamConnCloseFn = transport_provider.PancakeStreamConnCloseFn;
pub const PancakeStreamConnTakeFailureFn = transport_provider.PancakeStreamConnTakeFailureFn;
pub const PancakeTransportProviderSameConfigurationFn = transport_provider.PancakeTransportProviderSameConfigurationFn;
pub const PancakeTransportRetainFn = transport_provider.PancakeTransportRetainFn;
pub const PancakeTransportReleaseFn = transport_provider.PancakeTransportReleaseFn;
pub const PancakeMultiplexedReadinessFdFn = multiplexed_transport.PancakeMultiplexedReadinessFdFn;
pub const PancakeMultiplexedDrainReadyFn = multiplexed_transport.PancakeMultiplexedDrainReadyFn;
pub const PancakeMultiplexedStartConnectFn = multiplexed_transport.PancakeMultiplexedStartConnectFn;
pub const PancakeMultiplexedFinishConnectFn = multiplexed_transport.PancakeMultiplexedFinishConnectFn;
pub const PancakeMultiplexedClaimExternalFn = multiplexed_transport.PancakeMultiplexedClaimExternalFn;
pub const PancakeMultiplexedListenFn = multiplexed_transport.PancakeMultiplexedListenFn;
pub const PancakeMultiplexedFinishListenFn = multiplexed_transport.PancakeMultiplexedFinishListenFn;
pub const PancakeMultiplexedFinishAcceptFn = multiplexed_transport.PancakeMultiplexedFinishAcceptFn;
pub const PancakeMultiplexedStopListenFn = multiplexed_transport.PancakeMultiplexedStopListenFn;
pub const PancakeMultiplexedSubjectFn = multiplexed_transport.PancakeMultiplexedSubjectFn;
pub const PancakeMultiplexedConnTakeFailureFn = multiplexed_transport.PancakeMultiplexedConnTakeFailureFn;
pub const PancakeMultiplexedTryReadFn = multiplexed_transport.PancakeMultiplexedTryReadFn;
pub const PancakeMultiplexedTryWriteFn = multiplexed_transport.PancakeMultiplexedTryWriteFn;
pub const PancakeMultiplexedConnRemoteKeyFn = multiplexed_transport.PancakeMultiplexedConnRemoteKeyFn;
pub const PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION = transport_provider.PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION;
pub const PANCAKE_TRANSPORT_PROFILE_ABI_VERSION = transport_provider.PANCAKE_TRANSPORT_PROFILE_ABI_VERSION;
pub const PANCAKE_LOCATOR_VIEW_ABI_VERSION = locator.PANCAKE_LOCATOR_VIEW_ABI_VERSION;
pub const PANCAKE_STREAM_TRANSPORT_ABI_VERSION = transport_provider.PANCAKE_STREAM_TRANSPORT_ABI_VERSION;
pub const PANCAKE_TRANSPORT_EXEC_STREAM = transport_provider.PANCAKE_TRANSPORT_EXEC_STREAM;
pub const PANCAKE_TRANSPORT_EXEC_MULTIPLEXED = transport_provider.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED;
pub const PANCAKE_MULTIPLEXED_WOULD_BLOCK = multiplexed_transport.PANCAKE_MULTIPLEXED_WOULD_BLOCK;
pub const PANCAKE_MULTIPLEXED_EV_READABLE = multiplexed_transport.PANCAKE_MULTIPLEXED_EV_READABLE;
pub const PANCAKE_MULTIPLEXED_EV_WRITABLE = multiplexed_transport.PANCAKE_MULTIPLEXED_EV_WRITABLE;
pub const PANCAKE_MULTIPLEXED_EV_CLOSED = multiplexed_transport.PANCAKE_MULTIPLEXED_EV_CLOSED;
pub const PANCAKE_MULTIPLEXED_EV_ACCEPT = multiplexed_transport.PANCAKE_MULTIPLEXED_EV_ACCEPT;
pub const PANCAKE_MULTIPLEXED_EV_CONNECT = multiplexed_transport.PANCAKE_MULTIPLEXED_EV_CONNECT;
pub const PANCAKE_MULTIPLEXED_EV_LISTEN = multiplexed_transport.PANCAKE_MULTIPLEXED_EV_LISTEN;
pub const PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION = multiplexed_transport.PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION;
pub const PANCAKE_DESIGNATOR_SCHEME_ADDRESS = transport_provider.PANCAKE_DESIGNATOR_SCHEME_ADDRESS;
pub const PANCAKE_DESIGNATOR_SCHEME_KEY = transport_provider.PANCAKE_DESIGNATOR_SCHEME_KEY;
pub const PANCAKE_SEALED_CHANNEL_NONE = transport_provider.PANCAKE_SEALED_CHANNEL_NONE;
pub const PANCAKE_SEALED_CHANNEL_NOISE_XK = transport_provider.PANCAKE_SEALED_CHANNEL_NOISE_XK;
pub const PANCAKE_PENDING_CANCEL = close.PANCAKE_PENDING_CANCEL;
pub const PANCAKE_PENDING_FINISH = close.PANCAKE_PENDING_FINISH;
pub const PANCAKE_CLOSE_OPTIONS_ABI_VERSION = close.PANCAKE_CLOSE_OPTIONS_ABI_VERSION;
pub const PANCAKE_CLOSE_MAX_GRACE_MS = close.PANCAKE_CLOSE_MAX_GRACE_MS;
pub const PANCAKE_CLOSE_GRACE_UNSPECIFIED = close.PANCAKE_CLOSE_GRACE_UNSPECIFIED;
pub const PANCAKE_CLOSE_GRACE_FINITE = close.PANCAKE_CLOSE_GRACE_FINITE;
pub const PANCAKE_CLOSE_GRACE_UNBOUNDED = close.PANCAKE_CLOSE_GRACE_UNBOUNDED;
pub const PANCAKE_HINT_STRING = locator.PANCAKE_HINT_STRING;
pub const PANCAKE_HINT_BYTES = locator.PANCAKE_HINT_BYTES;
pub const PANCAKE_HINT_BOOLEAN = locator.PANCAKE_HINT_BOOLEAN;
pub const PANCAKE_HINT_INTEGER = locator.PANCAKE_HINT_INTEGER;
pub const PANCAKE_HINTS_MAP = locator.PANCAKE_HINTS_MAP;
pub const PANCAKE_HINTS_BOOLEAN_FALSE = locator.PANCAKE_HINTS_BOOLEAN_FALSE;

pub const PANCAKE_OK: i32 = 0;
pub const PANCAKE_ERR_NULL_POINTER: i32 = -1;
/// A non-pointer argument was out of range or unparseable (e.g. a zero frame
/// cap, or a host string that is not an address). Distinct from `_NULL_POINTER`
/// (a required pointer was null) and `_IO` (the network itself failed).
pub const PANCAKE_ERR_INVALID_ARGUMENT: i32 = -2;
pub const PANCAKE_ERR_SESSION: i32 = -3;
pub const PANCAKE_ERR_CODEC: i32 = -4;
pub const PANCAKE_ERR_INTERNAL: i32 = -5;
pub const PANCAKE_ERR_WOULD_BLOCK: i32 = -6;

/// Translate the shared locator adapter's complete error set at C crossings.
pub fn locatorAdapterErrorCode(err: locator_adapter.CloneViewError) i32 {
    return switch (err) {
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        error.InvalidLocatorView => PANCAKE_ERR_INVALID_ARGUMENT,
    };
}

/// The peer closed the stream gracefully on a frame boundary (clean EOF).
pub const PANCAKE_ERR_CLOSED: i32 = -7;
/// An underlying socket read/write failed; `pancake_last_error` carries the
/// concrete cause.
pub const PANCAKE_ERR_IO: i32 = -8;
/// Inbound bytes were not a structurally valid frame.
pub const PANCAKE_ERR_MALFORMED: i32 = -9;
/// An inbound frame exceeded the endpoint's `max_frame_bytes`.
pub const PANCAKE_ERR_FRAME_TOO_LARGE: i32 = -10;
/// A value *sent* across the typed surface uses a variant the C ABI cannot carry:
/// a `handoff` argument or a `sturdy`/`broken` reference target. Those are
/// refused loudly with this code rather than marshalled wrong. (`set`,
/// `tagged`, `keyword`, and `struct` arguments do carry, both directions.) A
/// received `sturdy`/`broken` reference projects lossily — the kind is reported but its
/// swissnum/detail is dropped — since the deliver was authored by the partner,
/// not refused on this consumer's behalf.
pub const PANCAKE_ERR_UNSUPPORTED_VALUE: i32 = -11;
/// A promise the partner broke: a `send`/`fetch` the remote side refused with a
/// reason, not a fault in the Host or transport. Bindings reuse it when they
/// turn that break into their own error type, so the reason stays distinct from
/// a real failure.
pub const PANCAKE_ERR_BROKEN: i32 = -12;
/// A lookup found nothing: the `pancake_locator_hint` key names no hint on the
/// locator. Distinct from `_INVALID_ARGUMENT` (the request was malformed) — the
/// request was well-formed, the thing asked for is simply absent.
pub const PANCAKE_ERR_NOT_FOUND: i32 = -13;
/// A caller-provided output buffer was too small for the value being written.
/// The call still reports the required length in its `out_len` parameter, so a
/// caller retries with a large enough buffer. Distinct from `_INVALID_ARGUMENT`
/// (a malformed request) — the request is well-formed, the buffer is just short.
pub const PANCAKE_ERR_BUFFER_TOO_SMALL: i32 = -14;
/// A caller-set deadline elapsed: the handshake budget passed with no hello, or
/// a blocking answer-wait's budget passed with no settle. Distinct from `_IO`
/// (the socket itself failed) and `_SESSION` (the partner refused something) —
/// nothing went wrong on the wire, the caller's own budget is what ended the
/// wait, so a retry with a longer one is a reasonable response.
pub const PANCAKE_ERR_TIMEOUT: i32 = -15;

comptime {
    const errors = [_]i32{
        PANCAKE_ERR_NULL_POINTER,
        PANCAKE_ERR_INVALID_ARGUMENT,
        PANCAKE_ERR_SESSION,
        PANCAKE_ERR_CODEC,
        PANCAKE_ERR_INTERNAL,
        PANCAKE_ERR_WOULD_BLOCK,
        PANCAKE_ERR_CLOSED,
        PANCAKE_ERR_IO,
        PANCAKE_ERR_MALFORMED,
        PANCAKE_ERR_FRAME_TOO_LARGE,
        PANCAKE_ERR_UNSUPPORTED_VALUE,
        PANCAKE_ERR_BROKEN,
        PANCAKE_ERR_NOT_FOUND,
        PANCAKE_ERR_BUFFER_TOO_SMALL,
        PANCAKE_ERR_TIMEOUT,
    };
    for (errors, 1..) |code, ordinal| {
        if (code != -@as(i32, @intCast(ordinal)))
            @compileError("prerelease C error codes must remain contiguous");
    }
}

// ── Codec selector ───────────────────────────────────────────────────────────

/// Codec selector: the wire grammar a Host session speaks and the framing an
/// endpoint delimits with (`pancake_tcp_connect` / `pancake_tcp_accept`). The
/// two must match, the endpoint splits the stream with the same grammar the
/// session encodes in. Zero is deliberately not a valid input selector:
/// zeroed trace memory or a future codec id reads as unknown, never Syrup.
/// Whether `value` is absent (`0`) or one of the stable public result codes.
/// The contiguity assertion above makes the range itself the one authority.
pub fn isStableFailureResult(value: i32) bool {
    return value == PANCAKE_OK or
        (value <= PANCAKE_ERR_NULL_POINTER and value >= PANCAKE_ERR_TIMEOUT);
}

/// Validate the typed-cause portion of a structured failure report. A report
/// with consequences names the first one; a report without consequences must
/// not carry secondary fields that contradict its count.
pub fn hasValidFailureCauses(report: PancakeFailureReport) bool {
    if (!isStableFailureResult(report.primary_result) or
        (report.primary_result == PANCAKE_OK and report.primary_name_len == 0)) return false;
    if (report.secondary_count == 0) {
        return report.secondary_result == PANCAKE_OK and
            report.secondary_name_len == 0 and
            report.secondary_message_len == 0;
    }
    return isStableFailureResult(report.secondary_result) and report.secondary_name_len != 0;
}

pub const PANCAKE_CODEC_UNKNOWN: u32 = 0;
pub const PANCAKE_CODEC_SYRUP: u32 = 1;
pub const PANCAKE_CODEC_CAPNP: u32 = 2;

/// The CapTP profile a session negotiates in (ADR-0003). `V1_0` is the
/// interop floor a Goblins vat and the upstream suite speak; `NEXT` is the
/// pancake-to-pancake track, which `Offer.native` prefers together with
/// Cap'n Proto. `op:start-session` names the version each end offers, and
/// the two need not match: the version and the codec negotiate as
/// independent axes, and an offer the partner cannot follow settles that
/// axis back to the baseline rather than being refused (ADR-0103). Carrying
/// a fleet gets the profile it wants when both ends prefer it, but this is not
/// a condition for opening the session.
pub const PANCAKE_CAPTP_V1_0: u32 = 0;
pub const PANCAKE_CAPTP_NEXT: u32 = 1;

/// Feature-offer bitmask for optional CapTP behavior a Host advertises.
/// `FULL` is every behavior Pancake implements; `MINIMUM` advertises only
/// Deliver, Resolve, and Abort. An absent peer hint means
/// `model.FeatureSet.baseline()`, which deliberately excludes outbound untag.
/// Unknown bits are refused so a caller cannot accidentally believe it enabled
/// behavior this build does not know how to gate.
pub const PANCAKE_FEATURE_PIPELINING: u32 = 1 << 0;
pub const PANCAKE_FEATURE_HANDOFF: u32 = 1 << 1;
pub const PANCAKE_FEATURE_WIRE_DELTA: u32 = 1 << 2;
pub const PANCAKE_FEATURE_STURDYREF: u32 = 1 << 3;
pub const PANCAKE_FEATURE_UNTAG: u32 = 1 << 4;
pub const PANCAKE_FEATURE_MINIMUM: u32 = 0;

const FeatureSpec = struct {
    field: []const u8,
    bit: u32,
};

const feature_specs = [_]FeatureSpec{
    .{ .field = "pipelining", .bit = PANCAKE_FEATURE_PIPELINING },
    .{ .field = "handoff", .bit = PANCAKE_FEATURE_HANDOFF },
    .{ .field = "wire_delta", .bit = PANCAKE_FEATURE_WIRE_DELTA },
    .{ .field = "sturdyref", .bit = PANCAKE_FEATURE_STURDYREF },
    .{ .field = "untag", .bit = PANCAKE_FEATURE_UNTAG },
};

fn featureFullMask() u32 {
    var out: u32 = 0;
    inline for (feature_specs) |spec| out |= spec.bit;
    return out;
}

pub const PANCAKE_FEATURE_FULL: u32 = featureFullMask();
pub const PANCAKE_FEATURE_BASELINE: u32 = featureSetToC(model.FeatureSet.baseline());

comptime {
    const fields = @typeInfo(model.FeatureSet).@"struct".fields;
    if (fields.len != feature_specs.len) {
        @compileError("model.FeatureSet changed; update the C ABI PANCAKE_FEATURE_* table and binding mirrors");
    }
    var bits_seen: u32 = 0;
    for (feature_specs) |spec| {
        if (!@hasField(model.FeatureSet, spec.field)) {
            @compileError("PANCAKE_FEATURE_* table names a field missing from model.FeatureSet: " ++ spec.field);
        }
        if (spec.bit == 0 or spec.bit & (spec.bit - 1) != 0) {
            @compileError("PANCAKE_FEATURE_* bit must name exactly one nonzero bit: " ++ spec.field);
        }
        if (bits_seen & spec.bit != 0) {
            @compileError("PANCAKE_FEATURE_* table reuses a bit: " ++ spec.field);
        }
        bits_seen |= spec.bit;
    }
    for (fields) |field| {
        var matches = 0;
        for (feature_specs) |spec| {
            if (std.mem.eql(u8, spec.field, field.name)) matches += 1;
        }
        if (matches != 1) {
            @compileError("model.FeatureSet field must have exactly one PANCAKE_FEATURE_* bit: " ++ field.name);
        }
    }
}

/// Encode a CapTP version as its `PANCAKE_CAPTP_*` value — the decode's
/// inverse, kept beside it so the pair cannot drift.
pub fn captpVersionToC(version: model.CaptpVersion) u32 {
    return switch (version) {
        .v1_0 => PANCAKE_CAPTP_V1_0,
        .next => PANCAKE_CAPTP_NEXT,
    };
}

/// Decode a `PANCAKE_CAPTP_*` value, or null for anything outside the family.
pub fn captpVersionFromC(version: u32) ?model.CaptpVersion {
    return switch (version) {
        PANCAKE_CAPTP_V1_0 => .v1_0,
        PANCAKE_CAPTP_NEXT => .next,
        else => null,
    };
}

/// Encode a codec as its `PANCAKE_CODEC_*` value — the decode's inverse for
/// built-ins. Unknown non-exhaustive codec ids cannot be described as either
/// built-in, so output surfaces use the explicit sentinel instead of lying as
/// Syrup.
pub fn codecToC(codec: model.CodecId) u32 {
    return switch (codec) {
        .syrup => PANCAKE_CODEC_SYRUP,
        .capnp => PANCAKE_CODEC_CAPNP,
        _ => PANCAKE_CODEC_UNKNOWN,
    };
}

/// Decode a `PANCAKE_CODEC_*` value, or null for anything outside the family.
pub fn codecFromC(codec: u32) ?model.CodecId {
    return switch (codec) {
        PANCAKE_CODEC_SYRUP => .syrup,
        PANCAKE_CODEC_CAPNP => .capnp,
        else => null,
    };
}

/// Validate the framing pair shared by the explicit blocking transport fronts.
/// The stable result remains INVALID_ARGUMENT; this helper makes the archive's
/// last-error detail identical instead of letting each transport forget or
/// paraphrase one half of the same C contract.
pub fn framingOptionsFromC(codec: u32, max_frame_bytes: usize, operation: []const u8) error{ InvalidCodec, InvalidFrameCap }!model.CodecId {
    const codec_id = codecFromC(codec) orelse {
        setLastError("{s}: codec must be a PANCAKE_CODEC_* value", .{operation});
        return error.InvalidCodec;
    };
    if (max_frame_bytes == 0) {
        setLastError("{s}: max_frame_bytes must not be zero", .{operation});
        return error.InvalidFrameCap;
    }
    return codec_id;
}

pub fn featureSetToC(features: model.FeatureSet) u32 {
    var out: u32 = 0;
    inline for (feature_specs) |spec| {
        if (@field(features, spec.field)) out |= spec.bit;
    }
    return out;
}

pub fn featureSetFromC(features: u32) ?model.FeatureSet {
    if (features & ~PANCAKE_FEATURE_FULL != 0) return null;
    var out = model.FeatureSet.minimum();
    inline for (feature_specs) |spec| {
        @field(out, spec.field) = features & spec.bit != 0;
    }
    return out;
}

// ── Frame storage shape ──────────────────────────────────────────────────────

pub const PANCAKE_FRAME_SHAPE_BYTE: u32 = 0;
/// Word-aligned frame storage: the pointer must be 8-byte aligned and the
/// length divisible by 8. Anything else is refused with
/// `PANCAKE_ERR_INVALID_ARGUMENT`.
pub const PANCAKE_FRAME_SHAPE_WORD: u32 = 1;

pub fn frameShapeFromC(shape: u32) ?foundation.FrameShape {
    return switch (shape) {
        PANCAKE_FRAME_SHAPE_BYTE => .byte,
        PANCAKE_FRAME_SHAPE_WORD => .word,
        else => null,
    };
}

fn frameShapeToC(shape: foundation.FrameShape) u32 {
    return switch (shape) {
        .byte => PANCAKE_FRAME_SHAPE_BYTE,
        .word => PANCAKE_FRAME_SHAPE_WORD,
    };
}

// ── Frame types ──────────────────────────────────────────────────────────────

/// A frame whose bytes are *borrowed* from the C caller for the duration of one
/// call. The engine reads them during the call and retains nothing; the caller
/// keeps ownership and frees them on its own schedule. Used for inbound feeds.
pub const PancakeFrame = extern struct {
    bytes: ?[*]const u8,
    len: usize,
    shape: u32,
};

/// Internal self-release hook a `PancakeManagedFrame` carries. Do not invoke
/// this pointer directly: free the frame through `pancake_managed_frame_release`,
/// which is idempotent and nulls the hook first. Calling it directly after the
/// wrapper has run is a null function-pointer call.
pub const ReleaseFn = *const fn (*PancakeManagedFrame) callconv(.c) void;

/// A frame the engine *owns* and hands to the C caller (outbound frames, event
/// frames). It is self-describing and self-releasing: free it exactly once
/// through `pancake_managed_frame_release` (idempotent), never with a host `free`
/// and never by calling the `release` field directly.
pub const PancakeManagedFrame = extern struct {
    bytes: ?[*]u8,
    len: usize,
    shape: u32,
    release: ?ReleaseFn,
    private_data: ?*anyopaque,
};

const ManagedFramePayload = struct {
    frame: foundation.Frame,
    allocator: std.mem.Allocator,
};

/// Preallocated ownership cell for a managed C frame. Reserve before removing
/// a frame from its source queue; commit after dequeue, or cancel on an empty
/// queue/refusal. This makes allocator failure transactional without copying
/// or requeueing frame bytes.
pub const ManagedFrameReservation = struct {
    payload: *ManagedFramePayload,

    pub fn cancel(self: ManagedFrameReservation) void {
        self.payload.allocator.destroy(self.payload);
    }

    pub fn commit(self: ManagedFrameReservation, frame: foundation.Frame) PancakeManagedFrame {
        self.payload.frame = frame;
        return .{
            .bytes = @constCast(self.payload.frame.bytes().ptr),
            .len = self.payload.frame.bytes().len,
            .shape = frameShapeToC(self.payload.frame.view().shape),
            .release = releaseOwnedFrame,
            .private_data = self.payload,
        };
    }
};

pub fn reserveManagedFrame(alloc: std.mem.Allocator) !ManagedFrameReservation {
    const payload = try alloc.create(ManagedFramePayload);
    payload.allocator = alloc;
    return .{ .payload = payload };
}

/// Wrap an owned `foundation.Frame` as a self-releasing managed frame. The frame
/// moves into a heap payload; the descriptor's `release` frees the payload and
/// the frame through `alloc`.
pub fn tryManagedFrame(alloc: std.mem.Allocator, frame: foundation.Frame) !PancakeManagedFrame {
    const reservation = try reserveManagedFrame(alloc);
    return reservation.commit(frame);
}

/// Wrap an owned frame into `slot` as a managed frame, or free it and fail: the
/// one body behind every take-outbound / read-frame tail. On wrap-allocation
/// failure the frame is deinit'd (it is owned and unreachable after), the last
/// error is set with `ctx` (comptime-prefixed onto the shared suffix so each
/// caller keeps its exact message), and `PANCAKE_ERR_INTERNAL` is returned; on
/// success `slot` owns the frame and `PANCAKE_OK` is returned. Shared so no two
/// archives can drift on the wrap-failure contract.
pub fn wrapManagedInto(alloc: std.mem.Allocator, frame: foundation.Frame, slot: *PancakeManagedFrame, comptime ctx: []const u8) i32 {
    slot.* = tryManagedFrame(alloc, frame) catch {
        var owned = frame;
        owned.deinit();
        setLastError(ctx ++ ": frame wrap allocation failed", .{});
        return PANCAKE_ERR_INTERNAL;
    };
    return PANCAKE_OK;
}

fn releaseOwnedFrame(frame: *PancakeManagedFrame) callconv(.c) void {
    const payload_ptr = frame.private_data orelse return;
    const payload: *ManagedFramePayload = @ptrCast(@alignCast(payload_ptr));
    const alloc = payload.allocator;
    payload.frame.deinit();
    alloc.destroy(payload);
    frame.bytes = null;
    frame.len = 0;
    frame.release = null;
    frame.private_data = null;
}

// ── Allocation policy ────────────────────────────────────────────────────────

/// Host allocation callbacks (`pancake_context_new_with_allocator`). `alloc`
/// returns memory aligned to `alignment` (a power of two) or null on failure;
/// `free` receives the same `size`/`alignment` the allocation was made with.
/// `user_data` is passed back to every callback unchanged. The callbacks must be
/// thread-safe: a context backing a TCP netlayer is driven from its threaded I/O
/// backend.
///
/// The surface is deliberately `alloc` + `free` only. With both sides told the
/// size, the only sound resize policy for an opaque host allocator is "never
/// resize in place" (see `ContextAllocator`), which keeps `free`'s size argument
/// exactly equal to `alloc`'s, correct even for a size-tracking host allocator.
/// A `realloc` callback cannot preserve that invariant or guarantee alignment of
/// the relocated block, so it is intentionally absent rather than a footgun.
pub const PancakeAllocFn = *const fn (user_data: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque;
pub const PancakeFreeFn = *const fn (user_data: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void;

/// Host allocator specification passed by value to
/// `pancake_context_new_with_allocator`. `alloc` and `free` are required;
/// `user_data` may be null.
pub const PancakeAllocator = extern struct {
    alloc: ?PancakeAllocFn,
    free: ?PancakeFreeFn,
    user_data: ?*anyopaque,
};

pub const PancakeContext = opaque {};

/// The allocator the *simple* C ABI path uses, the constructors that take no
/// `PancakeContext` (`pancake_tcp_netlayer_new`, for example) and
/// everything those handles own. `smp_allocator` is a thread-safe
/// general-purpose allocator: a managed frame per outbound message or event
/// costs an arena-style bump, not the `mmap`/`munmap` round-trip
/// `page_allocator` paid per frame on the wire path.
///
/// A caller that needs allocation policy creates a `PancakeContext` and uses the
/// `*_in` constructors instead; this default is the library-owned policy for the
/// callers that do not.
///
/// On freestanding `wasm32` (the browser binding target, ADR-0070) there are no
/// threads and no `smp_allocator`; the library-owned default is the single-
/// threaded wasm allocator, the same one the JS host reaches through
/// `pancake_wasm_alloc` / `pancake_wasm_free`, so a handle the library allocates
/// and a buffer JS allocates come from one heap.
pub const library_allocator = if (builtin.target.cpu.arch.isWasm() and builtin.target.os.tag == .freestanding)
    std.heap.wasm_allocator
else
    std.heap.smp_allocator;

/// Adapts the C host allocation callbacks to a `std.mem.Allocator`. Heap-pinned
/// inside its `Context`, so the vtable's `ptr` (`&context.embedder`) stays valid for
/// the context's whole life.
pub const ContextAllocator = struct {
    alloc_fn: PancakeAllocFn,
    free_fn: PancakeFreeFn,
    user_data: ?*anyopaque,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = hostAlloc,
        .resize = hostResize,
        .remap = hostRemap,
        .free = hostFree,
    };

    pub fn allocator(self: *ContextAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn hostAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *ContextAllocator = @ptrCast(@alignCast(ctx));
        const raw = self.alloc_fn(self.user_data, len, alignment.toByteUnits()) orelse return null;
        return @ptrCast(raw);
    }

    /// No in-place resize and no relocation: a grow becomes alloc-copy-free.
    /// This is the only sound policy for an opaque host allocator told the size
    /// on both `alloc` and `free` — it keeps every `free` size exactly equal to
    /// its `alloc` size, and never asks a relocated block to honor the original
    /// over-alignment (which a C `realloc` cannot promise).
    fn hostResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = .{ ctx, memory, alignment, new_len, ret_addr };
        return false;
    }

    fn hostRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = .{ ctx, memory, alignment, new_len, ret_addr };
        return null;
    }

    fn hostFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = ret_addr;
        const self: *ContextAllocator = @ptrCast(@alignCast(ctx));
        self.free_fn(self.user_data, memory.ptr, memory.len, alignment.toByteUnits());
    }
};

pub const default_failure_capacity: usize = 64;
pub const default_failure_payload_cap: usize = 512;

pub const LifecycleIds = struct {
    value: if (builtin.single_threaded) u64 else std.atomic.Value(u64),

    pub fn init() LifecycleIds {
        return .{ .value = if (builtin.single_threaded) 1 else .init(1) };
    }

    pub fn allocate(self: *LifecycleIds) error{IdentifierExhausted}!u64 {
        if (comptime builtin.single_threaded) {
            if (self.value == std.math.maxInt(u64)) return error.IdentifierExhausted;
            const current = self.value;
            self.value += 1;
            return current;
        }
        var current = self.value.load(.monotonic);
        while (current != std.math.maxInt(u64)) {
            if (self.value.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |observed| {
                current = observed;
            } else {
                return current;
            }
        }
        return error.IdentifierExhausted;
    }
};

const AllocatorPolicy = union(enum) {
    /// The library-owned allocation policy; carries no state.
    library,
    /// Host-supplied allocation policy: the heap-pinned state the returned
    /// allocator vtable points into.
    embedder: ContextAllocator,
};

pub const Context = struct {
    allocator_policy: AllocatorPolicy,
    failures: failure_diagnostics.Journal,
    lifecycle_ids: LifecycleIds,

    /// The allocator this context's handle family allocates and frees through.
    /// The `.embedder` arm's vtable borrows the pinned policy inside this
    /// Context, valid for the Context's whole lifetime.
    pub fn allocator(self: *Context) std.mem.Allocator {
        return switch (self.allocator_policy) {
            .library => library_allocator,
            .embedder => |*e| e.allocator(),
        };
    }
};

pub fn ctxFromOpaque(context: ?*PancakeContext) ?*Context {
    const ptr = context orelse return null;
    return @ptrCast(@alignCast(ptr));
}

// ── Per-thread last error ────────────────────────────────────────────────────
//
// The Zig side would otherwise hide the concrete `ReadFailed` / `WriteFailed`
// behind a flat `PANCAKE_ERR_IO`. This per-thread slot re-exposes it: a function
// that returns `_IO` first records a human-readable cause here. Each library
// that imports this leaf compiles its own copy of the slot, so every archive
// keeps independent last-error state, read through its own family's reader
// (`pancake_last_error`, `pancake_tcp_last_error`, and the rest).

threadlocal var last_error_buf: [256]u8 = undefined;
threadlocal var last_error_len: usize = 0;

const truncated_error_suffix = "... [truncated]";

pub fn setLastError(comptime fmt: []const u8, args: anytype) void {
    // A fixed writer reports exactly how many bytes it wrote, including on
    // overflow. `bufPrint`'s `NoSpaceLeft` leaves an unspecified prefix, so
    // taking the whole buffer there would publish the uninitialized tail of
    // this threadlocal to the C caller — and these messages format
    // partner-supplied designators.
    var w = std.Io.Writer.fixed(&last_error_buf);
    w.print(fmt, args) catch {
        // Overflow is itself diagnostic information. Keep the bounded prefix,
        // but make the loss explicit instead of exposing a plausible-looking
        // partial cause to the binding runtime.
        comptime std.debug.assert(truncated_error_suffix.len <= last_error_buf.len);
        const suffix_start = last_error_buf.len - truncated_error_suffix.len;
        @memcpy(last_error_buf[suffix_start..], truncated_error_suffix);
        last_error_len = last_error_buf.len;
        return;
    };
    last_error_len = w.end;
}

/// Retain the textual projection of the same bounded failure-chain fact used
/// by structured provider reports. The structured record is authoritative;
/// this archive-local slot is the immediate per-call explanation for direct C
/// consumers.
pub fn setLastErrorChain(prefix: []const u8, failure: foundation.FailureChain) void {
    if (failure.secondaryName()) |secondary_name| {
        setLastError("{s}: {s}; cleanup: {s} ({d} secondary failures)", .{
            prefix,
            failure.primaryName(),
            secondary_name,
            failure.secondary_count,
        });
    } else {
        setLastError("{s}: {s}", .{ prefix, failure.primaryName() });
    }
}

/// Record the concrete cause before projecting it into the deliberately small
/// C error vocabulary. Generic codes are useful for portable branching; the
/// per-thread detail is what makes the failure diagnosable.
pub fn failInternal(comptime operation: []const u8, cause: anyerror) i32 {
    setLastError(operation ++ ": {s}", .{@errorName(cause)});
    return PANCAKE_ERR_INTERNAL;
}

pub fn failIo(comptime operation: []const u8, cause: anyerror) i32 {
    setLastError(operation ++ ": {s}", .{@errorName(cause)});
    return PANCAKE_ERR_IO;
}

/// Copy the calling thread's last error message into `out_buf`. Every archive's
/// `pancake_*_last_error` export is one call to this. Copies at most
/// `cap - 1` bytes and always NUL-terminates when `cap > 0`. Returns the full
/// message length.
pub fn lastErrorRead(out_buf: ?[*]u8, cap: usize) usize {
    const dest = out_buf orelse return last_error_len;
    if (cap == 0) return last_error_len;
    const n = @min(last_error_len, cap - 1);
    @memcpy(dest[0..n], last_error_buf[0..n]);
    dest[n] = 0;
    return last_error_len;
}

/// Clear the calling thread's last error slot.
pub fn lastErrorClear() void {
    last_error_len = 0;
}

/// Complete one off-thread FFI call by copying this worker thread's diagnostic
/// into caller-owned storage before control returns to the runtime. The
/// operation must clear the slot on entry, so a status with no concrete cause
/// reports a zero length rather than an earlier call's message.
pub fn captureCallError(
    code: i32,
    out_buf: ?[*]u8,
    cap: usize,
    out_len: ?*usize,
) i32 {
    if (out_len) |len| len.* = lastErrorRead(out_buf, cap);
    return code;
}

/// A caller-buffer diagnostic is either wholly omitted or has a length slot.
/// Validate this before starting an effect so malformed optional plumbing can
/// never perform the operation and then replace its outcome.
pub fn optionalCallErrorOutputIsValid(out_buf: ?[*]u8, cap: usize, out_len: ?*usize) bool {
    return out_len != null or (out_buf == null and cap == 0);
}

// ── Typed OCapN value vocabulary ─────────────────────────────────────────────
//
// The fixed-layout reference/argument structs and Host marshalling traversal
// live in this leaf so every archive and binding shares one layout. The ocapn root
// (`src/c_abi/ocapn/mod.zig`) re-exports the names so `tools/gen/header/ocapn.zig`'s
// reflection emits them into `pancake_ocapn.h`; the transport archives include
// that one header on the C side.

pub const PANCAKE_ARG_INTEGER: u32 = 0;
pub const PANCAKE_ARG_FLOAT64: u32 = 1;
pub const PANCAKE_ARG_BOOLEAN: u32 = 2;
pub const PANCAKE_ARG_BYTES: u32 = 3;
pub const PANCAKE_ARG_STRING: u32 = 4;
pub const PANCAKE_ARG_SYMBOL: u32 = 5;
pub const PANCAKE_ARG_VOID: u32 = 6;
pub const PANCAKE_ARG_REFERENCE: u32 = 7;
pub const PANCAKE_ARG_LIST: u32 = 8;
/// A `set` reuses `items`; a `tagged` reuses `bytes` (the tag) and `items` (the
/// value list); a `keyword` reuses `bytes`.
pub const PANCAKE_ARG_SET: u32 = 9;
pub const PANCAKE_ARG_TAGGED: u32 = 10;
pub const PANCAKE_ARG_KEYWORD: u32 = 11;
/// An arbitrary-precision OCapN Integer outside `int64_t`: `bytes`/`bytes_len`
/// carry the canonical decimal magnitude (ASCII digits, no leading zero) and
/// `boolean` carries the sign (1 = negative). A magnitude that fits `int64_t`
/// belongs in `PANCAKE_ARG_INTEGER` and is refused here.
pub const PANCAKE_ARG_BIG_INTEGER: u32 = 12;
/// An OCapN Struct. `items` is an even-length sequence of alternating
/// `_STRING` keys and values. Keys must be unique. The alternating tree keeps
/// the C waist recursive without adding a second mutually-recursive ABI type.
pub const PANCAKE_ARG_STRUCT: u32 = 13;
/// An OCapN Error value. `bytes`/`bytes_len` carry its message. This is a
/// fulfilled value; `PANCAKE_RESOLUTION_BREAK` remains the rejected outcome.
pub const PANCAKE_ARG_ERROR: u32 = 14;

pub const PANCAKE_RESOLUTION_FULFILL: u32 = 0;
pub const PANCAKE_RESOLUTION_BREAK: u32 = 1;
/// The answer fulfilled to a three-party handoff (ADR-0009/ADR-0100): the
/// resolution carries a `desc:handoff-give` the recipient must redeem against
/// the named exporter rather than an immediate value. `PancakeResolve.handoff`
/// carries the verbatim give and the exporter's dialable locator.
pub const PANCAKE_RESOLUTION_HANDOFF: u32 = 2;

/// An opaque capability identity owned by one `PancakeHost`. The integer has no
/// wire meaning and cannot be combined with a caller-selected session. Equal
/// ids name the same Host capability; the C issuer keeps ids distinct across
/// Hosts and never reuses a retired id.
pub const PancakeReference = extern struct {
    id: u64,
};

/// A passable argument value. `kind` selects which field is live. `bytes`/
/// `bytes_len` carry `_BYTES`/`_STRING`/`_SYMBOL`/`_KEYWORD`/`_ERROR`; `items`/
/// `items_len` carry a `_LIST`'s or `_SET`'s elements. A `_TAGGED` uses both:
/// the tag in `bytes`/`bytes_len` and the value list in `items`/`items_len`.
/// A `_BIG_INTEGER` carries the canonical decimal magnitude in `bytes`/
/// `bytes_len` (ASCII digits, no leading zero) and the sign in `boolean`
/// (1 = negative); a magnitude that fits `int64_t` belongs in `_INTEGER` and
/// is refused here. An `_ERROR` is a fulfilled OCapN Error value whose bytes
/// are its message; it is distinct from a rejected resolution. A `_STRUCT`
/// carries alternating `_STRING` key/value
/// children in `items`; its count is therefore always even. On a projected
/// (received) value the pointers alias the
/// owning arena and are valid until the matching `*_release`.
pub const PancakeArgument = extern struct {
    kind: u32,
    boolean: u32,
    integer: i64,
    float64: f64,
    bytes: ?[*]const u8,
    bytes_len: usize,
    reference: PancakeReference,
    items: ?[*]const PancakeArgument,
    items_len: usize,
};

pub const zero_reference: PancakeReference = .{ .id = 0 };
pub const zero_argument: PancakeArgument = .{
    .kind = PANCAKE_ARG_VOID,
    .boolean = 0,
    .integer = 0,
    .float64 = 0,
    .bytes = null,
    .bytes_len = 0,
    .reference = zero_reference,
    .items = null,
    .items_len = 0,
};

/// `InvalidArgument` is this leaf's own refusal of a caller-supplied
/// discriminant outside its family. It always arrives with a last-error message
/// naming the offending value, so a mapper above must not stamp the bare error
/// name over it. The other members are a shape the marshal cannot carry
/// (`UnsupportedValue`), a missing pointer, and allocation failure.
pub const MarshalError = error{ UnsupportedValue, InvalidArgument, NullPointer, OutOfMemory };

/// Classify an inbound-dispatch error into a C ABI return code. Derived from the
/// single error taxonomy (`engine.abort_projection.classify`) so the C codes
/// cannot drift from the abort projection — and defined once here so no two
/// archives can disagree on the same error: codec/decode malformations report
/// `CODEC`, session state-machine refusals (a partner protocol violation, a
/// resource cap, an already-closed session) report `SESSION`, and host-internal
/// failures (allocation, …) report `INTERNAL`.
pub fn feedErrorToCode(err: anyerror) i32 {
    return switch (engine.abort_projection.classify(err).domain) {
        .codec => PANCAKE_ERR_CODEC,
        .session => PANCAKE_ERR_SESSION,
        .foreign => PANCAKE_ERR_INTERNAL,
    };
}

pub fn marshalErrorToCode(err: MarshalError) i32 {
    setLastError("C argument: {s}", .{@errorName(err)});
    return switch (err) {
        error.UnsupportedValue => PANCAKE_ERR_UNSUPPORTED_VALUE,
        error.InvalidArgument => PANCAKE_ERR_INVALID_ARGUMENT,
        error.NullPointer => PANCAKE_ERR_NULL_POINTER,
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
    };
}

/// `PancakeLastAbort.domain`: which layer classified the failure. Codec is a
/// decode/encode malformation, session is a state-machine refusal, foreign is
/// a host-internal failure (allocation, …).
pub const PANCAKE_ABORT_DOMAIN_CODEC: u32 = 0;
pub const PANCAKE_ABORT_DOMAIN_SESSION: u32 = 1;
pub const PANCAKE_ABORT_DOMAIN_FOREIGN: u32 = 2;

/// The typed cause of a peer's most recent local dispatch failure, projected
/// to C — the ABI counterpart of `engine.Peer.lastAbort`. `domain` is a
/// `PANCAKE_ABORT_DOMAIN_*` value. When `has_kind` is nonzero, `kind_name`
/// is the wire name of the projected `op:abort` kind (e.g. "MalformedFrame");
/// when zero, the failure projected no abort (a closed session, an allocation
/// failure). All byte views are process-static — read them, never free them.
/// Declared in this leaf so the ocapn peer family and the byte-fed driver
/// family (`pancake_host_session_last_abort`) share it by layout.
pub const PancakeLastAbort = extern struct {
    domain: u32,
    has_kind: u32,
    kind_name: ?[*]const u8,
    kind_name_len: usize,
    message: ?[*]const u8,
    message_len: usize,
    error_name: ?[*]const u8,
    error_name_len: usize,
    abort_delivery_error_name: ?[*]const u8,
    abort_delivery_error_name_len: usize,
    /// Process-static name of the first cleanup or consequence failure.
    secondary_error_name: ?[*]const u8,
    /// Length of `secondary_error_name`.
    secondary_error_name_len: usize,
    /// Secondary failures observed; 255 means 255 or more.
    secondary_error_count: u32,
};

/// Project an `engine.AbortInfo` into the C `PancakeLastAbort`. Every view
/// written is process-static.
pub fn lastAbortToC(info: engine.AbortInfo) PancakeLastAbort {
    const abort_delivery_error_name = if (info.abort_delivery_error) |err| @errorName(err) else null;
    const secondary_error_name = if (info.secondary_error) |err| @errorName(err) else null;
    return .{
        .domain = switch (info.domain) {
            .codec => PANCAKE_ABORT_DOMAIN_CODEC,
            .session => PANCAKE_ABORT_DOMAIN_SESSION,
            .foreign => PANCAKE_ABORT_DOMAIN_FOREIGN,
        },
        .has_kind = if (info.kind != null) 1 else 0,
        .kind_name = if (info.kind) |k| k.wireName().ptr else null,
        .kind_name_len = if (info.kind) |k| k.wireName().len else 0,
        .message = info.message.ptr,
        .message_len = info.message.len,
        .error_name = info.error_name.ptr,
        .error_name_len = info.error_name.len,
        .abort_delivery_error_name = if (abort_delivery_error_name) |name| name.ptr else null,
        .abort_delivery_error_name_len = if (abort_delivery_error_name) |name| name.len else 0,
        .secondary_error_name = if (secondary_error_name) |name| name.ptr else null,
        .secondary_error_name_len = if (secondary_error_name) |name| name.len else 0,
        .secondary_error_count = @intCast(info.secondary_error_count),
    };
}

pub fn sliceFromC(ptr: ?[*]const u8, len: usize) MarshalError![]const u8 {
    if (len == 0) return &.{};
    const p = ptr orelse return error.NullPointer;
    return p[0..len];
}

/// Depth bound on a host-supplied argument tree. A foreign caller could nest
/// `PancakeArgument` lists/sets/tagged values arbitrarily deep and overflow the
/// native stack inside `argumentFromC`, exactly as a hostile wire frame could in
/// the codec. Derived from the session's default `max_nesting_depth`, so the
/// marshal boundary and the codec refuse at the same depth by construction.
pub const max_marshal_depth: usize = (engine.SessionLimits{}).max_nesting_depth;

/// One recursive C-value decoder parameterized only by the reference leaf.
/// The Host supplies opaque-id lift/lower policy without cloning the
/// pass-by-copy value algebra.
pub fn argumentFromCWith(
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_from_c: anytype,
    arena: std.mem.Allocator,
    c_arg: PancakeArgument,
    depth: usize,
    comptime own_bytes: bool,
) (MarshalError || RefError)!model.Argument {
    return valueFromCImpl(model.Argument, .reference, RefError, ref_ctx, ref_from_c, arena, c_arg, depth, own_bytes);
}

const ReferenceField = enum { reference, capability };

/// The one conversion recursion behind both marshal lifetimes and both
/// application value spellings. `Output` is either `model.Argument` or an
/// owning tier's isomorphic opaque-capability value. `own_bytes` and the
/// reference field are comptime, so every projection remains straight-line.
fn valueFromCImpl(
    comptime Output: type,
    comptime reference_field: ReferenceField,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_from_c: anytype,
    arena: std.mem.Allocator,
    c_arg: PancakeArgument,
    depth: usize,
    comptime own_bytes: bool,
) (MarshalError || RefError)!Output {
    if (depth > max_marshal_depth) return error.UnsupportedValue;
    const next = depth + 1;
    return switch (c_arg.kind) {
        PANCAKE_ARG_INTEGER => .{ .integer = c_arg.integer },
        PANCAKE_ARG_FLOAT64 => .{ .float64 = c_arg.float64 },
        PANCAKE_ARG_BOOLEAN => .{ .boolean = c_arg.boolean != 0 },
        PANCAKE_ARG_BYTES => .{ .bytes = try leafFromC(arena, c_arg, own_bytes) },
        PANCAKE_ARG_STRING => .{ .string = try leafFromC(arena, c_arg, own_bytes) },
        PANCAKE_ARG_SYMBOL => .{ .symbol = try leafFromC(arena, c_arg, own_bytes) },
        PANCAKE_ARG_ERROR => .{ .@"error" = .{ .message = try leafFromC(arena, c_arg, own_bytes) } },
        PANCAKE_ARG_VOID => .{ .void = {} },
        PANCAKE_ARG_REFERENCE => switch (reference_field) {
            .reference => .{ .reference = try ref_from_c(ref_ctx, c_arg.reference) },
            .capability => .{ .capability = try ref_from_c(ref_ctx, c_arg.reference) },
        },
        PANCAKE_ARG_LIST => .{ .list = try valuesFromCImpl(Output, reference_field, RefError, ref_ctx, ref_from_c, arena, c_arg.items, c_arg.items_len, next, own_bytes) },
        PANCAKE_ARG_SET => .{ .set = try valuesFromCImpl(Output, reference_field, RefError, ref_ctx, ref_from_c, arena, c_arg.items, c_arg.items_len, next, own_bytes) },
        PANCAKE_ARG_TAGGED => .{ .tagged = .{
            .tag = try leafFromC(arena, c_arg, own_bytes),
            .value = try valuesFromCImpl(Output, reference_field, RefError, ref_ctx, ref_from_c, arena, c_arg.items, c_arg.items_len, next, own_bytes),
        } },
        PANCAKE_ARG_KEYWORD => .{ .keyword = try leafFromC(arena, c_arg, own_bytes) },
        PANCAKE_ARG_BIG_INTEGER => blk: {
            const big = model.BigInteger{
                .negative = c_arg.boolean != 0,
                .digits = try leafFromC(arena, c_arg, own_bytes),
            };
            // Fail closed at the boundary, like the codecs: leading zeros,
            // non-digits, or a magnitude that belongs in PANCAKE_ARG_INTEGER.
            if (!big.isCanonical()) break :blk error.UnsupportedValue;
            break :blk .{ .big_integer = big };
        },
        PANCAKE_ARG_STRUCT => .{ .@"struct" = try structFromCImpl(
            Output,
            reference_field,
            RefError,
            ref_ctx,
            ref_from_c,
            arena,
            c_arg.items,
            c_arg.items_len,
            next,
            own_bytes,
        ) },
        else => error.UnsupportedValue,
    };
}

fn structFromCImpl(
    comptime Output: type,
    comptime reference_field: ReferenceField,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_from_c: anytype,
    arena: std.mem.Allocator,
    items: ?[*]const PancakeArgument,
    len: usize,
    depth: usize,
    comptime own_bytes: bool,
) (MarshalError || RefError)![]const std.meta.Child(@FieldType(Output, "struct")) {
    if (len % 2 != 0) return error.UnsupportedValue;
    if (len == 0) return &.{};
    const p = items orelse return error.NullPointer;
    const Entry = std.meta.Child(@FieldType(Output, "struct"));
    const out = try arena.alloc(Entry, len / 2);
    for (out, 0..) |*entry, i| {
        const key_arg = p[i * 2];
        if (key_arg.kind != PANCAKE_ARG_STRING) return error.UnsupportedValue;
        const key = try leafFromC(arena, key_arg, own_bytes);
        for (out[0..i]) |prior| {
            if (std.mem.eql(u8, prior.key, key)) return error.UnsupportedValue;
        }
        entry.* = .{
            .key = key,
            .value = try valueFromCImpl(
                Output,
                reference_field,
                RefError,
                ref_ctx,
                ref_from_c,
                arena,
                p[i * 2 + 1],
                depth,
                own_bytes,
            ),
        };
    }
    return out;
}

/// A leaf's byte slice: borrowed from the C argument, or duped into `arena`
/// when the caller asked for owned bytes.
fn leafFromC(arena: std.mem.Allocator, c_arg: PancakeArgument, comptime own_bytes: bool) MarshalError![]const u8 {
    const borrowed = try sliceFromC(c_arg.bytes, c_arg.bytes_len);
    return if (own_bytes) try arena.dupe(u8, borrowed) else borrowed;
}

pub fn argsFromCWith(
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_from_c: anytype,
    arena: std.mem.Allocator,
    items: ?[*]const PancakeArgument,
    len: usize,
    depth: usize,
    comptime own_bytes: bool,
) (MarshalError || RefError)![]const model.Argument {
    return valuesFromCImpl(model.Argument, .reference, RefError, ref_ctx, ref_from_c, arena, items, len, depth, own_bytes);
}

/// Decode the same C value algebra into an owning tier's opaque-capability
/// value without first manufacturing wire references. `Value` must carry the
/// data arms accepted above plus a `capability` arm of the callback's payload.
pub fn valuesFromCWith(
    comptime Value: type,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_from_c: anytype,
    arena: std.mem.Allocator,
    items: ?[*]const PancakeArgument,
    len: usize,
    depth: usize,
    comptime own_bytes: bool,
) (MarshalError || RefError)![]const Value {
    return valuesFromCImpl(Value, .capability, RefError, ref_ctx, ref_from_c, arena, items, len, depth, own_bytes);
}

fn valuesFromCImpl(
    comptime Output: type,
    comptime reference_field: ReferenceField,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_from_c: anytype,
    arena: std.mem.Allocator,
    items: ?[*]const PancakeArgument,
    len: usize,
    depth: usize,
    comptime own_bytes: bool,
) (MarshalError || RefError)![]const Output {
    if (len == 0) return &.{};
    const p = items orelse return error.NullPointer;
    const out = try arena.alloc(Output, len);
    for (0..len) |i| out[i] = try valueFromCImpl(Output, reference_field, RefError, ref_ctx, ref_from_c, arena, p[i], depth, own_bytes);
    return out;
}

/// One recursive model-value encoder parameterized only by the reference leaf.
pub fn argumentToCWith(
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_to_c: anytype,
    arena: std.mem.Allocator,
    arg: model.Argument,
) (MarshalError || RefError)!PancakeArgument {
    var c_arg = zero_argument;
    switch (arg) {
        .integer => |v| {
            c_arg.kind = PANCAKE_ARG_INTEGER;
            c_arg.integer = v;
        },
        .float64 => |v| {
            c_arg.kind = PANCAKE_ARG_FLOAT64;
            c_arg.float64 = v;
        },
        .boolean => |v| {
            c_arg.kind = PANCAKE_ARG_BOOLEAN;
            c_arg.boolean = if (v) 1 else 0;
        },
        .bytes => |b| {
            c_arg.kind = PANCAKE_ARG_BYTES;
            c_arg.bytes = b.ptr;
            c_arg.bytes_len = b.len;
        },
        .string => |b| {
            c_arg.kind = PANCAKE_ARG_STRING;
            c_arg.bytes = b.ptr;
            c_arg.bytes_len = b.len;
        },
        .symbol => |b| {
            c_arg.kind = PANCAKE_ARG_SYMBOL;
            c_arg.bytes = b.ptr;
            c_arg.bytes_len = b.len;
        },
        .@"error" => |reason| {
            c_arg.kind = PANCAKE_ARG_ERROR;
            c_arg.bytes = reason.message.ptr;
            c_arg.bytes_len = reason.message.len;
        },
        .void => c_arg.kind = PANCAKE_ARG_VOID,
        .reference => |r| {
            c_arg.kind = PANCAKE_ARG_REFERENCE;
            c_arg.reference = try ref_to_c(ref_ctx, r);
        },
        .list => |items| {
            c_arg.kind = PANCAKE_ARG_LIST;
            const arr = try argsToCWith(RefError, ref_ctx, ref_to_c, arena, items);
            c_arg.items = arr.ptr;
            c_arg.items_len = arr.len;
        },
        .set => |items| {
            c_arg.kind = PANCAKE_ARG_SET;
            const arr = try argsToCWith(RefError, ref_ctx, ref_to_c, arena, items);
            c_arg.items = arr.ptr;
            c_arg.items_len = arr.len;
        },
        .tagged => |tagged| {
            c_arg.kind = PANCAKE_ARG_TAGGED;
            c_arg.bytes = tagged.tag.ptr;
            c_arg.bytes_len = tagged.tag.len;
            const arr = try argsToCWith(RefError, ref_ctx, ref_to_c, arena, tagged.value);
            c_arg.items = arr.ptr;
            c_arg.items_len = arr.len;
        },
        .keyword => |keyword| {
            c_arg.kind = PANCAKE_ARG_KEYWORD;
            c_arg.bytes = keyword.ptr;
            c_arg.bytes_len = keyword.len;
        },
        .big_integer => |big| {
            c_arg.kind = PANCAKE_ARG_BIG_INTEGER;
            c_arg.boolean = if (big.negative) 1 else 0;
            c_arg.bytes = big.digits.ptr;
            c_arg.bytes_len = big.digits.len;
        },
        .@"struct" => |entries| {
            c_arg.kind = PANCAKE_ARG_STRUCT;
            const arr = try arena.alloc(PancakeArgument, entries.len * 2);
            for (entries, 0..) |entry, i| {
                var key = zero_argument;
                key.kind = PANCAKE_ARG_STRING;
                key.bytes = entry.key.ptr;
                key.bytes_len = entry.key.len;
                arr[i * 2] = key;
                arr[i * 2 + 1] = try argumentToCWith(RefError, ref_ctx, ref_to_c, arena, entry.value);
            }
            c_arg.items = arr.ptr;
            c_arg.items_len = arr.len;
        },
        // Exhaustive on purpose: the model arms with no C mapping are named
        // here, so a new `model.Argument` arm stops this build at the boundary
        // that must decide how (or whether) the typed surface carries it,
        // rather than degrading silently to the opaque-frame fallback.
        .handoff => return error.UnsupportedValue,
    }
    return c_arg;
}

pub fn argsToCWith(
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_to_c: anytype,
    arena: std.mem.Allocator,
    args: []const model.Argument,
) (MarshalError || RefError)![]PancakeArgument {
    const out = try arena.alloc(PancakeArgument, args.len);
    for (args, 0..) |arg, i| out[i] = try argumentToCWith(RefError, ref_ctx, ref_to_c, arena, arg);
    return out;
}

// ── Transport connection payload lifecycle ───────────────────────────────────

/// Admission barrier for operations entered from foreign threads. The handle's
/// `std.Io` supplies the wait primitive, so this adds no thread, allocation, or
/// process-global runtime. Shutdown may race operations because it never frees
/// the handle: it seals admission and wakes transport work separately. Before
/// release, the foreign owner must prevent new calls and join its own operation
/// leases; `wait` then verifies that every natively admitted call returned.
/// No counter stored inside a C handle can make dereferencing that handle safe
/// against a concurrent free before admission.
pub const ForeignCallBarrier = struct {
    const closing_bit = @as(usize, 1) << (@bitSizeOf(usize) - 1);
    const active_mask = closing_bit - 1;

    gate: std.Io.Mutex = .init,
    drained: std.Io.Condition = .init,
    /// High bit seals admission; low bits count calls that already crossed the
    /// C boundary. Admission and shutdown never wait on the release barrier.
    state: std.atomic.Value(usize) = .init(0),

    pub fn acquire(self: *ForeignCallBarrier, io: std.Io) bool {
        _ = io;
        var state = self.state.load(.acquire);
        while (true) {
            if (state & closing_bit != 0) return false;
            std.debug.assert(state & active_mask != active_mask);
            if (self.state.cmpxchgWeak(state, state + 1, .acquire, .monotonic)) |observed| {
                state = observed;
                continue;
            }
            return true;
        }
    }

    pub fn release(self: *ForeignCallBarrier, io: std.Io) void {
        const previous = self.state.fetchSub(1, .release);
        std.debug.assert(previous & active_mask != 0);
        if (previous & active_mask != 1) return;
        self.gate.lockUncancelable(io);
        self.drained.signal(io);
        self.gate.unlock(io);
    }

    /// Seal admission. True exactly once, so the caller that wins performs the
    /// transport's idempotent wake without every concurrent closer repeating it.
    pub fn beginShutdown(self: *ForeignCallBarrier, io: std.Io) bool {
        _ = io;
        return self.state.fetchOr(closing_bit, .acq_rel) & closing_bit == 0;
    }

    pub fn wait(self: *ForeignCallBarrier, io: std.Io) void {
        self.gate.lockUncancelable(io);
        defer self.gate.unlock(io);
        while (self.state.load(.acquire) & active_mask != 0)
            self.drained.waitUncancelable(io, &self.gate);
    }
};

/// Per-direction serialization for one stream-shaped foreign connection.
/// `ForeignCallBarrier` owns lifetime admission, not stream state: two reads
/// share decoder/spill state and two writes share encoder/buffer state, while
/// one read and one write are valid full-duplex operations. Keeping distinct
/// gates makes that contract structural at every transport archive.
pub const ConnDirectionGates = struct {
    read: std.Io.Mutex = .init,
    write: std.Io.Mutex = .init,
};

/// Modest caps on a stream-shaped transport connection's per-direction buffers.
/// Neither buffer needs to hold a whole frame: `writeAll` streams a large
/// outbound frame straight through the write buffer, and an inbound frame
/// larger than the read buffer accumulates in the connection's bounded spill
/// (`net.Spill`) while it is in flight. Steady per-connection memory is
/// therefore these two buffers, not `max_frame_bytes`.
pub const connection_read_buf_bytes: usize = 16 * 1024;
pub const connection_write_buf_bytes: usize = 64 * 1024;

/// The buffer/payload lifecycle every stream-shaped transport archive's
/// connection handles share (tcp, inproc, and onion; iroh's loop connections
/// carry no buffers). `Payload` declares `stream` (with `shutdown`/`deinit`),
/// `operations`, `directions`, `read_buf`, `write_buf`, and `allocator`. A
/// comptime helper,
/// not an `export fn`, so each archive compiles its own copy and the shared leaf
/// stays symbol-free.
pub fn ConnLifecycle(comptime Payload: type) type {
    return struct {
        const Stream = @TypeOf(@as(Payload, undefined).stream);
        const ShutdownResult = @typeInfo(@TypeOf(Stream.shutdown)).@"fn".return_type.?;

        /// Allocate a connection payload and its buffers, leaving `.stream` for
        /// the caller to install once the connection is established. On any
        /// failure before install, release it with `abort`.
        pub fn begin(alloc: std.mem.Allocator, max_frame_bytes: usize) ?*Payload {
            const read_buf = alloc.alloc(u8, @min(max_frame_bytes, connection_read_buf_bytes)) catch return null;
            const write_buf = alloc.alloc(u8, @min(max_frame_bytes, connection_write_buf_bytes)) catch {
                alloc.free(read_buf);
                return null;
            };
            const payload = alloc.create(Payload) catch {
                alloc.free(read_buf);
                alloc.free(write_buf);
                return null;
            };
            payload.read_buf = read_buf;
            payload.write_buf = write_buf;
            payload.allocator = alloc;
            payload.operations = .{};
            payload.directions = .{};
            return payload;
        }

        /// Release a payload whose `.stream` was never installed.
        pub fn abort(payload: *Payload) void {
            const alloc = payload.allocator;
            alloc.free(payload.read_buf);
            alloc.free(payload.write_buf);
            alloc.destroy(payload);
        }

        /// Seal new operations and interrupt those already blocked in transport
        /// I/O without releasing storage.
        pub fn shutdown(payload: *Payload) ShutdownResult {
            if (payload.operations.beginShutdown(payload.stream.io)) {
                return payload.stream.shutdown();
            }
            return;
        }

        /// Release an established payload: interrupt I/O, join every admitted C
        /// call, then close the stream and free its buffers.
        pub fn destroy(payload: *Payload) ShutdownResult {
            const alloc = payload.allocator;
            // The release is a barrier even when shutdown refuses: admitted
            // calls still join and every owned byte is reclaimed before the
            // exact shutdown result reaches the caller.
            defer {
                payload.operations.wait(payload.stream.io);
                payload.stream.deinit();
                alloc.free(payload.read_buf);
                alloc.free(payload.write_buf);
                alloc.destroy(payload);
            }
            return shutdown(payload);
        }
    };
}

/// The one body behind every stream-shaped `pancake_*_conn_{read,write}_frame`
/// (tcp and inproc). `Payload` declares `stream` (with `readFrame`/`writeFrame`)
/// and `allocator`. A comptime helper, not an `export fn`, so each archive
/// compiles its own copy and the shared leaf stays symbol-free — the archives
/// keep their own exports (ADR-0059). `onConnectionLost` / `onWriteErr`
/// parameterize the last-error message: tcp consults `lastReadError`/
/// `lastWriteError`, inproc records a static cause.
pub fn ConnFrameOps(comptime Payload: type) type {
    return struct {
        pub fn readFrame(
            payload: *Payload,
            out_frame: *PancakeManagedFrame,
            comptime onConnectionLost: fn (*Payload) void,
        ) i32 {
            if (!payload.operations.acquire(payload.stream.io)) return PANCAKE_ERR_CLOSED;
            defer payload.operations.release(payload.stream.io);
            payload.directions.read.lockUncancelable(payload.stream.io);
            defer payload.directions.read.unlock(payload.stream.io);
            const f = payload.stream.readFrame() catch |err| return frameReadErrorToCode(payload, err, onConnectionLost);

            return wrapManagedInto(payload.allocator, f, out_frame, "conn_read_frame");
        }

        pub fn writeFrame(
            payload: *Payload,
            frame_in: *const PancakeFrame,
            comptime onWriteErr: fn (*Payload, anyerror) void,
        ) i32 {
            if (!payload.operations.acquire(payload.stream.io)) return PANCAKE_ERR_CLOSED;
            defer payload.operations.release(payload.stream.io);
            const bytes_ptr = frame_in.bytes orelse return PANCAKE_ERR_NULL_POINTER;
            payload.directions.write.lockUncancelable(payload.stream.io);
            defer payload.directions.write.unlock(payload.stream.io);

            payload.stream.writeFrame(bytes_ptr[0..frame_in.len]) catch |err| {
                onWriteErr(payload, err);
                return PANCAKE_ERR_IO;
            };
            return PANCAKE_OK;
        }

        fn frameReadErrorToCode(
            payload: *Payload,
            err: anytype,
            comptime onConnectionLost: fn (*Payload) void,
        ) i32 {
            return switch (err) {
                error.Closed => PANCAKE_ERR_CLOSED,
                error.MalformedFrame => PANCAKE_ERR_MALFORMED,
                error.FrameTooLarge => PANCAKE_ERR_FRAME_TOO_LARGE,
                error.TruncatedFrame => blk: {
                    setLastError("read_frame: stream closed mid-frame", .{});
                    break :blk PANCAKE_ERR_IO;
                },
                error.ConnectionLost => blk: {
                    onConnectionLost(payload);
                    break :blk PANCAKE_ERR_IO;
                },
                error.OutOfMemory => PANCAKE_ERR_INTERNAL,
            };
        }
    };
}
