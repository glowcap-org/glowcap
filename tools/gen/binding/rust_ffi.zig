//! Generates the Rust binding's extern blocks from each archive's annotated
//! symbol inventory plus its generated C header.
//!
//! The split of truth: parameter and return *types* reflect from the real Zig
//! exports (`@typeInfo`, so a signature change regenerates a different file),
//! parameter *names* come from the generated C header (Zig reflection strips
//! them; the header is generated from the same source and gate-held, so its
//! names are canonical), and the inventory supplies order and the `rust_omit`
//! rows. Each emitted file is a sibling module the hand-authored `sys/` file
//! re-exports — the struct mirrors, layout pins, and doc prose stay
//! hand-written beside it. `zig build gen-binding-rust-ffi-check` (part of
//! `check`) holds the committed files against a fresh generation.

const std = @import("std");
const cl = @import("c_abi_loam");
const cln = @import("c_abi_loam_lmdb");
const cls = @import("c_abi_loam_sqlite");
const clv = @import("c_abi_loam_volatile");

const c = @import("c_abi");
const cd = @import("c_abi_host");
const cdr = @import("c_abi_driver");
const ci = @import("c_abi_net_transport_iroh");
const ct = @import("c_abi_net_transport_tcp");
const cin = @import("c_abi_net_transport_inproc");
const con = @import("c_abi_net_transport_onion");
const cw = @import("c_abi_net_transport_webrtc");
const cr = @import("c_abi_net_transport_relay");

pub const step_name = "gen-binding-rust-ffi";

const Output = @import("output").Output;

pub const outputs = [_]Output{
    .{ .path = "bindings/rust/src/sys/loam_fns_gen.rs", .generate = generateLoam },
    .{ .path = "bindings/rust/src/sys/loam_lmdb_fns_gen.rs", .generate = generateLoamLmdb },
    .{ .path = "bindings/rust/src/sys/loam_sqlite_fns_gen.rs", .generate = generateLoamSqlite },
    .{ .path = "bindings/rust/src/sys/loam_volatile_fns_gen.rs", .generate = generateLoamVolatile },
    .{ .path = "bindings/rust/src/sys/ocapn_fns_gen.rs", .generate = generateOcapn },
    .{ .path = "bindings/rust/src/sys/host_fns_gen.rs", .generate = generateHost },
    .{ .path = "bindings/rust/src/sys/driver_fns_gen.rs", .generate = generateLoop },
    .{ .path = "bindings/rust/src/sys/tcp_fns_gen.rs", .generate = generateTcp },
    .{ .path = "bindings/rust/src/sys/inproc_fns_gen.rs", .generate = generateInproc },
    .{ .path = "bindings/rust/src/sys/onion_fns_gen.rs", .generate = generateOnion },
    .{ .path = "bindings/rust/src/sys/iroh_fns_gen.rs", .generate = generateIroh },
    .{ .path = "bindings/rust/src/sys/webrtc_fns_gen.rs", .generate = generateWebrtc },
    .{ .path = "bindings/rust/src/sys/relay_fns_gen.rs", .generate = generateRelay },
};

/// `module.GlowcapIrohNetlayer` → `GlowcapIrohNetlayer`.
const baseName = @import("reflect").baseName;

/// A named function-pointer alias the base spelling has no case for: the Zig
/// alias's type maps to its Rust `pub type` twin by type equality.
const Special = struct {
    T: type,
    spelling: []const u8,
};

/// The Rust FFI spelling of one parameter type. Byte pointers spell
/// `c_uchar`, `u32` spells `c_uint`, `anyopaque` spells `c_void` (the
/// `core::ffi` aliases the hand blocks use); struct and opaque pointers spell
/// their `#[repr(C)]` mirror's name; a nested optional pointer (`?*?*X`) is
/// an out-slot, `*mut *mut X`. `specials` maps named function-pointer aliases
/// to their Rust `pub type` twins.
fn rustParamType(comptime T: type, comptime specials: []const Special) []const u8 {
    inline for (specials) |s| {
        if (T == s.T) return s.spelling;
    }
    return switch (@typeInfo(T)) {
        .optional => |o| rustParamType(o.child, specials),
        .pointer => |p| blk: {
            const mutability = if (p.attrs.@"const") "*const " else "*mut ";
            const child = switch (@typeInfo(p.child)) {
                .optional => |inner| return (if (p.attrs.@"const") "*const " else "*mut ") ++ rustParamType(inner.child, specials),
                else => p.child,
            };
            const child_name = if (child == u8)
                "c_uchar"
            else if (child == anyopaque)
                "c_void"
            else
                baseName(child);
            break :blk mutability ++ child_name;
        },
        .int => switch (T) {
            i32 => "c_int",
            i64 => "i64",
            u8 => "u8",
            u16 => "u16",
            u32 => "c_uint",
            u64 => "u64",
            usize => "usize",
            else => @compileError("unmapped integer parameter width"),
        },
        else => @compileError("unmapped parameter type"),
    };
}

