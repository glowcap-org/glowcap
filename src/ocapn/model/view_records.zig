//! Record-like borrowed model views.
//!
//! `view.zig` keeps the lazy sequence and argument traversal machinery. This
//! module owns simple record projections whose materialization does not depend on
//! those lazy containers.

const std = @import("std");

const model = @import("mod.zig");

pub const ProjectError = error{MalformedView};
pub const Error = ProjectError || std.mem.Allocator.Error;

/// Borrowed mirror of `model.BreakReason`: the OCapN `<error message>` record
/// as a break payload, a broken-reference reason, or an `error` argument.
pub const BreakReason = struct {
    message: []const u8,

    pub fn toOwned(self: BreakReason, allocator: std.mem.Allocator) Error!model.BreakReason {
        return .{ .message = try allocator.dupe(u8, self.message) };
    }
};

/// Lazy hint-entry packing left by a codec. Cap'n Proto fills `w0`/`w1`/`w2`,
/// Syrup leaves them zero. The only owned path is `materialize` (one walk,
/// Cap'n caches the frame reader, Syrup re-parses once). No `len`/`at`: those
/// invited O(n) from-start re-walks nobody on the production path called.
pub const HintList = struct {
    bytes: []const u8 = &.{},
    w0: u64 = 0,
    w1: u64 = 0,
    w2: u64 = 0,
    vtable: *const VTable,

    pub const VTable = struct {
        materialize: *const fn (std.mem.Allocator, HintList, model.Hints.WireForm) Error!model.Hints,
        /// Validate dictionary shape without materializing entries.
        validate_shape: *const fn (HintList, model.Hints.WireForm) ProjectError!void,
        /// Borrowed find-by-name: the named entry's value borrowing the frame,
        /// or null when absent. Allocation-free by contract so callers need not
        /// materialize the dict.
        find: *const fn (HintList, name: []const u8) Error!?model.HintValue,
    };
};

/// Borrowed hint shape: exactly one arm, empty spelling, projected entries, or
/// a lazy codec list.
pub const BorrowedHints = union(enum) {
    empty: model.Hints.WireForm,
    projected: model.Hints,
    lazy: struct {
        wire_form: model.Hints.WireForm,
        list: HintList,
    },

    pub fn wireForm(self: BorrowedHints) model.Hints.WireForm {
        return switch (self) {
            .empty => |wf| wf,
            .projected => |h| h.wire_form,
            .lazy => |l| l.wire_form,
        };
    }

    pub fn toOwned(self: BorrowedHints, allocator: std.mem.Allocator) Error!model.Hints {
        return switch (self) {
            .empty => |wf| .{ .wire_form = wf },
            .projected => |h| try model.cloneHints(allocator, h),
            .lazy => |l| try l.list.vtable.materialize(allocator, l.list, l.wire_form),
        };
    }

    /// The named hint entry's value, borrowed from whatever backs this view,
    /// or null when the hint is absent. Never allocates: the projected arm
    /// scans its entries and the lazy arm walks the codec's list in place.
    pub fn findNamed(self: BorrowedHints, name: []const u8) Error!?model.HintValue {
        switch (self) {
            .empty => return null,
            .projected => |h| {
                for (h.entries) |entry| {
                    if (std.mem.eql(u8, entry.name, name)) return entry.value;
                }
                return null;
            },
            .lazy => |l| return l.list.vtable.find(l.list, name),
        }
    }

    pub fn validateShape(self: BorrowedHints) ProjectError!void {
        switch (self) {
            .empty => {},
            .projected => |h| model.validateHints(h) catch return error.MalformedView,
            .lazy => |l| try l.list.vtable.validate_shape(l.list, l.wire_form),
        }
    }

    /// Stack-only URI spelling when no allocation is required. `null` means the
    /// caller must `toOwned` (lazy list).
    pub fn stackUriHints(self: BorrowedHints) ?model.Hints {
        return switch (self) {
            .empty => |wf| if (wf == .boolean_false) model.Hints.emptyFalse() else model.Hints.emptyMap().forUriExport(),
            .projected => |h| h.forUriExport(),
            .lazy => null,
        };
    }
};

