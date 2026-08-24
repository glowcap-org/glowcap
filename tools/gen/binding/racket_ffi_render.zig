//! The rendering machinery under the Racket FFI generator: type projection,
//! slot cells, row classification, and the eager-table and multi-wrapper
//! emitters. `racket_ffi.zig` keeps the output list and the per-archive
//! tables.

const std = @import("std");
const headerParamNames = @import("header_names.zig").headerParamNames;
const baseName = @import("reflect").baseName;
const c = @import("c_abi");

/// A named function-pointer alias the base spelling has no case for.
pub const Special = struct {
    T: type,
    spelling: []const u8,
};

/// The raw `_fun` spelling of one parameter type. Out cells and every
/// non-struct pointer spell `_pointer`; a single struct pointer spells its
/// `_PancakeX-pointer` cstruct type, while a borrowed struct *array* stays
/// `_pointer` (the caller hands a raw block, which a tagged cstruct pointer
/// type would refuse); scalars spell `_size` / `_uintN`.
fn rktParamType(comptime T: type, comptime specials: []const Special) []const u8 {
    inline for (specials) |s| {
        if (T == s.T) return s.spelling;
    }
    return switch (@typeInfo(T)) {
        .optional => |o| switch (@typeInfo(o.child)) {
            .pointer => |p| if (p.size == .one and @typeInfo(p.child) == .@"struct")
                "(_or-null _" ++ baseName(p.child) ++ "-pointer)"
            else
                rktParamType(o.child, specials),
            else => rktParamType(o.child, specials),
        },
        .pointer => |p| blk: {
            if (p.child == u8 or p.child == anyopaque) break :blk "_pointer";
            switch (@typeInfo(p.child)) {
                .optional, .int, .@"opaque" => break :blk "_pointer",
                .@"struct" => break :blk if (p.size == .one)
                    "_" ++ baseName(p.child) ++ "-pointer"
                else
                    "_pointer",
                else => @compileError("unmapped pointer child type"),
            }
        },
        .int => switch (T) {
            i32 => "_int32",
            i64 => "_int64",
            u8 => "_uint8",
            u16 => "_uint16",
            u32 => "_uint32",
            u64 => "_uint64",
            usize => "_size",
            else => @compileError("unmapped integer parameter width"),
        },
        else => @compileError("unmapped parameter type"),
    };
}

/// The `_fun` result spelling.
fn rktReturnType(comptime T: type) []const u8 {
    return switch (T) {
        i32 => "_int32",
        u64 => "_uint64",
        usize => "_size",
        void => "_void",
        else => @compileError("unmapped result type"),
    };
}

/// The wrapper out-cell (ctype, init) of a slot parameter — a one-pointer to
/// a scalar, pointer, or opaque Host reference — or null when the parameter is
/// a caller-provided buffer, handle, or struct view rather than a cell the
/// wrapper allocates.
pub const Cell = struct {
    ctype: []const u8,
    init: []const u8,
};

pub fn slotCell(comptime T: type) ?Cell {
    return switch (@typeInfo(T)) {
        .optional => |o| slotCell(o.child),
        .pointer => |p| blk: {
            if (p.size != .one) break :blk null;
            if (p.child == u8 or p.child == anyopaque) break :blk null;
            switch (@typeInfo(p.child)) {
                .optional => |optional| break :blk switch (@typeInfo(optional.child)) {
                    .pointer => |borrowed| if (borrowed.size == .one and
                        @typeInfo(borrowed.child) == .@"struct")
                        .{
                            .ctype = "_" ++ baseName(borrowed.child) ++ "-pointer/null",
                            .init = "#f",
                        }
                    else
                        .{ .ctype = "_pointer", .init = "#f" },
                    else => .{ .ctype = "_pointer", .init = "#f" },
                },
                .int => break :blk .{
                    .ctype = switch (p.child) {
                        u16 => "_uint16",
                        u32 => "_uint32",
                        u64 => "_uint64",
                        usize => "_size",
                        // Signed out-slots: the readiness descriptor the onion
                        // archive hands back, and the close-wait budget.
                        i32 => "_int32",
                        i64 => "_int64",
                        else => @compileError("unmapped scalar slot width"),
                    },
                    .init = "0",
                },
                .@"struct" => break :blk if (p.child == c.PancakeReference)
                    .{ .ctype = "_PancakeReference", .init = "(make-PancakeReference 0)" }
                else
                    null,
                else => break :blk null,
            }
        },
        else => null,
    };
}

fn inOut(comptime row: anytype, comptime i: usize) bool {
    for (row.out_params) |o| {
        if (o == i) return true;
    }
    return false;
}

/// The synthesized-cell parameter indexes of one row: slots the inventory
/// marks as outputs.
pub fn slotIndexes(comptime M: type, comptime row: anytype) []const usize {
    @setEvalBranchQuota(1_000_000);
    const info = @typeInfo(@TypeOf(@field(M, row.name))).@"fn";
    comptime var idx: []const usize = &.{};
    inline for (info.param_types, 0..) |param_type, i| {
        if (slotCell(param_type.?) != null and inOut(row, i)) idx = idx ++ &[_]usize{i};
    }
    return idx;
}

