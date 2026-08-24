//! Generates the expected struct sizes and field offsets every language
//! binding's hand-mirrored FFI struct pins against — Rust's `#[repr(C)]`
//! `const` assert blocks, Python's `pancake._pin.pin_struct`, and Racket's
//! `pin-layout!` `want-size` argument.
//!
//! Every binding hand-declares its own struct *shape* (`#[repr(C)]`,
//! `ctypes.Structure`, `define-cstruct`) because each language's FFI wants a
//! symbolic declaration, not a byte-offset reader (that is what
//! `tools/gen/binding/ts_abi.zig` is for). What used to drift was the *numbers* those
//! declarations are checked against: three languages each hand-copied the
//! same `@sizeOf`/`@offsetOf` values from the C headers' prose, so a Zig-side
//! field change had to be swept by hand into three unrelated files with no
//! compiler to catch a miss. Here the numbers come straight off
//! `@sizeOf`/`@offsetOf` on the real C ABI archive types, so a struct change
//! regenerates different numbers and `zig build gen-binding-ffi-layouts-check`
//! (part of `check`) rejects a binding whose pin has gone stale.
//!
//! Racket's `pin-layout!` re-derives each cstruct's field order and widths
//! from `ctype->layout`, so what it needs is a kind list rather than an
//! offset list, and that list is generated here too. Hand-authoring it was
//! the last hand-copy in this family, and it drifted: a cstruct swept
//! correctly to a changed `PancakeTraceEvent` failed against an expectation
//! nobody had swept, and the message blamed the mirror. An expectation
//! reflected off the Zig type cannot disagree with the Zig type.
//!
//! Both pointers and function pointers are emitted as `pointer`, and
//! `pin-layout!` normalizes `fpointer` to `pointer` before comparing: a
//! binding's choice between Racket's `_pointer` and `_fpointer` is a
//! convenience at the declaration, not an ABI fact, and the ABI fact is that
//! the slot is one pointer wide.

const std = @import("std");

const c = @import("c_abi");
const cd = @import("c_abi_host");
const cdr = @import("c_abi_driver");
const ct = @import("c_abi_net_transport_tcp");
const ci = @import("c_abi_net_transport_iroh");
const cr = @import("c_abi_net_transport_relay");
const cw = @import("c_abi_net_transport_webrtc");
const co = @import("c_abi_net_transport_onion");

const Output = @import("output").Output;

pub const step_name = "gen-binding-ffi-layouts";

pub const outputs = [_]Output{
    .{ .path = "bindings/rust/src/sys/layouts_gen.rs", .generate = generateRust },
    .{ .path = "bindings/python/pancake/_layouts_gen.py", .generate = generatePython },
    .{ .path = "bindings/racket/private/layouts-gen.rkt", .generate = generateRacket },
};

/// One reflected struct field: `name` is the field's SCREAMING_SNAKE spelling
/// (the mechanical uppercase of the Zig field name, matching `ts_abi_gen`'s
/// convention), `lower` is the Zig spelling a mirror declares its own field
/// by, `off` is `@offsetOf`, `size` is `@sizeOf` of the field's own type, and
/// `racket` is the field's `ctype->layout` kind.
const FieldOff = struct {
    name: []const u8,
    lower: []const u8,
    off: usize,
    size: usize,
    racket: []const u8,
};

