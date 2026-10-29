//! Byte-fed Host session creation, close progression, and final release.
//!
//! This family owns the complete transport-session shell lifetime. Byte
//! pumping and CapTP verbs live in `session.zig`. Neither may invent a second
//! close policy or consume the shell outside this barrier.

const model = @import("model");
const driver_core = @import("driver_core");

const shared = @import("c_abi_shared");
const c = @import("../mod.zig");
const common = @import("../common.zig");

const instanceFrom = common.instanceFrom;
const sessionFrom = common.sessionFrom;
const instOf = common.instOf;
const errToCode = common.errToCode;

const GlowcapHost = c.GlowcapHost;
const GlowcapHostSession = c.GlowcapHostSession;

const GLOWCAP_OK = shared.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = shared.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = shared.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_WOULD_BLOCK = shared.GLOWCAP_ERR_WOULD_BLOCK;
const GLOWCAP_ERR_CLOSED = shared.GLOWCAP_ERR_CLOSED;

fn sessionCloseOutcomeCode(inst: *const common.Instance, session: *const driver_core.HostSession) i32 {
    const delivered = inst.core.sessionCloseActionDelivered(session);
    return if (inst.core.sessionCloseOutcome(session, delivered) == .timed_out)
        shared.GLOWCAP_ERR_TIMEOUT
    else
        GLOWCAP_OK;
}

fn projectSessionLifecycle(inst: *const common.Instance, session: *const driver_core.HostSession) u32 {
    const delivered = inst.core.sessionCloseActionDelivered(session);
    return switch (inst.core.sessionCloseOutcome(session, delivered)) {
        .closed, .timed_out => c.GLOWCAP_LIFECYCLE_CLOSED,
        .pending => switch (session.lifecyclePhase()) {
            .active => c.GLOWCAP_LIFECYCLE_ACTIVE,
            .finishing => c.GLOWCAP_LIFECYCLE_FINISHING,
            .cancel_pending => c.GLOWCAP_LIFECYCLE_TERMINATING,
            .terminating => c.GLOWCAP_LIFECYCLE_TERMINATING,
        },
    };
}