const RowClass = enum { plain, wrap1, multi, hand_wrapped };

fn rowClass(comptime M: type, comptime row: anytype, comptime hand_wrapped: []const []const u8) RowClass {
    inline for (hand_wrapped) |name| {
        if (comptime std.mem.eql(u8, row.name, name)) return .hand_wrapped;
    }
    const info = @typeInfo(@TypeOf(@field(M, row.name))).@"fn";
    const slots = comptime slotIndexes(M, row);
    if (slots.len == 0) return .plain;
    if (slots.len == 1 and slots[0] == info.param_types.len - 1) return .wrap1;
    return .multi;
}

/// The comptime `(_fun …)` spelling of one row's raw signature. Every
/// blocking row keeps its `#:blocking?` mark: the annotation deactivates the
/// calling thread for the duration of the callout, so the collector never
/// stops the world waiting on a parked call — which matters even (especially)
/// when the caller is a plain OS thread holding a thirty-second dial.
pub fn funSig(comptime M: type, comptime row: anytype, comptime specials: []const Special) []const u8 {
    @setEvalBranchQuota(1_000_000);
    const info = @typeInfo(@TypeOf(@field(M, row.name))).@"fn";
    comptime var s: []const u8 = "(_fun ";
    if (row.blocking) s = s ++ "#:blocking? #t ";
    inline for (info.param_types) |param_type| {
        s = s ++ comptime rktParamType(param_type.?, specials) ++ " ";
    }
    return s ++ "-> " ++ comptime rktReturnType(info.return_type.?) ++ ")";
}

fn writeRacketized(gpa: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    for (name) |ch| try out.append(gpa, if (ch == '_') '-' else ch);
}

pub const EagerConfig = struct {
    M: type,
    archive: []const u8,
    lib_var: []const u8,
    definer: []const u8,
    note: []const u8,
    /// Rows whose ergonomic wrapper stays hand-written: the starred raw is
    /// emitted and provided; no mechanical wrapper joins it.
    hand_wrapped: []const []const u8 = &.{},
    /// The generated header the `call/outs` wrappers' argument names come
    /// from; only needed when the archive has multi-out rows.
    header_path: ?[]const u8 = null,
    specials: []const Special = &.{},
    extra_require: ?[]const u8 = null,
    fingerprint_stem: ?[]const u8 = null,
    fingerprint_constant: ?[]const u8 = null,
    /// Most archive modules are the load owner. Core/Host/driver keep policy
    /// in their hand-written wrapper so runtime-proof checks can reach it.
    check_fingerprint_at_load: bool = true,
};

pub fn renderEager(gpa: std.mem.Allocator, comptime cfg: EagerConfig) ![]u8 {
    var header: ?[]const u8 = null;
    defer if (header) |h| gpa.free(h);
    if (cfg.header_path) |path| {
        var threaded = std.Io.Threaded.init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        header = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\#lang racket/base
        \\;; GENERATED by `zig build gen-binding-racket-ffi` (the annotated symbol
        \\;; inventory in the archive's symbols.zig and each export's reflected
        \\;; signature) -- do not edit. `zig build gen-binding-racket-ffi-check`
        \\;; (part of `check`) fails when this is stale.
        \\;;
        \\
    );
    try out.appendSlice(gpa, cfg.note);
    try out.appendSlice(gpa,
        \\(require ffi/unsafe
        \\         ffi/unsafe/define
        \\         "ffi-shared.rkt"
    );
    if (cfg.fingerprint_constant != null) try out.appendSlice(gpa, "\n         \"constants-gen.rkt\"");
    if (cfg.extra_require) |path| try out.print(gpa, "\n         \"{s}\"\n", .{path});
    try out.appendSlice(gpa,
        \\         "lib-resolve.rkt")
        \\
    );

    // Provide everything except the mechanically wrapped starred raws; a
    // hand-wrapped row's starred raw stays provided so the hand module can
    // wrap it.
    try out.appendSlice(gpa, "(provide (except-out (all-defined-out)");
    inline for (cfg.M.symbols.symbols) |row| {
        if (row.racket_omit == null) {
            switch (comptime rowClass(cfg.M, row, cfg.hand_wrapped)) {
                .wrap1, .multi => try out.print(gpa, "\n                     {s}*", .{row.name}),
                else => {},
            }
        }
    }
    try out.appendSlice(gpa, "))\n\n");
    try out.print(gpa, "(define {s} (open-pancake-archive \"{s}\"))\n\n", .{ cfg.lib_var, cfg.archive });
    try out.print(gpa, "(define-ffi-definer {s} {s})\n\n", .{ cfg.definer, cfg.lib_var });

    inline for (cfg.M.symbols.symbols) |row| {
        if (row.racket_omit == null) {
            const sig = comptime funSig(cfg.M, row, cfg.specials);
            switch (comptime rowClass(cfg.M, row, cfg.hand_wrapped)) {
                .plain => {
                    if (cfg.definer.len + row.name.len + sig.len + 10 <= 120) {
                        try out.print(gpa, "({s} {s} {s})\n", .{ cfg.definer, row.name, sig });
                    } else {
                        try out.print(gpa, "({s} {s}\n  {s})\n", .{ cfg.definer, row.name, sig });
                    }
                },
                .hand_wrapped => {
                    try out.print(gpa, "({s} {s}*\n  {s}\n  #:c-id {s})\n", .{ cfg.definer, row.name, sig, row.name });
                },
                .wrap1 => {
                    const info = @typeInfo(@TypeOf(@field(cfg.M, row.name))).@"fn";
                    const cell = comptime slotCell(info.param_types[info.param_types.len - 1].?).?;
                    try out.print(gpa, "({s} {s}*\n  {s}\n  #:c-id {s})\n", .{ cfg.definer, row.name, sig, row.name });
                    const wrap_width = 10 + row.name.len + 12 + row.name.len + 1 + cell.ctype.len + cell.init.len + 4;
                    if (wrap_width <= 120) {
                        try out.print(gpa, "(define {s} (wrap-out1 {s}* {s} {s}))\n", .{ row.name, row.name, cell.ctype, cell.init });
                    } else {
                        try out.print(gpa, "(define {s}\n  (wrap-out1 {s}* {s} {s}))\n", .{ row.name, row.name, cell.ctype, cell.init });
                    }
                },
                .multi => {
                    try out.print(gpa, "({s} {s}*\n  {s}\n  #:c-id {s})\n", .{ cfg.definer, row.name, sig, row.name });
                    try renderMultiWrapper(gpa, &out, cfg.M, row, header orelse return error.MultiOutNeedsHeader);
                },
            }
        }
    }
    if (cfg.check_fingerprint_at_load) {
        if (cfg.fingerprint_stem) |stem| {
            try out.print(gpa, "\n(require-archive-fingerprint! '{s} pancake_{s}_archive_fingerprint {s})\n", .{
                stem,
                stem,
                cfg.fingerprint_constant orelse @compileError("fingerprint constant required"),
            });
        }
    }
    return out.toOwnedSlice(gpa);
}

