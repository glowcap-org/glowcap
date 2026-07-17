//! Read-only session table walks for inspect / status surfaces.
//!
//! `Session` remains the authority boundary; this module owns only the
//! borrowed view shapes and the non-mutating walkers over export, import,
//! and answer tables.

const model = @import("model");
const session_mod = @import("mod.zig");
const slot = @import("slot.zig");
const answers = @import("answers.zig");

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
    position: model.AnswerPosition,
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
    ctx: anytype,
    comptime f: *const fn (@TypeOf(ctx), AnswerRowView) void,
) void {
    var it = table.rows.iterator();
    while (it.next()) |entry| {
        f(ctx, .{
            .position = .from(entry.key_ptr.*),
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
    forEachAnswerRow(&self.inbound_answers, ctx, f);
}

/// Walk every live outbound answer. Callback must not mutate the table.
pub fn forEachOutboundAnswer(self: *const Session, ctx: anytype, comptime f: *const fn (@TypeOf(ctx), AnswerRowView) void) void {
    forEachAnswerRow(&self.outbound_answers, ctx, f);
}