fn progressSessionCloses(inst: *common.Instance, now_ms: i64) i32 {
    inst.core.progressSessionCloses(now_ms) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Seal application admission for one session and begin or escalate its
/// terminal close. The caller supplies time. The core retains the deadline and
/// owns escalation while the embedder keeps driving bytes.
pub fn glowcap_host_session_close(
    raw: ?*GlowcapHostSession,
    options: ?*const c.GlowcapCloseOptions,
    now_ms: i64,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    if (!common.embedderOwnsDrive(inst, "session_close")) return GLOWCAP_ERR_INVALID_ARGUMENT;
    const policy = c.parseCloseOptions(options) catch |err| return c.closeOptionsErrorCode("host", err);
    inst.core.beginSessionClose(session, policy, now_ms) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Apply the caller's current monotonic time to one byte-fed session close.
pub fn glowcap_host_session_close_progress(
    raw: ?*GlowcapHostSession,
    now_ms: i64,
    out_state: ?*u32,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    if (!common.embedderOwnsDrive(inst, "session_close_progress")) return GLOWCAP_ERR_INVALID_ARGUMENT;
    const slot = out_state orelse return GLOWCAP_ERR_NULL_POINTER;
    const rc = progressSessionCloses(inst, now_ms);
    if (rc != GLOWCAP_OK) return rc;
    slot.* = projectSessionLifecycle(inst, session);
    return sessionCloseOutcomeCode(inst, session);
}

/// Observe one byte-fed session's owner lifecycle. CLOSED means the retryable
/// close action crossed its delivery boundary. Release remains separate and
/// frees the retained shell.
///
/// Binding close-input observation names one call-scoped u32 projection in
/// Python, TypeScript, and Racket. Only a locally closing pump asks before dispatch:
/// FINISH still admits input that can fail, while TERMINATING does not. The
/// storage dies before feed begins. Reusing writer scratch could overwrite a
/// prefix borrowed across an asynchronous write, and retaining another field
/// charges every live session for a close-only observation. Active feeds skip
/// the query and Rust keeps its out slot on the stack.
pub fn glowcap_host_session_lifecycle_state(raw: ?*GlowcapHostSession, out_state: ?*u32) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    if (!common.embedderOwnsDrive(inst, "session_lifecycle_state")) return GLOWCAP_ERR_INVALID_ARGUMENT;
    const slot = out_state orelse return GLOWCAP_ERR_NULL_POINTER;
    slot.* = projectSessionLifecycle(inst, session);
    return sessionCloseOutcomeCode(inst, session);
}

/// Mint the dialing half of a session over a byte channel the embedder has
/// already realized for `locator`. The one locator vocabulary is taken whole
/// rather than re-decomposed at every call site: the designator keys
/// duplicate-dial refusal and, on a key transport, demands the partner's
/// durable key, while route hints carry no semantics here because the
/// caller's dial executor spent them realizing the channel. A DIAL action
/// carries only `ticket`: borrow the pending view with
/// `glowcap_host_pending_dial` and pass it back here after opening the
/// channel. The host retains its own dial default for the locator's
/// transport first, never displacing an advertised locator the embedder
/// explicitly selected, so a bare client host dials without publishing
/// anything.
/// The keyed `op:start-session` is signed under the host identity and encoded
/// before this returns, so drain `take_outbound` (a FLUSH action is queued) and
/// drive the handshake byte-fed. Host-wide aliases remain lazily discoverable
/// through the new session. Sealed sessions derive their Noise ephemeral from
/// the Host's unique per-session seed under a separate KDF domain. Callers do
/// not branch on transport policy or supply per-open entropy.
/// `*out_session` is host-owned. Release with `glowcap_host_session_release`.
pub fn glowcap_host_session_open_dialed_locator(
    host: ?*GlowcapHost,
    locator: ?*const shared.GlowcapLocatorView,
    out_session: ?*?*GlowcapHostSession,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(host) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "session_open_dialed_locator")) return GLOWCAP_ERR_INVALID_ARGUMENT;
    const slot = out_session orelse return GLOWCAP_ERR_NULL_POINTER;
    const view = locator orelse return GLOWCAP_ERR_NULL_POINTER;
    var hint_stack: [shared.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = shared.locator_adapter.BorrowedLocator.init(inst.allocator, view, &hint_stack) catch |err| {
        if (err == error.OutOfMemory) return errToCode(err);
        shared.setLastError("host: session_open_dialed_locator received an invalid locator view", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    };
    defer borrowed.deinit(inst.allocator);
    inst.core.ensureAdvertisedLocator(borrowed.value.transport) catch |err| return errToCode(err);
    const session = inst.core.openDialedLocator(borrowed.value) catch |err| return errToCode(err);
    slot.* = @ptrCast(session);
    return GLOWCAP_OK;
}

/// Mint the accepting half of a session over the connection the embedder's
/// listener produced. `designator_scheme`, `server_designator`, and
/// `accepted_local_addr` resolve what this accept would sign (the listener's
/// signing designator for a key transport. The accepted local address for an
/// address transport), and the host retains that locator without displacing an
/// acceptable location the embedder already selected: an explicit
/// `glowcap_host_set_advertised_locator` is deployment policy and wins, and
/// the accept-derived locator becomes the selection only when there is none.
/// The session signs the selected snapshot even when it names another
/// transport. Sealed-channel entropy follows the dialed half's Host-owned
/// derivation.
pub fn glowcap_host_session_open_accepted(
    host: ?*GlowcapHost,
    transport: ?[*]const u8,
    transport_len: usize,
    designator_scheme: u32,
    server_designator: ?[*]const u8,
    server_designator_len: usize,
    accepted_local_addr: ?[*]const u8,
    accepted_local_addr_len: usize,
    out_session: ?*?*GlowcapHostSession,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(host) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "session_open_accepted")) return GLOWCAP_ERR_INVALID_ARGUMENT;
    const slot = out_session orelse return GLOWCAP_ERR_NULL_POINTER;
    const transport_bytes = shared.sliceFromC(transport, transport_len) catch |err| return shared.marshalErrorToCode(err);
    const sd = shared.sliceFromC(server_designator, server_designator_len) catch |err| return shared.marshalErrorToCode(err);
    const la = shared.sliceFromC(accepted_local_addr, accepted_local_addr_len) catch |err| return shared.marshalErrorToCode(err);
    const scheme: model.transport.DesignatorScheme = switch (designator_scheme) {
        c.GLOWCAP_DESIGNATOR_SCHEME_ADDRESS => .address,
        c.GLOWCAP_DESIGNATOR_SCHEME_KEY => .key,
        else => {
            shared.setLastError("host: session_open_accepted designator_scheme is not a GLOWCAP_DESIGNATOR_SCHEME_* value", .{});
            return GLOWCAP_ERR_INVALID_ARGUMENT;
        },
    };
    inst.core.ensureAcceptAdvertisedLocator(scheme, sd, la, transport_bytes) catch |err| return errToCode(err);
    const session = inst.core.openAcceptedAdvertised(transport_bytes) catch |err| return errToCode(err);
    slot.* = @ptrCast(session);
    return GLOWCAP_OK;
}