/// One `call/outs` wrapper: the public name takes the non-cell arguments
/// (named from the header) and returns `(values rc out…)` — or, for a void
/// raw, just `(values out…)` with a constant 0 status inside.
pub fn renderMultiWrapper(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime M: type,
    comptime row: anytype,
    header: []const u8,
) !void {
    const info = @typeInfo(@TypeOf(@field(M, row.name))).@"fn";
    const slots = comptime slotIndexes(M, row);
    const is_void = info.return_type.? == void;
    const names = (try headerParamNames(gpa, header, row.name)) orelse
        return error.PrototypeMissingFromHeader;
    defer gpa.free(names);
    if (names.len != info.param_types.len) return error.HeaderParamCountMismatch;

    try out.print(gpa, "(define ({s}", .{row.name});
    inline for (info.param_types, 0..) |_, i| {
        if (comptime !inSlots(slots, i)) {
            try out.appendSlice(gpa, " ");
            try writeRacketized(gpa, out, names[i]);
        }
    }
    try out.appendSlice(gpa, ")\n");
    if (is_void) {
        try out.appendSlice(gpa, "  (define-values (_rc");
        inline for (slots, 0..) |_, k| try out.print(gpa, " out{d}", .{k});
        try out.appendSlice(gpa, ")\n  ");
    }
    try out.appendSlice(gpa, "  (call/outs (list");
    inline for (slots) |i| {
        const cell = comptime slotCell(info.param_types[i].?).?;
        try out.print(gpa, " (cons {s} {s})", .{ cell.ctype, cell.init });
    }
    try out.appendSlice(gpa, ")\n             (lambda (");
    inline for (slots, 0..) |_, k| {
        if (k != 0) try out.appendSlice(gpa, " ");
        try out.print(gpa, "out{d}", .{k});
    }
    try out.appendSlice(gpa, ")\n               ");
    try out.print(gpa, "({s}*", .{row.name});
    inline for (info.param_types, 0..) |_, i| {
        try out.appendSlice(gpa, " ");
        if (comptime inSlots(slots, i)) {
            try out.print(gpa, "out{d}", .{comptime slotPos(slots, i)});
        } else {
            try writeRacketized(gpa, out, names[i]);
        }
    }
    if (is_void) {
        try out.appendSlice(gpa, ")\n               0)))\n  (values");
        inline for (slots, 0..) |_, k| try out.print(gpa, " out{d}", .{k});
        try out.appendSlice(gpa, "))\n");
    } else {
        try out.appendSlice(gpa, "))))\n");
    }
}

fn inSlots(comptime slots: []const usize, comptime i: usize) bool {
    for (slots) |s| {
        if (s == i) return true;
    }
    return false;
}

fn slotPos(comptime slots: []const usize, comptime i: usize) usize {
    for (slots, 0..) |s, k| {
        if (s == i) return k;
    }
    unreachable;
}
