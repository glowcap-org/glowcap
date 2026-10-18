//! CapTP unified reference slot (ADR-0080).
//!
//! Name plate: this file is the CapTP `Slot` **sum type** (mint × binding). It is
//! not `export_table.zig` or `import_table.zig` (rows with wire-delta counts). CapTP
//! keeps export, import, and answer as separate position namespaces. The sum is
//! shared, the tables are not one map.
//!
//! A slot's identity is not a stored wire kind but a legal `(mint, binding)`
//! variant. Impossible cells cannot be constructed. This is a sum, not a
//! validated product. The four CapTP `desc:*` tags are a **projection** of the
//! variant onto `model.Reference` (and from there the real syrup codec emits
//! bytes). This module does not reimplement Syrup encoding.
//!
//! Encode perspective matches the syrup codec (`writePayloadReference`):
//! a local export renders as `desc:import-*` and a remote import as
//! `desc:export` (ADR-0010 perspective flip).

const model = @import("model");

/// Who allocated the wire position.
pub const Mint = enum { local, remote };

/// Wire position integer shared by export / import / answer spaces on the wire.
pub const Position = u64;

/// Legal CapTP slot states only. There is no `(mint, binding)` product to
/// validate: nonsense combinations are not constructible.
///
/// `local_value` is object-only: a local promise *is* `local_unresolved` (one
/// representation per wire tag). `remote_value` carries no kind field, far
/// always encodes as `desc:export`.
pub const Slot = union(enum) {
    /// Local mint + unresolved, a promise this vat made (`desc:import-promise`).
    local_unresolved: Position,
    /// Remote mint + unresolved, an answer this vat awaits (`desc:answer`).
    remote_unresolved: Position,
    /// Local mint + value, a near object export (`desc:import-object`).
    local_value: Position,
    /// Remote mint + value, a far import (`desc:export`).
    remote_value: Position,
    /// Either mint + broken, no `desc:*` position tag.
    broken: struct { mint: Mint, position: Position },
};

/// Project a slot onto the codec-neutral `model.Reference` the syrup encoder
/// already knows how to render. This is the only projection seam, bytes come
/// from the real codec, never from a second encoder here.
pub fn toReference(slot: Slot) ?model.Reference {
    return switch (slot) {
        .local_unresolved => |p| .{ .near = .{ .export_position = .from(p), .kind = .promise } },
        .remote_unresolved => |p| .{ .promise = .{ .answer_position = .from(p) } },
        .local_value => |p| .{ .near = .{ .export_position = .from(p), .kind = .object } },
        .remote_value => |p| .{ .far = .{ .import_position = .from(p), .kind = .object } },
        .broken => null,
    };
}

/// Position carried by a slot.
pub fn position(slot: Slot) Position {
    return switch (slot) {
        .local_unresolved => |p| p,
        .remote_unresolved => |p| p,
        .local_value => |p| p,
        .remote_value => |p| p,
        .broken => |b| b.position,
    };
}

/// Binding axis of a slot: what the position is bound to.
pub const Binding = enum(u8) { unresolved, value, broken };

pub fn bindingOf(slot: Slot) Binding {
    return switch (slot) {
        .local_unresolved, .remote_unresolved => .unresolved,
        .local_value, .remote_value => .value,
        .broken => .broken,
    };
}

/// The local-mint slot with `binding` at `position`. An export row keeps
/// only the binding, because its position is its index and its mint is
/// local (`export_table.ExportRow`).
pub fn local(binding: Binding, pos: Position) Slot {
    return switch (binding) {
        .unresolved => .{ .local_unresolved = pos },
        .value => .{ .local_value = pos },
        .broken => .{ .broken = .{ .mint = .local, .position = pos } },
    };
}

/// Mint axis of a slot.
pub fn mintOf(slot: Slot) Mint {
    return switch (slot) {
        .local_unresolved, .local_value => .local,
        .remote_unresolved, .remote_value => .remote,
        .broken => |b| b.mint,
    };
}

pub const TransitionError = error{
    /// Fulfill / break require an unresolved slot.
    NotUnresolved,
};

/// Unresolved becomes same-mint value, position preserved: the total
/// unresolved→value transition over both mints. In this codebase only a remote
/// answer binding is driven through it (`answers/store.zig`). A `local_unresolved`
/// export is minted for a resolver callback and is terminal, glowcap never
/// settles a local promise export (ADR-0080, ADR-0007).
pub fn fulfill(slot: Slot) TransitionError!Slot {
    return switch (slot) {
        .local_unresolved => |p| .{ .local_value = p },
        .remote_unresolved => |p| .{ .remote_value = p },
        else => error.NotUnresolved,
    };
}

/// Unresolved becomes broken. Mint and position preserved.
pub fn breakSlot(slot: Slot) TransitionError!Slot {
    return switch (slot) {
        .local_unresolved => |p| .{ .broken = .{ .mint = .local, .position = p } },
        .remote_unresolved => |p| .{ .broken = .{ .mint = .remote, .position = p } },
        else => error.NotUnresolved,
    };
}