/// Release one session: its still-parked far vows break (their FAIL
/// completions queue inside this call) and the node retires it. Stranded
/// withdraws fail closed, so *sibling* sessions' vows may break here
/// too. The shell is freed. Null is a no-op. Refused (last error set,
/// the session kept) from inside a callback. Once teardown commits this returns
/// success. Targeted handoff wake work remains queued across allocator pressure.
/// Another cleanup failure condemns surviving sessions because retrying this
/// consumed handle would be invalid.
pub fn glowcap_host_session_release(raw: ?*GlowcapHostSession) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_OK;
    const inst = instOf(session.host);
    if (!common.embedderOwnsDrive(inst, "session_release")) return GLOWCAP_ERR_INVALID_ARGUMENT;
    inst.core.releaseSession(session) catch |err| {
        const code = errToCode(err);
        shared.setLastError("host: session_release: {s}", .{@errorName(err)});
        return code;
    };
    return GLOWCAP_OK;
}

/// Nonzero once the keyed handshake has completed and the session is open.
pub fn glowcap_host_session_is_open(raw: ?*GlowcapHostSession) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return 0;
    return if (session.sessionOpen()) 1 else 0;
}

/// Read the complete profile this session settled with its partner. All three
/// outputs are required and written together. Before the keyed handshake opens,
/// no settled profile exists and the call returns `GLOWCAP_ERR_WOULD_BLOCK`.
/// After the CapTP session becomes terminal it returns `GLOWCAP_ERR_CLOSED`.
pub fn glowcap_host_session_profile(
    raw: ?*GlowcapHostSession,
    out_captp_version: ?*u32,
    out_codec: ?*u32,
    out_features: ?*u32,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const version = out_captp_version orelse return GLOWCAP_ERR_NULL_POINTER;
    const codec = out_codec orelse return GLOWCAP_ERR_NULL_POINTER;
    const features = out_features orelse return GLOWCAP_ERR_NULL_POINTER;
    if (session.isTerminating()) return GLOWCAP_ERR_CLOSED;
    const profile = session.settledProfile() orelse
        return if (session.sessionClosed()) GLOWCAP_ERR_CLOSED else GLOWCAP_ERR_WOULD_BLOCK;
    version.* = shared.captpVersionToC(profile.captp_version);
    codec.* = shared.codecToC(profile.codec);
    features.* = shared.featureSetToC(profile.features);
    return GLOWCAP_OK;
}

/// Borrow the actual netlayer symbol this session was opened through. Both
/// outputs are required and remain valid until the session is released.
pub fn glowcap_host_session_transport_name(
    raw: ?*GlowcapHostSession,
    out_name: ?*?[*]const u8,
    out_name_len: ?*usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const name = out_name orelse return GLOWCAP_ERR_NULL_POINTER;
    const len = out_name_len orelse return GLOWCAP_ERR_NULL_POINTER;
    name.* = session.transport.ptr;
    len.* = session.transport.len;
    return GLOWCAP_OK;
}

/// The id the live trace names this session's rows by (`GlowcapTraceEvent`'s
/// `session`), so an embedder can annotate the same session a trace consumer
/// is watching. Stable for the session's life and never reused by this host.
pub fn glowcap_host_session_trace_id(
    raw: ?*GlowcapHostSession,
    out_id: ?*u64,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const out = out_id orelse return GLOWCAP_ERR_NULL_POINTER;
    out.* = session.peer_handle.int();
    return GLOWCAP_OK;
}
