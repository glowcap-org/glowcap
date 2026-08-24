//! Read-only session table walks for inspect / status surfaces.
//!
//! `Session` remains the authority boundary; this module owns only the
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

/// Read-only import row for session table walks (inspect / status).
pub const ImportView = struct {
    position: model.ImportPosition,
    slot: slot.Slot,
    refcount: u64,
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

/// Walk a slot table (exports or imports), projecting each row to `View`.
/// Read-only: the borrowed `*const` table cannot mutate under the callback.
fn forEachSlotRow(
    comptime View: type,
    comptime Pos: type,
    table: anytype,
    ctx: anytype,
    comptime f: *const fn (@TypeOf(ctx), View) void,
) void {
    var it = table.slots.rows.iterator();
    while (it.next()) |entry| {
        f(ctx, View{
            .position = Pos.from(entry.key_ptr.*),
            .slot = entry.value_ptr.cell,
            .refcount = entry.value_ptr.count,
        });
    }
}

/// Walk an answer table (inbound or outbound), projecting each row.
fn forEachAnswerRow(
    table: anytype,
    comptime Position: type,
    ctx: anytype,
    comptime f: *const fn (@TypeOf(ctx), AnswerRowView) void,
) void {
    var it = table.rows.iterator();
    while (it.next()) |entry| {
        f(ctx, .{
            .position = if (Position == model.AnswerName)
                entry.key_ptr.*
            else
                .fromWire(entry.key_ptr.*),
            .view = AnswerView.of(entry.value_ptr),
        });
    }
}

/// Walk every live export row. Callback must not mutate the table.
pub fn forEachExport(self: *const Session, ctx: anytype, comptime f: *const fn (@TypeOf(ctx), ExportView) void) void {
    forEachSlotRow(ExportView, model.ExportPosition, &self.exports, ctx, f);
}

/// Walk every live import row. Callback must not mutate the table.
pub fn forEachImport(self: *const Session, ctx: anytype, comptime f: *const fn (@TypeOf(ctx), ImportView) void) void {
    forEachSlotRow(ImportView, model.ImportPosition, &self.imports, ctx, f);
}

/// Walk every live inbound answer. Callback must not mutate the table.
pub fn forEachInboundAnswer(self: *const Session, ctx: anytype, comptime f: *const fn (@TypeOf(ctx), AnswerRowView) void) void {
    forEachAnswerRow(&self.inbound_answers, model.AnswerName, ctx, f);
}

/// Walk every live outbound answer. Callback must not mutate the table.
pub fn forEachOutboundAnswer(self: *const Session, ctx: anytype, comptime f: *const fn (@TypeOf(ctx), AnswerRowView) void) void {
    forEachAnswerRow(&self.outbound_answers, model.AnswerPosition, ctx, f);
}

// ── Point lookups the engine reads on the hot path ─────────────────────────
// `*Session` rather than `*const` because the table reads use `getPtr`.

pub fn inboundAnswer(self: *Session, id: model.AnswerPosition) ?AnswerView {
    return self.inboundAnswerNamed(.fromWire(id));
}

pub fn inboundAnswerNamed(self: *Session, id: model.AnswerName) ?AnswerView {
    const entry = self.inbound_answers.getPtr(id) orelse return null;
    return AnswerView.of(entry);
}

/// Live inbound answer to Slot.
pub fn inboundAnswerSlot(self: *Session, id: model.AnswerPosition) ?slot.Slot {
    const cell = self.inbound_answers.getPtr(.fromWire(id)) orelse return null;
    return answers.answerSlot(id, cell.status());
}

/// Whether `id` is a known inbound answer — the existence probe the
/// pipeline's guards read, without materializing an `AnswerView`.
pub fn hasInboundAnswer(self: *const Session, id: model.AnswerPosition) bool {
    return self.hasInboundAnswerNamed(.fromWire(id));
}

pub fn hasInboundAnswerNamed(self: *const Session, id: model.AnswerName) bool {
    return self.inbound_answers.contains(id);
}

/// The identity stamp of the live inbound-answer row at `id`, or null when
/// absent — the value a queued listener-fire carrier compares at encode to
/// tell this row instance from a released-and-reused position.
pub fn inboundAnswerRowId(self: *Session, id: model.AnswerPosition) ?u64 {
    return self.inboundAnswerRowIdNamed(.fromWire(id));
}

pub fn inboundAnswerRowIdNamed(self: *Session, id: model.AnswerName) ?u64 {
    const entry = self.inbound_answers.getPtr(id) orelse return null;
    return entry.row_id;
}

pub fn outboundAnswer(self: *Session, id: model.AnswerPosition) ?AnswerView {
    const entry = self.outbound_answers.getPtr(id) orelse return null;
    return AnswerView.of(entry);
}

/// Whether an application owner, rather than stateless serve policy, owns the
/// eventual release of this live outbound answer.
pub fn outboundAnswerReleaseClaimed(self: *Session, id: model.AnswerPosition) bool {
    const entry = self.outbound_answers.getPtr(id) orelse return false;
    return entry.application_release_claimed;
}

/// Live outbound answer to Slot.
pub fn outboundAnswerSlot(self: *Session, id: model.AnswerPosition) ?slot.Slot {
    const cell = self.outbound_answers.getPtr(id) orelse return null;
    return answers.answerSlot(id, cell.status());
}
