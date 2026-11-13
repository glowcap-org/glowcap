//! Failure metadata shared by runtime layers. Diagnostic bytes grant no provenance.
const std = @import("std");

/// Provenance established for a named failure, independently of operation context.
/// Unclassified diagnostics retain unspecified origin, even when written locally.
pub const Origin = enum(u2) { unspecified, local, partner };
/// A reason established by its producer. Only local owners establish runtime reasons.
/// All eight values are assigned. Adding a reason requires widening this enum
/// and BreakCause, then remeasuring its retained owners. The byte is a cost,
/// not an extensibility constraint on the failure vocabulary.
pub const Reason = enum(u3) {
    unspecified,
    application,
    identity_unverified,
    peer_unreachable,
    /// The exporter closed while the recipient carrier may still be live.
    /// Recipient closure belongs to the operation result, not this reason.
    closed,
    refused,
    transport_unavailable,
    publication_absent,
};
/// Operations may add context while preserving the originating failure.
/// Nested restoration renders its inner diagnostic before retaining this flag.
pub const Context = packed struct(u3) {
    fetch: bool = false,
    restoration: bool = false,
    withdrawal: bool = false,
};

/// A fresh dial report can establish only these transport-owned outcomes.
pub const RouteFailure = enum(u32) {
    peer_unreachable,
    transport_unavailable,

    pub fn cause(self: RouteFailure) BreakCause {
        return BreakCause.local(switch (self) {
            .peer_unreachable => .peer_unreachable,
            .transport_unavailable => .transport_unavailable,
        });
    }
};

/// The route outcome a local error names, when it names one. Only the transport
/// registry can name an absent dialer, so `UnknownTransport` is the one row.
pub fn namedRouteFailure(err: anyerror) ?RouteFailure {
    return if (err == error.UnknownTransport) .transport_unavailable else null;
}

/// Inline metadata has one byte of retained cost and no allocated state.
/// C projections use explicit integer fields, independently of this storage.
const ContextBits = @typeInfo(Context).@"struct".backing_integer.?;

pub const BreakCause = packed struct(u8) {
    origin: Origin = .unspecified,
    reason: Reason = .unspecified,
    context: Context = .{},

    /// Shared predicate definitions. Binding generators render these cases.
    /// They do not reconstruct provenance rules in each language.
    /// Route queries exclude restoration: inspect the retained reason for its inner
    /// route failure. The outer operation is a restoration failure.
    pub const Query = enum {
        application,
        publication_refusal,
        publication_absent,
        peer_identity_unverified,
        exporter_unreachable,

        pub const Case = struct {
            origin: Origin,
            reasons: []const Reason,
            context_mask: ContextBits = std.math.maxInt(ContextBits),
            context: ContextBits = 0,
        };

        pub fn cases(self: Query) []const Case {
            const fetch: ContextBits = @bitCast(Context{ .fetch = true });
            const restoration: ContextBits = @bitCast(Context{ .restoration = true });
            return switch (self) {
                .application => &.{
                    .{ .origin = .local, .reasons = &.{.application} },
                    .{ .origin = .partner, .reasons = &.{.application} },
                },
                .publication_refusal => &.{.{ .origin = .partner, .reasons = &.{.application}, .context = fetch }},
                .publication_absent => &.{.{ .origin = .local, .reasons = &.{.publication_absent}, .context = fetch }},
                .peer_identity_unverified => &.{.{ .origin = .local, .reasons = &.{.identity_unverified}, .context_mask = restoration }},
                .exporter_unreachable => &.{.{ .origin = .local, .reasons = &.{ .peer_unreachable, .transport_unavailable }, .context_mask = restoration }},
            };
        }

        pub fn matches(self: Query, cause: BreakCause) bool {
            const context: ContextBits = @bitCast(cause.context);
            for (self.cases()) |candidate| {
                if (cause.origin != candidate.origin or context & candidate.context_mask != candidate.context) continue;
                for (candidate.reasons) |reason| if (cause.reason == reason) return true;
            }
            return false;
        }
    };

    pub fn local(reason: Reason) BreakCause {
        return .{ .origin = .local, .reason = reason };
    }

    pub fn partner() BreakCause {
        return .{ .origin = .partner, .reason = .application };
    }

    pub fn publicationAbsent() BreakCause {
        return local(.publication_absent).withFetch();
    }

    pub fn withFetch(self: BreakCause) BreakCause {
        var result = self;
        result.context.fetch = true;
        return result;
    }

    pub fn withRestoration(self: BreakCause) BreakCause {
        var result = self;
        result.context.restoration = true;
        return result;
    }

    pub fn withWithdrawal(self: BreakCause) BreakCause {
        var result = self;
        result.context.withdrawal = true;
        return result;
    }

    pub fn isApplication(self: BreakCause) bool {
        return Query.application.matches(self);
    }

    pub fn isPublicationRefusal(self: BreakCause) bool {
        return Query.publication_refusal.matches(self);
    }

    pub fn isPublicationAbsent(self: BreakCause) bool {
        return Query.publication_absent.matches(self);
    }

    pub fn isPeerIdentityUnverified(self: BreakCause) bool {
        return Query.peer_identity_unverified.matches(self);
    }

    pub fn isExporterUnreachable(self: BreakCause) bool {
        return Query.exporter_unreachable.matches(self);
    }

    pub fn label(self: BreakCause) ?[]const u8 {
        if (self.context.restoration) return "RestorationFailed";
        if (self.context.withdrawal) return "handoff redeem failed";
        if (self.origin != .local) return null;
        return switch (self.reason) {
            .identity_unverified => "PeerIdentityUnverified",
            .peer_unreachable, .transport_unavailable => "ExporterUnreachable",
            else => null,
        };
    }
};

