//! Construction, configuration, and teardown for one Session aggregate.
//!
//! Session remains the authoritative state container. This module owns the
//! only full initializer and the matching whole-aggregate retirement walk, so
//! adding a retained table cannot acquire a second construction or teardown
//! policy elsewhere.

const std = @import("std");
const model = @import("model");

const answer_notifications = @import("answers/notifications.zig");
const imported_promises = @import("promises/imported.zig");
const limits = @import("limits.zig");
const session = @import("mod.zig");

const BOOTSTRAP_POSITION = session.BOOTSTRAP_POSITION;
const Session = session.Session;
const SessionLimits = limits.SessionLimits;

/// Construction knobs for `initWith`. Every field has a default, so a caller
/// names only what it overrides: `Session.init(allocator)` is
/// `initWith(allocator, .{})`. The knobs are orthogonal, `negotiating` selects
/// the starting state, `limits` sets the resource bounds, and the rest set the
/// profile / codec / features the handshake would otherwise install. The
/// already-open default comes from `model.Preference.default_offer`.
pub const Options = struct {
    /// Start in `negotiating` (awaiting `op:start-session`) instead of `open`.
    negotiating: bool = false,
    codec: model.CodecId = model.Preference.default_offer.codec,
    captp_version: model.CaptpVersion = model.Preference.default_offer.captp_version,
    features: model.FeatureSet = model.Preference.default_offer.features,
    limits: SessionLimits = .{},
    /// The first export position this session hands out.
    ///
    /// A near reference carries only this integer, so it means whatever the
    /// session reading it says it means. Two sessions that both count from the
    /// same place therefore name different objects with the same number, and a
    /// capability offered to the wrong one is not refused: it silently resolves
    /// to whatever that session keeps there. Disjoint host-assigned ranges make
    /// the foreign position absent instead of ambiguous, so the held-export
    /// check refuses it. Bootstrap remains position zero (ADR-0006).
    export_base: u64 = BOOTSTRAP_POSITION + 1,
    /// Positions available past `export_base`. Unbounded without a host range.
    export_span: u64 = std.math.maxInt(u64),
};

/// Move the export allocator to its host-assigned range before it has handed
/// out an export. Asserted rather than tolerated: moving a live range would
/// rename a position the partner already holds.
pub fn setExportBase(self: *Session, base: u64, span: u64) void {
    std.debug.assert(self.exports.len() == 0);
    self.export_base = base;
    self.next_export_position = base;
    self.export_position_end = base +| span;
}

/// Open V1.0 session with all defaults, equivalent to `initWith(allocator, .{})`.
pub fn init(allocator: std.mem.Allocator) Session {
    return initWith(allocator, .{});
}

/// Begin in negotiation on the default profile and feature set. The in-process
/// handshake driver constructs both peers this way. `initWith` can override
/// the negotiated knobs.
pub fn initNegotiating(allocator: std.mem.Allocator) Session {
    return initWith(allocator, .{ .negotiating = true });
}

/// One configured profile is both what this side asks for and what it speaks
/// until the partner hello settles otherwise. Construction and reposture both
/// use this one spelling so neither can advertise a profile the Session does
/// not speak.
pub fn preferenceOf(
    captp_version: model.CaptpVersion,
    codec: model.CodecId,
    features: model.FeatureSet,
) model.Preference {
    return .{ .captp_version = captp_version, .codec = codec, .features = features };
}

/// The one full constructor. Every shorthand delegates here.
pub fn initWith(allocator: std.mem.Allocator, options: Options) Session {
    return .{
        .allocator = allocator,
        .state = if (options.negotiating) .negotiating else .open,
        .captp_version = options.captp_version,
        .codec = options.codec,
        .preferred = preferenceOf(options.captp_version, options.codec, options.features),
        .features = options.features,
        .limits = options.limits,
        // Start past bootstrap at construction, not only once transition to
        // open runs, so a capability registered before open still gets a fresh
        // export rather than colliding with export zero.
        .export_base = options.export_base,
        .next_export_position = options.export_base,
        .export_position_end = options.export_base +| options.export_span,
        .key_arena = std.heap.ArenaAllocator.init(allocator),
        .recv_scratch = std.heap.ArenaAllocator.init(allocator),
        .exports = .empty,
        .imports = .empty,
        .inbound_answers = .empty,
        .outbound_answers = .empty,
        .imported_promises = .empty,
        .handshake_local_sent = false,
        .handshake_remote_received = false,
        .partner_session_key = &.{},
        .local_session_key = &.{},
        .partner_designator = &.{},
        .partner_acceptable_location_raw = &.{},
        .outbound_resolver_link = .empty,
        .v1_0_inbound_resolver_link = .empty,
        .sturdyref_cache = .empty,
        .sturdyref_cache_index = .empty,
        .pending_enlivens = .empty,
        .pending_enliven_by_answer = .empty,
        .bootstrap = .empty,
    };
}

/// Retire every Session-owned allocation exactly once.
pub fn deinit(self: *Session) void {
    self.exports.deinit(self.allocator);
    self.imports.deinit(self.allocator);
    self.inbound_answers.deinit(self.allocator);
    self.outbound_answers.deinit(self.allocator);
    answer_notifications.deinitDetached(self);
    // Bootstrap key bytes live in `key_arena`, freed wholesale below.
    self.bootstrap.deinit(self.allocator);
    var imported_it = self.imported_promises.valueIterator();
    while (imported_it.next()) |entry| imported_promises.deinitImportedPromise(self.allocator, entry);
    self.imported_promises.deinit(self.allocator);
    self.outbound_resolver_link.deinit(self.allocator);
    self.v1_0_inbound_resolver_link.deinit(self.allocator);
    // Drop the index before row swissnums because its keys alias those slices.
    self.sturdyref_cache_index.deinit(self.allocator);
    for (self.sturdyref_cache.items) |entry| self.allocator.free(entry.swissnum);
    self.sturdyref_cache.deinit(self.allocator);
    var enliven_it = self.pending_enlivens.keyIterator();
    while (enliven_it.next()) |key| self.allocator.free(key.*);
    self.pending_enlivens.deinit(self.allocator);
    self.pending_enliven_by_answer.deinit(self.allocator);
    self.key_arena.deinit();
    self.recv_scratch.deinit();
}
