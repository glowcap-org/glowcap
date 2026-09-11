//! Host construction and future-session configuration vocabulary.
//!
//! Options describe one Host and the peers it will mint. The Host remains the
//! state aggregate; this owner holds the configuration shape and the one
//! admitted mutation that updates only future sessions.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");

const host_mod = @import("../host.zig");
const capability = @import("../capability.zig");
const admission = @import("admission.zig");

const Host = host_mod.Host;

/// Bootstrap / sturdyref registry durability (ADR-0082). `ephemeral` is
/// today's process-lifetime registry. `durable_bootstrap` names the
/// embedder-store posture; selecting it is refused until a store is wired
/// (no silent ephemeral twin).
pub const BootstrapDurability = enum { ephemeral, durable_bootstrap };

/// Construction refusals happen before a Host is published. Embedders decide
/// whether they are process-fatal; the core never makes that policy choice
/// with a panic.
pub const InitError = error{
    DurableBootstrapUnavailable,
    InvalidHostWorkQuantum,
};

pub const Options = struct {
    /// Full CapTP session limits applied to every minted peer (ADR-0082).
    /// Defaults match `session.SessionLimits{}`, including the 1 MiB
    /// `max_frame_bytes` the driver C ABI publishes as
    /// `GLOWCAP_DEFAULT_FRAME_CAP`. The completion loop's read buffers come
    /// from a shared 16 KiB pool (ADR-0054), not from `max_frame_bytes`, so
    /// raising the admission cap costs no per-session memory.
    limits: engine.SessionLimits = .{},
    /// Registry durability posture (ADR-0082). `.ephemeral` is live;
    /// `.durable_bootstrap` fails closed at `Host.init` until an embedder store
    /// lands.
    bootstrap_durability: BootstrapDurability = .ephemeral,
    /// Verify the partner's `op:start-session` signature — the secure default a
    /// real peer keeps.
    verify_partner: bool = true,
    /// The wire grammar this host *prefers*. What a given session speaks is
    /// settled with its partner, not imposed from here (ADR-0103), so two ends
    /// no longer have to be configured alike: a partner that cannot follow
    /// settles this axis back to the baseline on its own session and every
    /// other session keeps the preference.
    codec: model.CodecId = model.Preference.default_offer.codec,
    /// The CapTP profile this host prefers, beside the codec above. The two are
    /// one decision rather than two knobs, and both default to
    /// `model.Preference.default_offer`.
    ///
    /// `next` is a wire difference rather than a label: V1.0 has no native
    /// `op:resolve`, so an answer settles through a `resolve_me_desc` callback
    /// there and through a resolve on `next`. A hello states this preference in
    /// its locator hints and the two sides settle from the pair, so a host may
    /// prefer `next` and still hold baseline sessions with peers that do not.
    captp_version: model.CaptpVersion = model.Preference.default_offer.captp_version,
    /// Optional CapTP features this host offers. Defaults to
    /// `model.Preference.default_offer.features`; each session intersects this
    /// set with the partner's offer at handshake. A peer with no Glowcap
    /// feature hint gets the baseline compatibility set, which keeps outbound
    /// `op:untag` disabled without changing the session's OCapN version.
    features: model.FeatureSet = model.Preference.default_offer.features,
    /// Per-session amplification cap. When set, a session that still has local
    /// work after this many turns is condemned; this is an explicit
    /// untrusted/self-amplification policy, not the Host scheduler quantum.
    local_turn_budget: ?usize = null,
    /// Host-wide resumable work quantum. Every quantum round-robins dirty
    /// sessions, Node effects, and handoff notifications, requeueing
    /// continuation work at the FIFO tail, and a `resume_work` action carries
    /// the rest into the next drain. Zero is refused at construction: a Host
    /// always yields, so one hot session cannot hold the pump.
    host_work_quantum: usize = 64,
    /// Optional core issuer for capability ids projected without their
    /// Registry pointer. Native `Ref` equality carries that pointer and leaves
    /// this null.
    capability_id_issuer: ?capability.IdIssuer = null,
    /// Retained outbound-work waterline for one byte-fed session. A producer
    /// that starts below it commits atomically and may cross it by one bounded
    /// operation; the next host-driving producer refuses
    /// `OutboundBackpressure` until frames drain. Null derives from
    /// `max_frame_bytes`.
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
