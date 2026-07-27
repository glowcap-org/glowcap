//! Generates the Racket binding's FFI tables from each archive's annotated
//! symbol inventory.
//!
//! The split of truth: parameter and return *types* reflect from the real Zig
//! exports (`@typeInfo`, so a signature change regenerates a different file),
//! the inventory supplies order, the `racket_omit` rows, the `blocking` marks
//! (`#:blocking?`, so a parked FFI call does not freeze the place's green
//! threads), and the out-cell wrapper tier derives from `out_params` plus the
//! slot shape of each parameter: a one-pointer to a scalar or a pointer is a
//! fresh caller-owned cell the wrapper allocates, while a caller-provided
//! buffer stays an argument. A wrapper's remaining argument names come from
//! the generated C header. Each eager archive's output is a sibling module
//! the hand-authored `ffi-*.rkt` file re-provides; the iroh output exports
//! one table-building function the lazy hand loader calls with the opened
//! library and the config cstruct type, so the generated module stays below
//! the hand module that declares it. `zig build gen-binding-racket-ffi-check`
//! (part of `check`) holds the committed files against a fresh generation.

const std = @import("std");

// Force sidecar stubs so reflecting the iroh archive stays cargo-free.
comptime {
    _ = @import("iroh_sidecar_stub");
    _ = @import("webrtc_sidecar_stub");
}

const c = @import("c_abi");
const cd = @import("c_abi_driver");
const ci = @import("c_abi_net_transport_iroh");
const ct = @import("c_abi_net_transport_tcp");
const cin = @import("c_abi_net_transport_inproc");
const cw = @import("c_abi_net_transport_webrtc");

const headerParamNames = @import("header_names.zig").headerParamNames;

pub const step_name = "gen-binding-racket-ffi";

const Output = @import("output").Output;

pub const outputs = [_]Output{
    .{ .path = "bindings/racket/private/ffi-ocapn-gen.rkt", .generate = generateOcapn },
    .{ .path = "bindings/racket/private/ffi-driver-gen.rkt", .generate = generateDriver },
    .{ .path = "bindings/racket/private/ffi-tcp-gen.rkt", .generate = generateTcp },
    .{ .path = "bindings/racket/private/ffi-inproc-gen.rkt", .generate = generateInproc },
    .{ .path = "bindings/racket/private/ffi-iroh-gen.rkt", .generate = generateIroh },
    .{ .path = "bindings/racket/private/ffi-webrtc-gen.rkt", .generate = generateWebrtc },
};

/// `module.PancakeManagedFrame` → `PancakeManagedFrame`.
const baseName = @import("reflect").baseName;

/// A named function-pointer alias the base spelling has no case for.
const Special = struct {
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
        .optional => |o| rktParamType(o.child, specials),
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
        usize => "_size",
        void => "_void",
        else => @compileError("unmapped result type"),
    };
}

/// The wrapper out-cell (ctype, init) of a slot parameter — a one-pointer to
/// a scalar or to a pointer — or null when the parameter is a caller-provided
/// buffer, handle, or struct view rather than a cell the wrapper allocates.
const Cell = struct {
    ctype: []const u8,
    init: []const u8,
};