/// The detail borrows its producer's storage. Cause never comes from wire text.
pub const Broken = struct {
    detail: []const u8,
    cause: BreakCause,

    /// Maximum rendered local diagnostic retained by a Host operation.
    pub const diagnostic_capacity = 256;

    pub fn unnamed(detail: []const u8) Broken {
        return .{ .detail = detail, .cause = .{} };
    }

    pub fn partner(detail: []const u8) Broken {
        return .{ .detail = detail, .cause = BreakCause.partner() };
    }

    /// A behavior on this side refused with its own application text. The same
    /// refusal reaches a far caller as a partner application break.
    pub fn application(detail: []const u8) Broken {
        return .{ .detail = detail, .cause = BreakCause.local(.application) };
    }

    pub fn publicationAbsent(detail: []const u8) Broken {
        return .{ .detail = detail, .cause = BreakCause.publicationAbsent() };
    }

    /// Largest valid UTF-8 prefix within the byte limit, without allocation.
    pub fn truncate(detail: []const u8, limit: usize) []const u8 {
        const end = @min(detail.len, limit);
        var i: usize = 0;
        while (i < end) {
            const len = std.unicode.utf8ByteSequenceLength(detail[i]) catch break;
            if (len > end - i) break;
            if (!std.unicode.utf8ValidateSlice(detail[i..][0..len])) break;
            i += len;
        }
        return detail[0..i];
    }

    /// Bound labeled diagnostics to a valid UTF-8 prefix. Unlabeled text is borrowed unchanged.
    pub fn bounded(self: Broken) Broken {
        const prefix = self.cause.label() orelse return self;
        return .{ .detail = truncate(self.detail, diagnostic_capacity - prefix.len - 2), .cause = self.cause };
    }

    /// Render only at a text boundary. Operation context can label any origin.
    pub fn render(self: Broken, buffer: *[diagnostic_capacity]u8) []const u8 {
        const prefix = self.cause.label() orelse return self.detail;
        const detail = self.bounded().detail;
        if (detail.len == 0) return prefix;
        return std.mem.print(buffer, "{s}: {s}", .{ prefix, detail }) catch unreachable;
    }

    /// Format through the caller's writeAll method, keeping the foundation
    /// independent of the caller's writer type and I/O backend.
    pub fn format(self: Broken, writer: anytype) !void {
        var diagnostic: [diagnostic_capacity]u8 = undefined;
        try writer.writeAll(self.render(&diagnostic));
    }
};