/// Borrowed mirror of `model.PeerLocator`.
pub const PeerLocator = struct {
    transport: []const u8,
    designator: []const u8,
    hints: BorrowedHints = .{ .empty = .map },

    pub fn fromOwned(owned: *const model.PeerLocator) PeerLocator {
        return .{
            .transport = owned.transport,
            .designator = owned.designator,
            .hints = if (owned.hints.entries.len == 0)
                .{ .empty = owned.hints.wire_form }
            else
                .{ .projected = owned.hints },
        };
    }

    pub fn toOwned(self: PeerLocator, allocator: std.mem.Allocator) Error!model.PeerLocator {
        const transport = try allocator.dupe(u8, self.transport);
        errdefer allocator.free(transport);
        const designator = try allocator.dupe(u8, self.designator);
        errdefer allocator.free(designator);
        const hints = try self.hints.toOwned(allocator);
        return .{ .transport = transport, .designator = designator, .hints = hints };
    }
};

/// A handoff signature, in whichever shape its codec carried it.
pub const Signature = union(enum) {
    raw: []const u8,
    halves: struct { r: []const u8, s: []const u8 },

    pub fn toOwned(self: Signature, allocator: std.mem.Allocator) Error![]u8 {
        return switch (self) {
            .raw => |bytes| allocator.dupe(u8, bytes),
            .halves => |h| blk: {
                const out = try allocator.alloc(u8, h.r.len + h.s.len);
                @memcpy(out[0..h.r.len], h.r);
                @memcpy(out[h.r.len..], h.s);
                break :blk out;
            },
        };
    }

    /// Whether two signatures spell the same bytes, whichever arm each codec
    /// filled. Syrup carries the halves and Cap'n Proto the concatenation, so
    /// two views of one signature can disagree on arm and agree on value. A
    /// comparison that reads either arm directly answers wrongly at best and
    /// panics on the arm that is not there. Total and allocation-free: the
    /// cross-arm case walks the raw bytes in two spans rather than joining the
    /// halves.
    pub fn eql(self: Signature, other: Signature) bool {
        return switch (self) {
            .raw => |bytes| switch (other) {
                .raw => |o| std.mem.eql(u8, bytes, o),
                .halves => |h| rawEqualsHalves(bytes, h.r, h.s),
            },
            .halves => |h| switch (other) {
                .raw => |o| rawEqualsHalves(o, h.r, h.s),
                .halves => |o| std.mem.eql(u8, h.r, o.r) and std.mem.eql(u8, h.s, o.s),
            },
        };
    }

    fn rawEqualsHalves(raw: []const u8, r: []const u8, s: []const u8) bool {
        return raw.len == r.len + s.len and
            std.mem.eql(u8, raw[0..r.len], r) and
            std.mem.eql(u8, raw[r.len..], s);
    }
};

/// Borrowed mirror of `model.HandoffGive`.
pub const HandoffGive = struct {
    recipient_key: []const u8,
    exporter: PeerLocator,
    gifter_exporter_session: []const u8,
    gifter_side: []const u8,
    gift_id: []const u8,
    signature: Signature,
    raw_signed: ?[]const u8 = null,

    fn fromOwned(owned: *const model.HandoffGive) HandoffGive {
        return .{
            .recipient_key = owned.recipient_key,
            .exporter = PeerLocator.fromOwned(&owned.exporter),
            .gifter_exporter_session = owned.gifter_exporter_session,
            .gifter_side = owned.gifter_side,
            .gift_id = owned.gift_id,
            .signature = .{ .raw = owned.signature },
            .raw_signed = owned.raw_signed,
        };
    }

    pub fn toOwned(self: HandoffGive, allocator: std.mem.Allocator) Error!model.HandoffGive {
        const recipient_key = try allocator.dupe(u8, self.recipient_key);
        errdefer allocator.free(recipient_key);
        const exporter = try self.exporter.toOwned(allocator);
        errdefer model.freePeerLocator(allocator, exporter);
        const gifter_exporter_session = try allocator.dupe(u8, self.gifter_exporter_session);
        errdefer allocator.free(gifter_exporter_session);
        const gifter_side = try allocator.dupe(u8, self.gifter_side);
        errdefer allocator.free(gifter_side);
        const gift_id = try allocator.dupe(u8, self.gift_id);
        errdefer allocator.free(gift_id);
        const signature = try self.signature.toOwned(allocator);
        errdefer allocator.free(signature);
        const raw_signed = if (self.raw_signed) |raw| try allocator.dupe(u8, raw) else null;
        return .{
            .recipient_key = recipient_key,
            .exporter = exporter,
            .gifter_exporter_session = gifter_exporter_session,
            .gifter_side = gifter_side,
            .gift_id = gift_id,
            .signature = signature,
            .raw_signed = raw_signed,
        };
    }
};

