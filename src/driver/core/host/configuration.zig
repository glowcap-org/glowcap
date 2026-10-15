//! Host construction and future-session configuration vocabulary.
//!
//! Options describe one Host and the peers it will mint. The Host remains the
//! state aggregate. This owner holds the configuration shape and the one
//! admitted mutation that updates only future sessions.

const std = @import("std");
const actors = @import("actors");

const model = @import("model");
const engine = @import("engine");

const host_mod = @import("../host.zig");
const capability = @import("../capability.zig");
const admission = @import("admission.zig");
const served = @import("../served.zig");

const Host = host_mod.Host;

/// Construction refusals happen before a Host is published. Embedders decide
/// whether they are process-fatal. The core never makes that policy choice with
/// a panic.
pub const InitError = error{InvalidHostWorkQuantum};

pub const Options = struct {
    /// Full CapTP session limits applied to every minted peer (ADR-0082).
    /// Defaults match `session.SessionLimits{}`, including the 1 MiB
    /// `max_frame_bytes` the driver C ABI publishes as
    /// `GLOWCAP_DEFAULT_FRAME_CAP`. The completion loop's read buffers come
    /// from a shared 16 KiB pool (ADR-0054), not from `max_frame_bytes`, so
    /// raising the admission cap costs no per-session memory.
    limits: engine.SessionLimits = .{},
    /// Verify the partner's `op:start-session` signature. This is the secure
    /// default a real peer keeps.
    verify_partner: bool = true,
    /// The wire grammar this host *prefers*. What a given session speaks is
    /// settled with its partner, not imposed from here (ADR-0103), so two ends
    /// need not be configured alike: a partner that cannot follow settles this
    /// axis back to the baseline on its own session and every other session
    /// keeps the preference.
    codec: model.CodecId = model.Preference.default_offer.codec,
    /// The CapTP profile this host prefers, beside the codec above. The two are
    /// one decision rather than two knobs, and both default to
    /// `model.Preference.default_offer`.
    ///
    /// `next` is a wire difference rather than a label: V1.0 has no Zig
    /// `op:resolve`, so an answer settles through a `resolve_me_desc` callback
    /// there and through a resolve on `next`. A hello states this preference in
    /// its locator hints and the two sides settle from the pair, so a host may
    /// prefer `next` and still hold baseline sessions with peers that do not.
    captp_version: model.CaptpVersion = model.Preference.default_offer.captp_version,
    /// Optional CapTP features this host offers. Defaults to
    /// `model.Preference.default_offer.features`. Each session intersects this
    /// set with the partner's offer at handshake. A peer with no Glowcap
    /// feature hint gets the baseline compatibility set, which keeps outbound
    /// `op:untag` disabled without changing the session's OCapN version.
    features: model.FeatureSet = model.Preference.default_offer.features,
    /// Per-session amplification cap. A session that still has local work
    /// after this many turns is condemned, so one partner that keeps its
    /// calls amplifying cannot starve the others sharing this Host's Vat. It
    /// is not the Host scheduler quantum. `null` turns the cap off, which is
    /// safe only when every partner is trusted.
    local_turn_budget: ?usize = served.default_loop_local_turn_budget,
    /// Host-wide release-on-drop setting (ADR-0192): whether a far capability
    /// a binding projects to its application releases its Host retain when
    /// the language's scope end for that value is observed. The core stores
    /// and reports it through `Host.releaseOnDrop` and
    /// `Host.setReleaseOnDrop` and attaches no behavior to it. A binding whose
    /// release rides a finalizer passes false and keeps its per-session
    /// opt-in.
    release_on_drop: bool = true,
    /// Host-wide resumable work quantum. Every quantum round-robins dirty
    /// sessions, Node effects, and handoff notifications, requeueing
    /// continuation work at the FIFO tail, and a `resume_work` action carries
    /// the rest into the next drain. Zero is refused at construction: a Host
    /// always yields, so one hot session cannot hold the pump.
    host_work_quantum: usize = 64,
    /// Optional core issuer for capability ids projected without their
    /// Registry pointer. Zig `Ref` equality carries that pointer and leaves
    /// this null.
    capability_id_issuer: ?capability.IdIssuer = null,
    /// Retained outbound-work waterline for one byte-fed session. A producer
    /// that starts below it commits atomically and may cross it by one bounded
    /// operation. The next host-driving producer refuses `OutboundBackpressure`
    /// until frames drain. Null derives from `max_frame_bytes`.
    outbound_high_water_bytes: ?usize = null,

    /// Convenience for the common case: default Options with only the frame
    /// admission cap overridden.
    pub fn withFrameCap(cap: usize) Options {
        var options: Options = .{};
        options.limits.max_frame_bytes = cap;
        return options;
    }

    /// Admission cap shortcut (`limits.max_frame_bytes`).
    pub fn frameCap(self: Options) usize {
        return self.limits.max_frame_bytes;
    }

    pub fn outboundHighWaterBytes(self: Options) usize {
        return self.outbound_high_water_bytes orelse
            std.math.mul(usize, self.limits.max_frame_bytes, 2) catch std.math.maxInt(usize);
    }
};

/// The Host-wide release-on-drop setting (ADR-0192), read by the binding that
/// projects a far capability.
pub fn releaseOnDrop(self: *const Host) bool {
    return self.opts.release_on_drop;
}

/// Change the release-on-drop setting for values projected after this call.
/// Admitted like every other configuration mutation: on the owning thread,
/// outside a callback, before close.
pub fn setReleaseOnDrop(self: *Host, enabled: bool) error{ ReenteredHost, WrongThread, HostClosing }!void {
    try admission.admitConfigurationMutation(self);
    self.opts.release_on_drop = enabled;
}

/// Override selective session limits before minting peers (ADR-0124). `null`
/// leaves that field unchanged. Already-open sessions keep the limits they
/// were minted with.
pub fn setSessionLimits(
    self: *Host,
    max_frame_bytes: ?usize,
    queue_cap: ?usize,
    outbound_high_water_bytes: ?usize,
    max_retained_sent_answer_bytes: ?u32,
) error{ ReenteredHost, WrongThread, HostClosing }!void {
    try admission.admitConfigurationMutation(self);
    if (max_frame_bytes) |value| self.opts.limits.max_frame_bytes = value;
    if (queue_cap) |value| self.opts.limits.queue_cap = value;
    if (outbound_high_water_bytes) |value| self.opts.outbound_high_water_bytes = value;
    if (max_retained_sent_answer_bytes) |value| {
        self.opts.limits.max_retained_sent_answer_bytes = value;
    }
}

/// Configure the Vat's independent per-ingress queue budget at bootstrap,
/// before any session or eventual send. Bounds include message spines and
/// queue rows, not just application bytes. Backing remains demand allocated.
pub fn setIngressLimits(self: *Host, limits: actors.QueueLimits) error{ ReenteredHost, WrongThread, HostClosing, InvalidArgument, HostNotQuiescent }!void {
    try admission.admitConfigurationMutation(self);
    if (limits.max_pending_turns == 0 or limits.max_chunk_bytes == 0 or
        limits.max_chunk_bytes > limits.max_pending_bytes) return error.InvalidArgument;
    if (self.vat.ingresses.rowCount() != 0 or self.next_vow != 1 or self.vat.next_vow != 1)
        return error.HostNotQuiescent;
    self.vat.queue_limits = limits;
}
