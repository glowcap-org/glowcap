//! Owned peer locator: transport, designator, and dial hints.
//!
//! Leaf module so `handoff.zig` can name the exporter without importing the
//! model hub (the hub re-exports handoff). Hint spellings live in `hints.zig`.

const std = @import("std");

const hints = @import("hints.zig");
const transport = @import("transport.zig");

pub const PeerLocator = struct {
    transport: []const u8,
    designator: []const u8,
    hints: hints.Hints = .{},
};

pub const ValidationError = transport.SymbolError || error{
    EmptyDesignator,
    EmptyHintName,
    DuplicateHintName,
    InvalidFalseHints,
};

pub const HintAdditionError = error{
    EmptyHintName,
    DuplicateHintName,
    InvalidFalseHints,
};

/// Validate adding one named hint to an already-valid locator. Storage owners
/// perform their own transactional allocation, but model invariants have one
/// authority here.
pub fn validateHintAddition(locator: PeerLocator, name: []const u8) HintAdditionError!void {
    if (locator.hints.wire_form == .boolean_false) return error.InvalidFalseHints;
    if (name.len == 0) return error.EmptyHintName;
    for (locator.hints.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return error.DuplicateHintName;
    }
}

/// Validate the representation-independent OCapN peer-locator invariants.
/// Transport-specific designator and hint semantics stay with the provider.
pub fn validate(locator: PeerLocator) ValidationError!void {
    try transport.validateSymbol(locator.transport);
    if (locator.designator.len == 0) return error.EmptyDesignator;
    if (locator.hints.wire_form == .boolean_false and locator.hints.entries.len != 0)
        return error.InvalidFalseHints;
    for (locator.hints.entries) |entry| {
        if (entry.name.len == 0) return error.EmptyHintName;
    }
    if (hints.firstDuplicateName(locator.hints.entries) != null)
        return error.DuplicateHintName;
}