/// Borrowed mirror of `model.HandoffReceive`.
pub const HandoffReceive = struct {
    receiving_session: []const u8,
    receiving_side: []const u8,
    handoff_count: u64,
    signed_give: HandoffGive,
    signature: Signature,

    fn fromOwned(owned: *const model.HandoffReceive) HandoffReceive {
        return .{
            .receiving_session = owned.receiving_session,
            .receiving_side = owned.receiving_side,
            .handoff_count = owned.handoff_count,
            .signed_give = HandoffGive.fromOwned(&owned.signed_give),
            .signature = .{ .raw = owned.signature },
        };
    }

    pub fn toOwned(self: HandoffReceive, allocator: std.mem.Allocator) Error!model.HandoffReceive {
        const receiving_session = try allocator.dupe(u8, self.receiving_session);
        errdefer allocator.free(receiving_session);
        const receiving_side = try allocator.dupe(u8, self.receiving_side);
        errdefer allocator.free(receiving_side);
        const signed_give = try self.signed_give.toOwned(allocator);
        errdefer model.owned.freeHandoffGive(allocator, signed_give);
        const signature = try self.signature.toOwned(allocator);
        return .{
            .receiving_session = receiving_session,
            .receiving_side = receiving_side,
            .handoff_count = self.handoff_count,
            .signed_give = signed_give,
            .signature = signature,
        };
    }
};

/// Borrowed mirror of `model.Handoff`.
pub const Handoff = union(enum) {
    give: HandoffGive,
    receive: HandoffReceive,

    pub fn fromOwned(owned: *const model.Handoff) Handoff {
        return switch (owned.*) {
            .give => |*give| .{ .give = HandoffGive.fromOwned(give) },
            .receive => |*receive| .{ .receive = HandoffReceive.fromOwned(receive) },
        };
    }

    pub fn toOwned(self: Handoff, allocator: std.mem.Allocator) Error!model.Handoff {
        return switch (self) {
            .give => |give| .{ .give = try give.toOwned(allocator) },
            .receive => |receive| .{ .receive = try receive.toOwned(allocator) },
        };
    }
};

pub const StartSession = struct {
    /// The version the partner named, or null when it named one this build
    /// does not know. Optional because a codec's job is to say what the bytes
    /// contain, not whether glowcap likes it: an unrecognised token is a
    /// perfectly well-formed frame naming a version we do not speak, and
    /// calling that a malformed frame both lies to the operator and puts the
    /// decision in two decoders instead of the one validator that owns it.
    /// The owned type shares the optional shape, but outbound the version is
    /// ours to choose, so the encoders refuse a null they could not have
    /// produced.
    captp_version: ?model.CaptpVersion,
    session_pubkey: []const u8,
    acceptable_location: PeerLocator,
    acceptable_location_sig: Signature,
    /// The exact `<ocapn-peer ...>` location-record bytes as received, borrowed
    /// from the decoded frame. Null when the producing path did not capture it.
    acceptable_location_raw: ?[]const u8 = null,
};