/// The Rust return spelling, or empty for void (no `->` clause).
fn rustReturnType(comptime T: type) []const u8 {
    return switch (T) {
        i32 => "c_int",
        u64 => "u64",
        usize => "usize",
        void => "",
        else => @compileError("unmapped result type"),
    };
}

// The header-name parser is shared with the Racket generator.
const headerParamNames = @import("header_names.zig").headerParamNames;

/// C parameter names are not constrained by Rust's keyword set. Keep the
/// header spelling recognizable and append one underscore when Rust reserves
/// it (`ref` is used by the Host capability-release API).
fn isRustKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "as",      "async",   "await",  "break",  "const",    "continue", "crate",
        "dyn",     "else",    "enum",   "extern", "false",    "fn",       "for",
        "gen",     "if",      "impl",   "in",     "let",      "loop",     "match",
        "mod",     "move",    "mut",    "pub",    "ref",      "return",   "self",
        "Self",    "static",  "struct", "super",  "trait",    "true",     "try",
        "type",    "unsafe",  "use",    "where",  "while",    "abstract", "become",
        "box",     "do",      "final",  "macro",  "override", "priv",     "typeof",
        "unsized", "virtual", "yield",
    };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, name, keyword)) return true;
    }
    return false;
}

fn appendRustParamName(out: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8) !void {
    try out.appendSlice(gpa, name);
    if (isRustKeyword(name)) try out.append(gpa, '_');
}