/// The `ctype->layout` kind Racket reports for a slot of this Zig type.
/// Unmapped types are a build error rather than a guess, because a guess here
/// would be an expectation that agrees with nothing.
fn racketKind(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .int => |info| std.fmt.comptimePrint("{s}{d}", .{
            if (info.signedness == .signed) "int" else "uint",
            info.bits,
        }),
        .float => |info| switch (info.bits) {
            32 => "float",
            64 => "double",
            else => @compileError("no Racket ctype kind for " ++ @typeName(T)),
        },
        // Data pointer or function pointer alike: one pointer-wide slot.
        .pointer => "pointer",
        // An optional pointer is the null-pointer representation, one
        // pointer-wide slot with no tag, so it reports what its child does.
        // Any other optional carries a tag byte the child never had, and
        // answering with the child's kind would state a width the ABI does not
        // have. An extern struct cannot hold one, so this is a guard rather
        // than a case, and it fails the build rather than guessing.
        .optional => |info| switch (@typeInfo(info.child)) {
            .pointer => "pointer",
            else => @compileError("no Racket ctype kind for the tagged optional " ++ @typeName(T)),
        },
        .array => |info| "#(" ++ racketKind(info.child) ++
            std.fmt.comptimePrint(" {d})", .{info.len}),
        .@"struct" => |info| blk: {
            comptime var text: []const u8 = "(";
            inline for (info.field_types, 0..) |field_type, i| {
                text = text ++ (if (i == 0) "" else " ") ++ racketKind(field_type);
            }
            break :blk text ++ ")";
        },
        else => @compileError("no Racket ctype kind for " ++ @typeName(T)),
    };
}

/// One reflected struct: `stem` is the SCREAMING_SNAKE prefix every
/// language's constants share, derived by hand from the Zig type name so the
/// table reads as a name-to-type map, not a name computed from a name.
const Layout = struct {
    stem: []const u8,
    size: usize,
    fields: []const FieldOff,
};

fn upperName(comptime name: []const u8) []const u8 {
    @setEvalBranchQuota(100_000);
    comptime var buf: [name.len]u8 = undefined;
    for (name, 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
    // Rebind through a fresh `const` so the returned slice points at an
    // anonymous constant rather than this function's comptime-var frame,
    // which a global (`layouts`) may not reference.
    const frozen: [name.len]u8 = buf;
    return &frozen;
}

fn layoutOf(comptime stem: []const u8, comptime T: type) Layout {
    const type_info = @typeInfo(T).@"struct";
    const type_fields = type_info.field_names;
    comptime var offs: [type_fields.len]FieldOff = undefined;
    for (type_fields, type_info.field_types, 0..) |field_name, field_type, i| {
        offs[i] = .{
            .name = upperName(field_name),
            .lower = field_name,
            .off = @offsetOf(T, field_name),
            .size = @sizeOf(field_type),
            .racket = racketKind(field_type),
        };
    }
    const frozen: [type_fields.len]FieldOff = offs;
    return .{ .stem = stem, .size = @sizeOf(T), .fields = &frozen };
}

// One canonical manifest drives both archive fingerprints and every generated
// binding layout expectation. Widening a public C struct inventory therefore
// cannot update load-time identity without also updating the mirrors.
const contract_layouts = c.contract_layouts ++ cd.contract_layouts ++
    cdr.contract_layouts ++ ct.contract_layouts ++ ci.contract_layouts ++
    cr.contract_layouts ++ cw.contract_layouts ++ co.contract_layouts;

const binding_layout_count = blk: {
    var count: usize = 0;
    for (contract_layouts) |entry| {
        if (entry.binding_mirror) count += 1;
    }
    break :blk count;
};

const layouts = blk: {
    var reflected: [binding_layout_count]Layout = undefined;
    var index: usize = 0;
    for (contract_layouts) |entry| {
        if (!entry.binding_mirror) continue;
        reflected[index] = layoutOf(entry.stem, entry.Type);
        index += 1;
    }
    break :blk reflected;
};

fn generateRust(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\//! GENERATED by `zig build gen-binding-ffi-layouts` from src/c_abi (the
        \\//! ocapn, driver, and iroh transport archives) — do not edit.
        \\//! `zig build gen-binding-ffi-layouts-check` (part of `check`) fails when
        \\//! this is stale.
        \\//!
        \\//! Expected sizes and field offsets for the hand-mirrored `#[repr(C)]`
        \\//! structs in `sys::ocapn`, `sys::host`, and `sys::iroh`: values come
        \\//! from `@sizeOf`/`@offsetOf` on the real Zig C ABI types, so a Zig-side
        \\//! field change moves a number here and the `const` assert blocks that
        \\//! check against these constants fail loudly instead of silently
        \\//! misparsing a frame or an action.
        \\#![allow(dead_code)]
        \\
        \\
    );
    inline for (layouts) |layout| {
        try out.print(gpa, "pub const {s}_SIZE: usize = {d};\n", .{ layout.stem, layout.size });
        inline for (layout.fields) |field| {
            try out.print(gpa, "pub const {s}_{s}_OFF: usize = {d};\n", .{ layout.stem, field.name, field.off });
        }
    }
    return out.toOwnedSlice(gpa);
}

