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

    pub fn fromOwned(owned: *const model.BreakReason) BreakReason {
        return .{ .message = owned.message };
    }

    pub fn toOwned(self: BreakReason, allocator: std.mem.Allocator) Error!model.BreakReason {
        return .{ .message = try allocator.dupe(u8, self.message) };
    }
};

/// Borrowed mirror of `model.PeerLocator`. `hints` is carried by value.
pub const PeerLocator = struct {
    transport: []const u8,
    designator: []const u8,
    /// The wire-decode path projects only the empty hint spellings (`#f` or
    /// `{}`): a non-empty hints map decodes as empty here. Hint entries
    /// survive only via `syrup.readLocatorOwned`.
    hints: model.Hints = .{},

    pub fn fromOwned(owned: *const model.PeerLocator) PeerLocator {
        return .{ .transport = owned.transport, .designator = owned.designator, .hints = owned.hints };
    }

    pub fn toOwned(self: PeerLocator, allocator: std.mem.Allocator) Error!model.PeerLocator {
        const transport = try allocator.dupe(u8, self.transport);
        errdefer allocator.free(transport);
        const designator = try allocator.dupe(u8, self.designator);
        errdefer allocator.free(designator);
        const hints = try model.cloneHints(allocator, self.hints);
        return .{ .transport = transport, .designator = designator, .hints = hints };
    }
};

/// A handoff's exporter location, in whichever shape its codec carried it.
pub const ExporterLocation = union(enum) {
    raw: []const u8,
    locator: struct {
        transport: []const u8,
        designator: []const u8,
        /// The verbatim `<ocapn-peer …>` record this locator parsed from, when
        /// the codec carried one (the Syrup path; empty for capnp's opaque
        /// bytes). A consumer that needs hint entries the borrowed session
        /// reader discards — an exporter's direct-address dial hints, say —
        /// re-parses this span with an allocator. The flattened
        /// `transport:designator` form above cannot carry hints.
        record: []const u8 = &.{},
    },

    pub fn toOwned(self: ExporterLocation, allocator: std.mem.Allocator) Error![]u8 {
        return switch (self) {
            .raw => |bytes| allocator.dupe(u8, bytes),
            .locator => |loc| blk: {
                // The flattened `transport:designator` form splits back on the
                // first ':', so a transport containing ':' would re-split into
                // a different locator. Refuse the ambiguity at the producer.
                if (std.mem.indexOfScalar(u8, loc.transport, ':') != null) return error.MalformedView;
                const out = try allocator.alloc(u8, loc.transport.len + 1 + loc.designator.len);
                @memcpy(out[0..loc.transport.len], loc.transport);
                out[loc.transport.len] = ':';
                @memcpy(out[loc.transport.len + 1 ..], loc.designator);
                break :blk out;
            },
        };
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
};

/// Borrowed mirror of `model.HandoffGive`.
pub const HandoffGive = struct {
    recipient_key: []const u8,
    exporter_location: ExporterLocation,
    gifter_exporter_session: []const u8,
    gifter_side: []const u8,
    gift_id: []const u8,
    signature: Signature,
    raw_signed: ?[]const u8 = null,

    pub fn fromOwned(owned: *const model.HandoffGive) HandoffGive {
        return .{
            .recipient_key = owned.recipient_key,
            .exporter_location = .{ .raw = owned.exporter_location },
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
        const exporter_location = try self.exporter_location.toOwned(allocator);
        errdefer allocator.free(exporter_location);
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
            .exporter_location = exporter_location,
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

    pub fn fromOwned(owned: *const model.HandoffReceive) HandoffReceive {
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
    captp_version: model.CaptpVersion,
    session_pubkey: []const u8,
    acceptable_location: PeerLocator,
    acceptable_location_sig: Signature,
    /// The exact `<ocapn-peer ...>` location-record bytes as received, borrowed
    /// from the decoded frame. Null when the producing path did not capture it.
    acceptable_location_raw: ?[]const u8 = null,
};