/// Render one archive's whole generated file: the shared GENERATED banner,
/// the archive's use-lines, and the extern block reflected from `M`'s
/// inventory with names from `header_path`.
fn renderArchive(
    gpa: std.mem.Allocator,
    comptime M: type,
    comptime header_path: []const u8,
    comptime archive_note: []const u8,
    comptime uses: []const u8,
    comptime specials: []const Special,
) ![]u8 {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const header = try std.Io.Dir.cwd().readFileAlloc(io, header_path, gpa, .limited(1 << 20));
    defer gpa.free(header);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\// GENERATED by `zig build gen-binding-rust-ffi` (the annotated symbol
        \\// inventory in the archive's symbols.zig, each export's reflected
        \\// signature, and the generated header's parameter names) — do not edit.
        \\// `zig build gen-binding-rust-ffi-check` (part of `check`) fails when this
        \\// is stale.
        \\//
        \\
    );
    try out.appendSlice(gpa, archive_note);
    try out.appendSlice(gpa, "#![allow(dead_code)]\n\n");
    try out.appendSlice(gpa, uses);
    // `unsafe extern` is the Rust 2024 form: declaring a foreign signature is
    // itself the unsafe act, because nothing checks the declaration against the
    // archive. Every crate here is edition 2024, so the bare `extern` a 2021
    // parser wants would not compile.
    try out.appendSlice(gpa, "\nunsafe extern \"C\" {\n");

    inline for (M.symbols.symbols) |row| {
        if (row.rust_omit == null) {
            const names = (try headerParamNames(gpa, header, row.name)) orelse
                return error.PrototypeMissingFromHeader;
            defer gpa.free(names);
            const info = @typeInfo(@TypeOf(@field(M, row.name))).@"fn";
            if (names.len != info.param_types.len) {
                std.debug.print("param count mismatch for {s}: header {d} vs reflected {d}\n", .{ row.name, names.len, info.param_types.len });
                return error.HeaderParamCountMismatch;
            }

            const ret = comptime rustReturnType(info.return_type.?);
            // Single-line when it fits rustfmt's width (a tab counting four);
            // one-parameter-per-line otherwise, the hand blocks' own shape.
            var width: usize = 4 + 7 + row.name.len + 2 + 1;
            inline for (info.param_types, 0..) |param_type, i| {
                if (i != 0) width += 2;
                width += names[i].len + @intFromBool(isRustKeyword(names[i])) + 2 + (comptime rustParamType(param_type.?, specials)).len;
            }
            if (ret.len != 0) width += 4 + ret.len;
            if (width < 120) {
                try out.print(gpa, "\tpub fn {s}(", .{row.name});
                inline for (info.param_types, 0..) |param_type, i| {
                    if (i != 0) try out.appendSlice(gpa, ", ");
                    try appendRustParamName(&out, gpa, names[i]);
                    try out.print(gpa, ": {s}", .{comptime rustParamType(param_type.?, specials)});
                }
                if (ret.len != 0) {
                    try out.print(gpa, ") -> {s};\n", .{ret});
                } else {
                    try out.appendSlice(gpa, ");\n");
                }
            } else if (width == 120 and ret.len != 0) {
                // At exactly the boundary rustfmt keeps the parameters on one
                // line and moves only the return arrow, indented one tab from
                // the signature. Emit that canonical shape so generation and
                // formatting cannot alternate forever. (The 2021 style edition
                // indented the arrow two tabs; `bindings-fmt-check` and
                // `gen-binding-rust-ffi-check` pin the pair from both sides, so
                // a future rustfmt that moves it again is caught rather than
                // becoming a silent alternation.)
                try out.print(gpa, "\tpub fn {s}(", .{row.name});
                inline for (info.param_types, 0..) |param_type, i| {
                    if (i != 0) try out.appendSlice(gpa, ", ");
                    try appendRustParamName(&out, gpa, names[i]);
                    try out.print(gpa, ": {s}", .{comptime rustParamType(param_type.?, specials)});
                }
                try out.print(gpa, ")\n\t-> {s};\n", .{ret});
            } else {
                try out.print(gpa, "\tpub fn {s}(\n", .{row.name});
                inline for (info.param_types, 0..) |param_type, i| {
                    try out.appendSlice(gpa, "\t\t");
                    try appendRustParamName(&out, gpa, names[i]);
                    try out.print(gpa, ": {s},\n", .{comptime rustParamType(param_type.?, specials)});
                }
                if (ret.len != 0) {
                    try out.print(gpa, "\t) -> {s};\n", .{ret});
                } else {
                    try out.appendSlice(gpa, "\t);\n");
                }
            }
        }
    }
    try out.appendSlice(gpa, "}\n");
    return out.toOwnedSlice(gpa);
}

fn generateLoop(gpa: std.mem.Allocator) ![]u8 {
    return renderArchive(gpa, cdr, "include/glowcap_driver.h",
        \\// The raw extern block of the `glowcap_driver_*` loop family (ADR-0024),
        \\// exported only by `libglowcap_driver`. The loop adopts a Host created
        \\// through the separate `libglowcap_host` archive. The hand-written
        \\// sibling (`driver.rs`) owns the `#[repr(C)]` mirrors and their layout
        \\// pins, and re-exports this block.
        \\
        \\
    ,
        \\use core::ffi::{c_int, c_uchar, c_uint};
        \\
    ++ "\nuse super::driver::{\n" ++
        "\tGlowcapDriverEvent, GlowcapDriverFailure, GlowcapDriverLoop, GlowcapDriverOptions, GlowcapTransportOperationOptions,\n" ++
        "};\n" ++
        \\use super::host::{GlowcapCloseOptions, GlowcapHost, GlowcapHostSession};
        \\use super::ocapn::GlowcapLocatorView;
        \\use crate::sys::{GlowcapReference, GlowcapTransportProvider};
        \\
    , &.{});
}

fn generateOcapn(gpa: std.mem.Allocator) ![]u8 {
    return renderArchive(gpa, c, "include/glowcap_ocapn.h",
        \\// The raw extern block of `libglowcap_ocapn`. The hand-written sibling
        \\// (`ocapn.rs`) owns the shared `#[repr(C)]` mirrors and their layout pins,
        \\// and re-exports this block, so consumers keep their `sys::glowcap_*` paths.
        \\
        \\
    , "use core::ffi::{c_int, c_uchar, c_uint};\n\n" ++
        "use super::ocapn::{\n" ++
        "\tGlowcapAllocator, GlowcapContext, GlowcapFailureEvent, GlowcapFailureReport, GlowcapLocator,\n" ++
        "\tGlowcapLocatorHintView, GlowcapLocatorView, GlowcapManagedFrame, GlowcapSturdyRef,\n" ++
        "};\n", &.{});
}