fn generatePython(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\# GENERATED by `zig build gen-binding-ffi-layouts` from src/c_abi (the
        \\# ocapn, driver, and iroh transport archives) — do not edit.
        \\# `zig build gen-binding-ffi-layouts-check` (part of `check`) fails when
        \\# this is stale.
        \\#
        \\# The whole shape of every C ABI struct the hand-mirrored
        \\# ctypes.Structure types in _ffi_ocapn, _ffi_host, _ffi_iroh, and
        \\# _ffi_webrtc declare: struct size, then one row per field carrying
        \\# its name, its offset, and its own width. Values come from
        \\# @sizeOf/@offsetOf on the real Zig C ABI types, so a Zig-side field
        \\# change moves a row here and `pancake._pin.pin_struct` fails loudly
        \\# at import time instead of silently misparsing a frame, an action,
        \\# or a trace fact.
        \\
        \\LAYOUTS: dict[str, tuple[int, tuple[tuple[str, int, int], ...]]] = {
        \\
    );
    inline for (layouts) |layout| {
        try out.print(gpa, "    \"{s}\": ({d}, (\n", .{ layout.stem, layout.size });
        inline for (layout.fields) |field| {
            try out.print(gpa, "        (\"{s}\", {d}, {d}),\n", .{ field.lower, field.off, field.size });
        }
        try out.appendSlice(gpa, "    )),\n");
    }
    try out.appendSlice(gpa, "}\n");
    return out.toOwnedSlice(gpa);
}

fn generateRacket(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\#lang racket/base
        \\;; GENERATED by `zig build gen-binding-ffi-layouts` from src/c_abi (the
        \\;; ocapn, driver, and iroh transport archives) — do not edit.
        \\;; `zig build gen-binding-ffi-layouts-check` (part of `check`) fails when
        \\;; this is stale.
        \\;;
        \\;; The size and the ctype->layout kind list the hand-mirrored cstructs
        \\;; in ffi-shared.rkt, ffi-iroh.rkt, and ffi-webrtc.rkt pass to
        \\;; pin-layout!. Both come off @sizeOf/@offsetOf on the real Zig C ABI
        \\;; types, so pin-layout! compares a cstruct against the ABI itself
        \\;; rather than against a hand-copied expectation beside it. Function
        \\;; pointers are stated as `pointer`; pin-layout! normalizes the
        \\;; cstruct's `fpointer` slots the same way.
        \\
        \\(provide
        \\
    );
    inline for (layouts) |layout| {
        try out.appendSlice(gpa, "  ");
        try writeConstName(&out, gpa, layout.stem, "-SIZE");
        try out.appendSlice(gpa, "\n  ");
        try writeConstName(&out, gpa, layout.stem, "-LAYOUT");
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, ")\n\n");
    inline for (layouts) |layout| {
        try out.appendSlice(gpa, "(define ");
        try writeConstName(&out, gpa, layout.stem, "-SIZE");
        try out.print(gpa, " {d})\n", .{layout.size});
        try out.appendSlice(gpa, "(define ");
        try writeConstName(&out, gpa, layout.stem, "-LAYOUT");
        try out.appendSlice(gpa, " '(");
        inline for (layout.fields, 0..) |field, i| {
            if (i != 0) try out.append(gpa, ' ');
            try out.appendSlice(gpa, field.racket);
        }
        try out.appendSlice(gpa, "))\n");
    }
    return out.toOwnedSlice(gpa);
}

/// Racket names read kebab, not SCREAMING_SNAKE: `PANCAKE-REFERENCE-SIZE`.
fn writeConstName(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    stem: []const u8,
    suffix: []const u8,
) !void {
    for (stem) |ch| try out.append(gpa, if (ch == '_') '-' else ch);
    try out.appendSlice(gpa, suffix);
}
