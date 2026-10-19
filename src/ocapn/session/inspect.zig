//! Read-only session table walks for inspect / status surfaces.
//!
//! `Session` remains the authority boundary. This module owns only the
//! borrowed view shapes and the non-mutating walkers over export, import,
//! and answer tables.

const model = @import("model");
const session_mod = @import("mod.zig");
const slot = @import("slot.zig");
const answers = @import("answers/store.zig");

const Session = session_mod.Session;
const AnswerView = answers.AnswerView;

/// Read-only export row for session table walks (inspect / status).
pub const ExportView = struct {
    position: model.ExportPosition,
    slot: slot.Slot,
    refcount: u64,
};

/// Read-only import row for session table walks (inspect / status). The row
/// stores no cell: a far import is always the `remote_value` of its own
/// position, projected here so the export and import panes draw one shape.
pub const ImportView = struct {
    position: model.ImportPosition,
    slot: slot.Slot,
    refcount: u64,
    /// How many of `refcount` the session keeps for a release of its own.
    session_held: u64,
};

/// Read-only answer row (inbound or outbound) plus position.
pub const AnswerRowView = struct {
    position: model.AnswerName,
    view: AnswerView,
};

pub fn exportCount(self: *const Session) usize {
    return self.exports.len();
}

pub fn importCount(self: *const Session) usize {
    return self.imports.len();
}

pub fn inboundAnswerCount(self: *const Session) usize {
    return self.inbound_answers.len();
}

pub fn outboundAnswerCount(self: *const Session) usize {
    return self.outbound_answers.len();
}

/// Walk every live export row, projecting each to `ExportView`. The callback
/// must not mutate the table.
pub fn forEachExport(self: *const Session, ctx: anytype, comptime f: *const fn (@TypeOf(ctx), ExportView) void) void {
    var it = self.exports.iterator();
    while (it.next()) |entry| {
        f(ctx, .{
            .position = entry.position,
            .slot = entry.row.slot(entry.position),
            .refcount = entry.row.count,
        });
    }
}

/// Walk every live import row, projecting each to `ImportView`. The callback
/// must not mutate the table.
pub fn forEachImport(self: *const Session, ctx: anytype, comptime f: *const fn (@TypeOf(ctx), ImportView) void) void {
    var it = self.imports.rows.iterator();
    while (it.next()) |entry| {
        f(ctx, .{
            .position = .from(entry.key_ptr.*),
            .slot = .{ .remote_value = entry.key_ptr.* },
            .refcount = entry.value_ptr.count,
            .session_held = entry.value_ptr.session_held,
        });
    }
}

/// Walk every live inbound answer. The callback must not mutate the table.
pub fn forEachInboundAnswer(self: *const Session, ctx: anytype, comptime f: *const fn (@TypeOf(ctx), AnswerRowView) void) void {
    var it = self.inbound_answers.rows.iterator();
    while (it.next()) |entry| {
        f(ctx, .{ .position = entry.key_ptr.*, .view = AnswerView.of(entry.value_ptr) });
    }
}

/// Walk every live outbound answer. The callback must not mutate the table.
pub fn forEachOutboundAnswer(self: *const Session, ctx: anytype, comptime f: *const fn (@TypeOf(ctx), AnswerRowView) void) void {
    var it = self.outbound_answers.iterator();
    while (it.next()) |entry| {
        f(ctx, .{ .position = .fromWire(entry.position), .view = AnswerView.of(entry.cell) });
    }
}

// ── Point lookups the engine reads on the hot path ─────────────────────────

pub fn inboundAnswer(self: *const Session, id: model.AnswerPosition) ?AnswerView {
    return self.inboundAnswerNamed(.fromWire(id));
}

pub fn inboundAnswerNamed(self: *const Session, id: model.AnswerName) ?AnswerView {
    const entry = self.inbound_answers.getPtr(id) orelse return null;
    return AnswerView.of(entry);
}

/// Live inbound answer to Slot.
pub fn inboundAnswerSlot(self: *const Session, id: model.AnswerPosition) ?slot.Slot {
    const cell = self.inbound_answers.getPtr(.fromWire(id)) orelse return null;
    return answers.answerSlot(id, cell.status());
}

/// Whether `id` is a known inbound answer, the existence probe the
/// pipeline's guards read, without materializing an `AnswerView`.
pub fn hasInboundAnswer(self: *const Session, id: model.AnswerPosition) bool {
    return self.hasInboundAnswerNamed(.fromWire(id));
}

pub fn hasInboundAnswerNamed(self: *const Session, id: model.AnswerName) bool {
    return self.inbound_answers.contains(id);
}

/// The identity stamp of the live inbound-answer row at `id`, or null when
/// absent, the value a queued listener-fire carrier compares at encode to
/// tell this row instance from a released-and-reused position.
pub fn inboundAnswerRowId(self: *const Session, id: model.AnswerPosition) ?u64 {
    return self.inboundAnswerRowIdNamed(.fromWire(id));
}

pub fn inboundAnswerRowIdNamed(self: *const Session, id: model.AnswerName) ?u64 {
    const entry = self.inbound_answers.getPtr(id) orelse return null;
    return entry.row_id;
}

pub fn outboundAnswer(self: *const Session, id: model.AnswerPosition) ?AnswerView {
    const entry = self.outbound_answers.get(id) orelse return null;
    return AnswerView.of(entry);
}

/// The target of the question `id` carries now, for a holder that will read
/// the row back after the position may have been minted again.
pub fn outboundAnswerTarget(self: *Session, id: model.AnswerPosition) ?answers.OutboundAnswerTarget {
    return self.outbound_answers.targetOf(id);
}

/// Whether `target` still names the row it was taken from.
pub fn hasLiveOutboundAnswer(self: *Session, target: answers.OutboundAnswerTarget) bool {
    return self.outbound_answers.live(target) != null;
}

/// Whether an application owner, rather than stateless serve policy, owns the
/// eventual release of this live outbound answer.
pub fn outboundAnswerReleaseClaimed(self: *Session, target: answers.OutboundAnswerTarget) bool {
    const entry = self.outbound_answers.live(target) orelse return false;
    return entry.application_release_claimed;
}

/// Live outbound answer to Slot.
pub fn outboundAnswerSlot(self: *const Session, id: model.AnswerPosition) ?slot.Slot {
    const cell = self.outbound_answers.get(id) orelse return null;
    return answers.answerSlot(id, cell.status());
}
