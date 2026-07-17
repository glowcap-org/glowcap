//! Locator hint entries and empty-hint wire spellings (`#f` vs `{}`).
//!
//! Shared by `PeerLocator` and handoff exporter locations so `handoff.zig` can
//! name `Hints` without importing the model hub (which imports handoff).

const transport = @import("transport.zig");

pub const HintValue = union(enum) {
    string: []const u8,
    bytes: []const u8,
    boolean: bool,
    integer: i64,
};

pub const HintEntry = struct {
    name: []const u8,
    value: HintValue,
};

pub const Hints = struct {
    entries: []const HintEntry = &.{},
    /// Which wire spelling an empty hint set uses. Goblins writes an absent
    /// hint map as the boolean `#f` while an empty map is `{}`; the two are
    /// semantically the same empty hints, but a signature computed over one
    /// spelling does not verify over the other, so the decoded form is
    /// remembered and reproduced on encode.
    wire_form: WireForm = .map,

    pub const WireForm = enum { map, boolean_false };

    pub fn emptyMap() Hints {
        return .{};
    }

    pub fn emptyFalse() Hints {
        return .{ .wire_form = .boolean_false };
    }

    /// The hints a keyed self-locator advertises for its `direct_addresses`:
    /// the `#f` empty spelling (`emptyFalse`) when there are none, or a single
    /// `hint_direct_addresses` entry carrying them. This is the one place that
    /// empty-vs-entry decision lives, so every keyed hello signs identical
    /// bytes — the blocking driver's `acceptVia` and the byte-fed `Host`, over
    /// `keyed-tcp` or `iroh`. The empty case must stay `#f`, not `{}`: a
    /// partner verifies the location signature over the exact spelling, and the
    /// two do not verify against each other. The caller owns `entry_buf`; the
    /// returned `Hints` borrows it for the hello's lifetime, so a keyed hello on
    /// the connection-open path allocates nothing.
    pub fn forDirectAddresses(direct_addresses: []const u8, entry_buf: *[1]HintEntry) Hints {
        if (direct_addresses.len == 0) return emptyFalse();
        entry_buf[0] = .{ .name = transport.hint_direct_addresses, .value = .{ .string = direct_addresses } };
        return .{ .entries = entry_buf[0..1] };
    }

    /// Empty-hint spelling for URI / redeem projection when a locator carried
    /// neither entries nor an explicit wire form. Bare `.{}` defaults to map
    /// form; dialable handoff URIs want Goblins' `#f` empty spelling so a
    /// partner verifies the same bytes the gifter signed.
    pub fn forUriExport(self: Hints) Hints {
        if (self.entries.len != 0 or self.wire_form == .boolean_false) return self;
        return emptyFalse();
    }
};