fn generateHost(gpa: std.mem.Allocator) ![]u8 {
    return renderArchive(gpa, cd, "include/glowcap_host.h",
        \\// The raw extern block of the `glowcap_host_*` family, exported by the
        \\// `libglowcap_host` archive. The hand-written sibling
        \\// (`host.rs`) owns the `#[repr(C)]` mirrors, the callback `pub type`
        \\// aliases, and their layout pins, and re-exports this block, so consumers
        \\// keep their `sys::host::glowcap_host_*` paths.
        \\
        \\
    , "use core::ffi::{c_int, c_uchar, c_uint, c_void};\n\n" ++
        "use super::host::{\n" ++
        "\tGlowcapCloseOptions, GlowcapHost, GlowcapHostBehavior, GlowcapHostCtxFree, GlowcapHostPumpHooks,\n" ++
        "\tGlowcapHostSession, GlowcapHostTurn, GlowcapPartnerIdentity, GlowcapSessionLimitOptions, GlowcapTraceCallback,\n" ++
        "};\n" ++
        "use super::ocapn::{GlowcapLocatorHintView, GlowcapLocatorView};\n" ++
        "use crate::sys::{GlowcapArgument, GlowcapContext, GlowcapLastAbort, GlowcapManagedFrame, GlowcapReference};\n", &.{
        .{ .T = cd.GlowcapHostBehavior, .spelling = "GlowcapHostBehavior" },
        .{ .T = cd.GlowcapTraceCallback, .spelling = "GlowcapTraceCallback" },
        .{ .T = cd.GlowcapHostCtxFree, .spelling = "GlowcapHostCtxFree" },
    });
}

fn generateTcp(gpa: std.mem.Allocator) ![]u8 {
    return renderArchive(gpa, ct, "include/glowcap_net_transport_tcp.h",
        \\// The raw extern block of `libglowcap_net_transport_tcp`. The hand-written
        \\// sibling (`tcp.rs`) owns the opaque types and re-exports this block, so
        \\// consumers keep their `sys::tcp::glowcap_tcp_*` paths.
        \\
        \\
    , "use core::ffi::{c_int, c_uchar, c_uint};\n\n" ++
        "use super::tcp::{GlowcapTcpConfig, GlowcapTcpConn, GlowcapTcpListener, GlowcapTcpNetlayer, GlowcapTcpStreamOptions};\n" ++
        "use crate::sys::{GlowcapContext, GlowcapFrame, GlowcapManagedFrame, GlowcapTransportProvider};\n", &.{});
}

fn generateInproc(gpa: std.mem.Allocator) ![]u8 {
    return renderArchive(gpa, cin, "include/glowcap_net_transport_inproc.h",
        \\// The raw extern block of `libglowcap_net_transport_inproc`. The
        \\// hand-written sibling (`inproc.rs`) owns the opaque types and re-exports
        \\// this block, so consumers keep their `sys::inproc::glowcap_inproc_*` paths.
        \\
        \\
    ,
        \\use core::ffi::{c_int, c_uchar, c_uint};
        \\
        \\use super::inproc::{GlowcapInprocConn, GlowcapInprocListener, GlowcapInprocNetlayer};
        \\use crate::sys::{GlowcapContext, GlowcapFrame, GlowcapManagedFrame};
        \\
    , &.{});
}

fn generateOnion(gpa: std.mem.Allocator) ![]u8 {
    return renderArchive(gpa, con, "include/glowcap_net_transport_onion.h",
        \\// The raw extern block of `libglowcap_net_transport_onion`. The
        \\// hand-written sibling (`onion.rs`) owns the opaque types and re-exports
        \\// this block, so consumers keep their `sys::onion::glowcap_onion_*` paths.
        \\
        \\
    ,
        \\use core::ffi::{c_int, c_uchar, c_uint};
        \\
        \\use super::onion::{GlowcapOnionConfig, GlowcapOnionConn};
        \\use super::onion::{GlowcapOnionListener, GlowcapOnionNetlayer};
        \\use crate::sys::{GlowcapContext, GlowcapFrame, GlowcapManagedFrame, GlowcapTransportProvider};
        \\
    , &.{});
}