fn slotCell(comptime T: type) ?Cell {
    return switch (@typeInfo(T)) {
        .optional => |o| slotCell(o.child),
        .pointer => |p| blk: {
            if (p.size != .one) break :blk null;
            if (p.child == u8 or p.child == anyopaque) break :blk null;
            switch (@typeInfo(p.child)) {
                .optional => break :blk .{ .ctype = "_pointer", .init = "#f" },
                .int => break :blk .{
                    .ctype = switch (p.child) {
                        u16 => "_uint16",
                        u32 => "_uint32",
                        u64 => "_uint64",
                        usize => "_size",
                        else => @compileError("unmapped scalar slot width"),
                    },
                    .init = "0",
                },
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
fn slotIndexes(comptime M: type, comptime row: anytype) []const usize {
    const info = @typeInfo(@TypeOf(@field(M, row.name))).@"fn";
    comptime var idx: []const usize = &.{};
    inline for (info.params, 0..) |p, i| {
        if (slotCell(p.type.?) != null and inOut(row, i)) idx = idx ++ &[_]usize{i};
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
    if (slots.len == 1 and slots[0] == info.params.len - 1) return .wrap1;
    return .multi;
}

/// The comptime `(_fun …)` spelling of one row's raw signature. Every
/// blocking row keeps its `#:blocking?` mark: the annotation deactivates the
/// calling thread for the duration of the callout, so the collector never
/// stops the world waiting on a parked call — which matters even (especially)
/// when the caller is a plain OS thread holding a thirty-second dial.
fn funSig(comptime M: type, comptime row: anytype, comptime specials: []const Special) []const u8 {
    @setEvalBranchQuota(1_000_000);
    const info = @typeInfo(@TypeOf(@field(M, row.name))).@"fn";
    comptime var s: []const u8 = "(_fun ";
    if (row.blocking) s = s ++ "#:blocking? #t ";
    inline for (info.params) |p| {
        s = s ++ comptime rktParamType(p.type.?, specials) ++ " ";
    }
    return s ++ "-> " ++ comptime rktReturnType(info.return_type.?) ++ ")";
}

fn writeRacketized(gpa: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    for (name) |ch| try out.append(gpa, if (ch == '_') '-' else ch);
}

const EagerConfig = struct {
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
};

fn renderEager(gpa: std.mem.Allocator, comptime cfg: EagerConfig) ![]u8 {
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
                    if (cfg.definer.len + row.name.len + sig.len + 10 <= 100) {
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
                    const cell = comptime slotCell(info.params[info.params.len - 1].type.?).?;
                    try out.print(gpa, "({s} {s}*\n  {s}\n  #:c-id {s})\n", .{ cfg.definer, row.name, sig, row.name });
                    const wrap_width = 10 + row.name.len + 12 + row.name.len + 1 + cell.ctype.len + cell.init.len + 4;
                    if (wrap_width <= 100) {
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
    return out.toOwnedSlice(gpa);
}

/// One `call/outs` wrapper: the public name takes the non-cell arguments
/// (named from the header) and returns `(values rc out…)` — or, for a void
/// raw, just `(values out…)` with a constant 0 status inside.
fn renderMultiWrapper(
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
    if (names.len != info.params.len) return error.HeaderParamCountMismatch;

    try out.print(gpa, "(define ({s}", .{row.name});
    inline for (info.params, 0..) |_, i| {
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
        const cell = comptime slotCell(info.params[i].type.?).?;
        try out.print(gpa, " (cons {s} {s})", .{ cell.ctype, cell.init });
    }
    try out.appendSlice(gpa, ")\n             (lambda (");
    inline for (slots, 0..) |_, k| {
        if (k != 0) try out.appendSlice(gpa, " ");
        try out.print(gpa, "out{d}", .{k});
    }
    try out.appendSlice(gpa, ")\n               ");
    try out.print(gpa, "({s}*", .{row.name});
    inline for (info.params, 0..) |_, i| {
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

fn generateOcapn(gpa: std.mem.Allocator) ![]u8 {
    return renderEager(gpa, .{
        .M = c,
        .archive = "pancake_ocapn",
        .lib_var = "ocapn-lib",
        .definer = "define-pancake",
        .note =
        \\;; The raw `ffi/unsafe` table of libpancake_ocapn, the core archive. The
        \\;; hand-written sibling (`ffi-ocapn.rkt`) owns the prose and re-provides
        \\;; this module together with the shared cstruct vocabulary.
        \\
        ,
        .header_path = "include/pancake_ocapn.h",
    });
}

fn generateDriver(gpa: std.mem.Allocator) ![]u8 {
    return renderEager(gpa, .{
        .M = cd,
        .archive = "pancake_driver",
        .lib_var = "driver-lib",
        .definer = "define-driver",
        .note =
        \\;; The raw `ffi/unsafe` table of libpancake_driver, the byte-fed host
        \\;; archive. The hand-written sibling (`ffi-driver.rkt`) owns the prose and
        \\;; the bespoke pending-dial wrapper over the starred raw, and re-provides
        \\;; this module. The behavior/pump callback types and the plan/dial cstructs
        \\;; live in `ffi-shared.rkt`, the binding's types leaf.
        \\
        ,
        .hand_wrapped = &.{"pancake_host_pending_dial"},
        .specials = &.{
            .{ .T = cd.PancakeHostBehavior, .spelling = "_PancakeHostBehavior" },
            .{ .T = cd.PancakeHostCtxFree, .spelling = "_pointer" },
        },
    });
}

fn generateTcp(gpa: std.mem.Allocator) ![]u8 {
    return renderEager(gpa, .{
        .M = ct,
        .archive = "pancake_net_transport_tcp",
        .lib_var = "tcp-lib",
        .definer = "define-pancake-tcp",
        .note =
        \\;; The raw `ffi/unsafe` table of libpancake_net_transport_tcp. The
        \\;; hand-written sibling (`ffi-tcp.rkt`) owns the prose and re-provides this
        \\;; module. The blocking rows (`#:blocking?`) park the calling thread on the
        \\;; socket; the mark keeps the runtime GC-cooperative during the park.
        \\
        ,
    });
}

fn generateInproc(gpa: std.mem.Allocator) ![]u8 {
    return renderEager(gpa, .{
        .M = cin,
        .archive = "pancake_net_transport_inproc",
        .lib_var = "inproc-lib",
        .definer = "define-pancake-inproc",
        .note =
        \\;; The raw `ffi/unsafe` table of libpancake_net_transport_inproc. The
        \\;; hand-written sibling (`ffi-inproc.rkt`) owns the prose and re-provides
        \\;; this module. The blocking rows (`#:blocking?`) park the calling thread
        \\;; on the in-process pipes; the mark keeps the runtime GC-cooperative
        \\;; during the park.
        \\
        ,
    });
}

fn generateIroh(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\#lang racket/base
        \\;; GENERATED by `zig build gen-binding-racket-ffi` (the annotated symbol
        \\;; inventory in the archive's symbols.zig and each export's reflected
        \\;; signature) -- do not edit. `zig build gen-binding-racket-ffi-check`
        \\;; (part of `check`) fails when this is stale.
        \\;;
        \\;; The keyed table of libpancake_net_transport_iroh. The archive is
        \\;; optional and loads lazily, so this module exports one table-building
        \\;; function the hand-written sibling (`ffi-iroh.rkt`) calls with the opened
        \\;; library and the config cstruct pointer type it declares — the generated
        \\;; module stays below the hand module, so no require cycle forms. The
        \\;; blocking dial is emitted without an out-cell wrapper because
        \\;; `pancake-iroh.rkt` runs it on a plain OS thread (so the place's green
        \\;; threads keep serving while a dial parks) with a preallocated cell; its
        \\;; `#:blocking?` mark stays, deactivating that thread for the callout so
        \\;; the collector never waits on a parked dial. Every other row returns
        \\;; immediately.
        \\(require ffi/unsafe
        \\         "ffi-shared.rkt")
        \\(provide iroh-ffi-table)
        \\
        \\(define (iroh-ffi-table L _PancakeIrohConfig-pointer)
        \\  (hasheq
    );
    inline for (ci.symbols.symbols) |row| {
        if (row.racket_omit == null) {
            const key = comptime irohKey(row.name);
            const sig = comptime funSig(ci, row, &.{});
            const slots = comptime slotIndexes(ci, row);
            if (slots.len == 0 or row.blocking) {
                try out.print(gpa, "\n   '{s}\n   (get-ffi-obj '{s} L {s})", .{ key, row.name, sig });
            } else {
                // Every out-bearing iroh row has exactly one trailing cell.
                comptime std.debug.assert(slots.len == 1);
                const info = @typeInfo(@TypeOf(@field(ci, row.name))).@"fn";
                comptime std.debug.assert(slots[0] == info.params.len - 1);
                const cell = comptime slotCell(info.params[slots[0]].type.?).?;
                try out.print(gpa, "\n   '{s}\n   (wrap-out1 (get-ffi-obj '{s} L {s})\n              {s} {s})", .{ key, row.name, sig, cell.ctype, cell.init });
            }
        }
    }
    try out.appendSlice(gpa, "))\n");
    return out.toOwnedSlice(gpa);
}

/// `pancake_iroh_netlayer_drain_ready` → `netlayer-drain-ready`.
fn irohKey(comptime name: []const u8) []const u8 {
    const stripped = name["pancake_iroh_".len..];
    comptime var s: []const u8 = "";
    inline for (stripped) |ch| {
        s = s ++ &[_]u8{if (ch == '_') '-' else ch};
    }
    return s;
}

fn generateWebrtc(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\#lang racket/base
        \\;; GENERATED by `zig build gen-binding-racket-ffi` (the annotated symbol
        \\;; inventory in the archive's symbols.zig and each export's reflected
        \\;; signature) -- do not edit. `zig build gen-binding-racket-ffi-check`
        \\;; (part of `check`) fails when this is stale.
        \\;;
        \\;; The keyed table of libpancake_net_transport_webrtc. The archive is
        \\;; optional and loads lazily, so this module exports one table-building
        \\;; function the hand-written sibling (`ffi-webrtc.rkt`) calls with the
        \\;; opened library -- the generated module stays below the hand module, so
        \\;; no require cycle forms. A webrtc peer is an opaque handle with no
        \\;; config struct, so the table takes only the library. The blocking
        \\;; `peer-wait-open` and `peer-read` keep their `#:blocking?` mark so the
        \\;; place's green threads keep serving while a call parks; every other row
        \\;; returns immediately.
        \\(require ffi/unsafe
        \\         "ffi-shared.rkt")
        \\(provide webrtc-ffi-table)
        \\
        \\(define (webrtc-ffi-table L)
        \\  (hasheq
    );
    inline for (cw.symbols.symbols) |row| {
        if (row.racket_omit == null) {
            const key = comptime webrtcKey(row.name);
            const sig = comptime funSig(cw, row, &.{});
            const slots = comptime slotIndexes(cw, row);
            if (slots.len == 0 or row.blocking) {
                try out.print(gpa, "\n   '{s}\n   (get-ffi-obj '{s} L {s})", .{ key, row.name, sig });
            } else {
                // Every out-bearing webrtc row has exactly one trailing cell.
                comptime std.debug.assert(slots.len == 1);
                const info = @typeInfo(@TypeOf(@field(cw, row.name))).@"fn";
                comptime std.debug.assert(slots[0] == info.params.len - 1);
                const cell = comptime slotCell(info.params[slots[0]].type.?).?;
                try out.print(gpa, "\n   '{s}\n   (wrap-out1 (get-ffi-obj '{s} L {s})\n              {s} {s})", .{ key, row.name, sig, cell.ctype, cell.init });
            }
        }
    }
    try out.appendSlice(gpa, "))\n");
    return out.toOwnedSlice(gpa);
}

fn webrtcKey(comptime name: []const u8) []const u8 {
    const stripped = name["pancake_webrtc_".len..];
    comptime var s: []const u8 = "";
    inline for (stripped) |ch| {
        s = s ++ &[_]u8{if (ch == '_') '-' else ch};
    }
    return s;
}