fn generateIroh(gpa: std.mem.Allocator) ![]u8 {
    return renderArchive(gpa, ci, "include/glowcap_net_transport_iroh.h",
        \\// The raw extern block of `libglowcap_net_transport_iroh`. The hand-written
        \\// sibling (`iroh.rs`) owns the opaque types, the `#[repr(C)]` mirrors and
        \\// their layout pins, and re-exports this block, so consumers keep their
        \\// `sys::iroh::glowcap_iroh_*` paths.
        \\
        \\
    ,
        \\use core::ffi::{c_int, c_uchar};
        \\
        \\use super::GlowcapTransportProvider;
        \\use super::iroh::{GlowcapIrohConfig, GlowcapIrohConn, GlowcapIrohNetlayer, GlowcapIrohReadyEvent};
        \\
    , &.{});
}

fn generateWebrtc(gpa: std.mem.Allocator) ![]u8 {
    return renderArchive(gpa, cw, "include/glowcap_net_transport_webrtc.h",
        \\// The raw extern block of `libglowcap_net_transport_webrtc`. The
        \\// hand-written sibling (`webrtc.rs`) owns the opaque handles and readiness
        \\// record and re-exports this block, so consumers keep their
        \\// `sys::webrtc::glowcap_webrtc_*` paths.
        \\
        \\
    , "use core::ffi::{c_int, c_uchar};\n\n" ++
        "use super::GlowcapTransportProvider;\n" ++
        "use super::webrtc::{GlowcapWebrtcConfig, GlowcapWebrtcNetlayer, GlowcapWebrtcPeer, GlowcapWebrtcReadyEvent};\n", &.{});
}

fn generateRelay(gpa: std.mem.Allocator) ![]u8 {
    return renderArchive(gpa, cr, "include/glowcap_net_transport_relay.h",
        \\// The raw extern block of `libglowcap_net_transport_relay`. The hand-written
        \\// sibling (`relay.rs`) owns the config and opaque handle mirrors and
        \\// re-exports this block, so consumers keep their `sys::relay::*` paths.
        \\
        \\
    , "use core::ffi::{c_int, c_uchar};\n\n" ++
        "use super::GlowcapTransportProvider;\n" ++
        "use super::ocapn::GlowcapContext;\n" ++
        "use super::relay::{GlowcapRelayConfig, GlowcapRelayRuntime};\n", &.{});
}

fn generateLoam(gpa: std.mem.Allocator) ![]u8 {
    return renderArchive(gpa, cl, "include/glowcap_loam.h", "// Portable Loam extern projection.\n", "use super::layouts::*;\nuse crate::sys::host::{GlowcapHost, GlowcapHostSession};\nuse crate::sys::ocapn::GlowcapContext;\nuse crate::sys::{GlowcapArgument, GlowcapReference};\nuse core::ffi::{c_int, c_uchar, c_uint, c_void};\n", &.{ .{ .T = cl.GlowcapLoamEntropyFn, .spelling = "Option<GlowcapLoamEntropyFn>" }, .{ .T = cl.GlowcapLoamKvFn, .spelling = "Option<GlowcapLoamKvFn>" } });
}
fn generateLoamLmdb(gpa: std.mem.Allocator) ![]u8 {
    return renderArchive(gpa, cln, "include/glowcap_loam_lmdb.h", "// LMDB Loam extern projection.\n", "use super::layouts::*;\nuse crate::sys::GlowcapReference;\nuse core::ffi::{c_int, c_uchar, c_uint};\n", &.{});
}
fn generateLoamSqlite(gpa: std.mem.Allocator) ![]u8 {
    return renderArchive(gpa, cls, "include/glowcap_loam_sqlite.h", "// SQLite Loam extern projection.\n", "use super::layouts::*;\nuse crate::sys::GlowcapReference;\nuse core::ffi::{c_int, c_uchar, c_uint};\n", &.{});
}
fn generateLoamVolatile(gpa: std.mem.Allocator) ![]u8 {
    return renderArchive(gpa, clv, "include/glowcap_loam_volatile.h", "// In-memory Loam extern projection.\n", "use super::layouts::*;\nuse crate::sys::GlowcapReference;\nuse core::ffi::{c_int, c_uchar, c_uint};\n", &.{});
}
