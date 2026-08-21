//! The dlopen half of the TypeScript ABI mirror: the per-archive FFI symbol
//! tables, rendered from each archive's own symbols inventory, with the
//! comptime check that every export has a row. `ts_abi.zig` owns the output
//! list and the constants and layouts halves.

const std = @import("std");

const c = @import("c_abi");
const cd = @import("c_abi_host");
const cdr = @import("c_abi_driver");
const ci = @import("c_abi_net_transport_iroh");
const ct = @import("c_abi_net_transport_tcp");
const cin = @import("c_abi_net_transport_inproc");
const con = @import("c_abi_net_transport_onion");
const cw = @import("c_abi_net_transport_webrtc");
const cr = @import("c_abi_net_transport_relay");

fn checkInventory(comptime M: type) void {
    comptime {
        @setEvalBranchQuota(40_000);
        for (@typeInfo(M).@"struct".decl_names) |decl_name| {
            if (!std.mem.startsWith(u8, decl_name, "pancake_")) continue;
            if (@typeInfo(@TypeOf(@field(M, decl_name))) != .@"fn") continue;
            var listed = false;
            for (M.symbols.symbols) |row| {
                if (std.mem.eql(u8, row.name, decl_name)) listed = true;
            }
            for (M.symbols.omitted_families) |fam| {
                if (std.mem.startsWith(u8, decl_name, fam.prefix)) listed = true;
            }
            if (!listed) @compileError("export '" ++ decl_name ++ "' has no row (or omitted-family match) in its symbols.zig inventory");
        }
        for (M.symbols.symbols) |row| {
            // Resolving the name proves the row still names a live export.
            _ = @field(M, row.name);
        }
    }
}

comptime {
    checkInventory(c);
    checkInventory(cd);
    checkInventory(cdr);
    checkInventory(ct);
    checkInventory(cin);
    checkInventory(con);
    checkInventory(ci);
    checkInventory(cw);
    checkInventory(cr);
    for (cw.symbols.symbols) |row| {
        if (row.ts_omit == null) {
            @compileError("WebRTC export '" ++ row.name ++ "' promises a TypeScript native loader, but TypeScript WebRTC is browser-native");
        }
    }
}

/// The TS class letter for one parameter type: opaque handles and function
/// pointers cross as `P`, byte and struct slots as `B`, and the plain
/// integers by width. A row's `pointer_params` overrides its slot to `P`.
fn tsParamClass(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .optional => |o| tsParamClass(o.child),
        .pointer => |p| switch (p.size) {
            .many, .slice => "B",
            else => switch (@typeInfo(p.child)) {
                .@"opaque" => "P",
                .@"fn" => "P",
                else => "B",
            },
        },
        .int => switch (T) {
            u8 => "\"u8\"",
            u16 => "\"u16\"",
            u32 => "\"u32\"",
            u64 => "U64",
            usize => "U",
            // A signed 32-bit parameter is a timeout in milliseconds, where
            // negative means wait without limit — the one place this ABI takes a
            // signed integer in, and the same `I` the result classes use.
            i32 => "I",
            i64 => "\"i64\"",
            else => @compileError("unmapped integer parameter width"),
        },
        else => @compileError("unmapped parameter type"),
    };
}

fn tsResultClass(comptime T: type) []const u8 {
    return switch (T) {
        i32 => "I",
        u64 => "U64",
        void => "V",
        usize => "U",
        else => @compileError("unmapped result type"),
    };
}

/// Which one-letter shorthands a table's rows use, so the generated prelude
/// declares exactly those (an unused letter would trip deno lint).
const UsedClasses = struct {
    p: bool = false,
    b: bool = false,
    u: bool = false,
    i: bool = false,
    v: bool = false,
    u64: bool = false,

    fn note(self: *UsedClasses, class: []const u8) void {
        if (std.mem.eql(u8, class, "P")) self.p = true;
        if (std.mem.eql(u8, class, "B")) self.b = true;
        if (std.mem.eql(u8, class, "U")) self.u = true;
        if (std.mem.eql(u8, class, "I")) self.i = true;
        if (std.mem.eql(u8, class, "V")) self.v = true;
        if (std.mem.eql(u8, class, "U64")) self.u64 = true;
    }
};

/// One symbol's row rendered as parts, so the emitter can compose the
/// single-line and split forms without re-parsing its own output.
const RowParts = struct {
    params: []u8,
    result: []const u8,
    /// Rendered "outBuffers: [..]" text, or empty when the symbol crosses no
    /// buffers at all.
    out_buffers: []u8,
    nonblocking: bool,

    fn deinit(self: RowParts, gpa: std.mem.Allocator) void {
        gpa.free(self.params);
        gpa.free(self.out_buffers);
    }
};

fn rowParts(gpa: std.mem.Allocator, comptime M: type, comptime row: anytype, used: *UsedClasses) !RowParts {
    const info = @typeInfo(@TypeOf(@field(M, row.name))).@"fn";
    inline for (row.out_params) |op| {
        if (op >= info.param_types.len) {
            @compileError(row.name ++ " names an out parameter beyond its reflected arity");
        }
    }
    var params: std.ArrayList(u8) = .empty;
    errdefer params.deinit(gpa);
    try params.appendSlice(gpa, "parameters: [");
    var any_buffer = false;
    inline for (info.param_types, 0..) |param_type, i| {
        if (i != 0) try params.appendSlice(gpa, ", ");
        var class = tsParamClass(param_type.?);
        inline for (row.pointer_params) |pp| {
            if (pp == i) class = "P";
        }
        if (std.mem.eql(u8, class, "B")) any_buffer = true;
        used.note(class);
        try params.appendSlice(gpa, class);
    }
    try params.appendSlice(gpa, "]");
    const result = tsResultClass(info.return_type.?);
    used.note(result);
    var out_buffers: std.ArrayList(u8) = .empty;
    errdefer out_buffers.deinit(gpa);
    if (any_buffer) {
        try out_buffers.appendSlice(gpa, "outBuffers: [");
        for (row.out_params, 0..) |op, i| {
            if (i != 0) try out_buffers.appendSlice(gpa, ", ");
            try out_buffers.print(gpa, "{d}", .{op});
        }
        try out_buffers.appendSlice(gpa, "]");
    }
    return .{
        .params = try params.toOwnedSlice(gpa),
        .result = result,
        .out_buffers = try out_buffers.toOwnedSlice(gpa),
        .nonblocking = row.nonblocking,
    };
}

/// The dlopen row block for one archive, emitted in inventory order with the
/// annotated section comments; rows the inventory opts out of TS are skipped.
/// Row layout follows deno fmt: one line when it fits the 120-column width (a
/// tab counting four), the split object form otherwise.
fn renderRows(gpa: std.mem.Allocator, comptime M: type, used: *UsedClasses) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    inline for (M.symbols.symbols) |row| {
        if (row.ts_omit == null) {
            if (row.section) |section| {
                var it = std.mem.splitScalar(u8, section, '\n');
                while (it.next()) |l| try out.print(gpa, "\t// {s}\n", .{l});
            }
            const parts = try rowParts(gpa, M, row, used);
            defer parts.deinit(gpa);
            // Single-line width: tab(4) + name + ": { " + the parts joined by
            // ", " + " },".
            var width: usize = 4 + row.name.len + 4 + parts.params.len + 2 + 8 + parts.result.len + 3;
            if (parts.out_buffers.len != 0) width += 2 + parts.out_buffers.len;
            if (parts.nonblocking) width += 2 + 17;
            if (width <= 120) {
                try out.print(gpa, "\t{s}: {{ {s}, result: {s}", .{ row.name, parts.params, parts.result });
                if (parts.out_buffers.len != 0) try out.print(gpa, ", {s}", .{parts.out_buffers});
                if (parts.nonblocking) try out.appendSlice(gpa, ", nonblocking: true");
                try out.appendSlice(gpa, " },\n");
            } else {
                try out.print(gpa, "\t{s}: {{\n\t\t{s},\n\t\tresult: {s},\n", .{ row.name, parts.params, parts.result });
                if (parts.out_buffers.len != 0) try out.print(gpa, "\t\t{s},\n", .{parts.out_buffers});
                if (parts.nonblocking) try out.appendSlice(gpa, "\t\tnonblocking: true,\n");
                try out.appendSlice(gpa, "\t},\n");
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The `const P = …` shorthand prelude, declaring only the letters the rows
/// use.
fn renderLetters(gpa: std.mem.Allocator, out: *std.ArrayList(u8), used: UsedClasses) !void {
    const letters = [_]struct { on: bool, decl: []const u8 }{
        .{ .on = used.p, .decl = "P = \"pointer\"" },
        .{ .on = used.b, .decl = "B = \"buffer\"" },
        .{ .on = used.u, .decl = "U = \"usize\"" },
        .{ .on = used.i, .decl = "I = \"i32\"" },
        .{ .on = used.v, .decl = "V = \"void\"" },
        .{ .on = used.u64, .decl = "U64 = \"u64\"" },
    };
    var first = true;
    for (letters) |l| {
        if (!l.on) continue;
        if (first) {
            try out.print(gpa, "const {s},\n", .{l.decl});
            first = false;
        } else {
            try out.print(gpa, "\t{s},\n", .{l.decl});
        }
    }
    // The final letter line ends the const statement: drop its ",\n".
    out.items.len -= 2;
    try out.appendSlice(gpa, ";\n\n");
}

const ArchiveFingerprintSpec = struct {
    stem: []const u8,
    constant: []const u8,
};

fn renderDlopenFile(gpa: std.mem.Allocator, comptime M: type, comptime preamble: []const u8, comptime lib: []const u8, comptime table: []const u8, comptime fingerprint: ?ArchiveFingerprintSpec) ![]u8 {
    var used = UsedClasses{};
    const rows = try renderRows(gpa, M, &used);
    defer gpa.free(rows);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, preamble);
    try renderLetters(gpa, &out, used);
    try out.print(gpa, "export const {s} = lazySymbols(() => libPath(\"{s}\"), {{\n", .{ table, lib });
    try out.appendSlice(gpa, rows);
    if (fingerprint) |spec| {
        try out.print(gpa, "}}, {{\n\tsymbol: \"pancake_{s}_archive_fingerprint\",\n\texpected: {s},\n\tarchive: \"{s}\",\n}});\n", .{ spec.stem, spec.constant, lib });
    } else try out.appendSlice(gpa, "});\n");
    return out.toOwnedSlice(gpa);
}

const host_ffi_preamble =
    \\// GENERATED by `zig build gen-ts-abi` from src/c_abi/host (the annotated
    \\// symbol inventory in symbols.zig plus each export's reflected signature)
    \\// — do not edit.
    \\// `zig build gen-ts-abi-check` (part of `check`) fails when this is stale.
    \\//
    \\// Internal: the FFI mirror of the `pancake_host_*` family — the byte-fed
    \\// host tier (ADR-0072), the sibling of the Racket binding's `ffi-host.rkt`.
    \\//
    \\// Nothing here is public. This table loads `libpancake_host`, the archive
    \\// that owns every `pancake_host_*` symbol. The driver archive is a separate
    \\// consumer of Host and exports only its `pancake_driver_*` family. Host shares the
    \\// frame, argument, reference, and last-abort layouts by layout, so this
    \\// loader declares no core symbol. The host surface over it spans
    \\// `../../host.ts`, `../../session.ts`, `../../action.ts`, and
    \\// `../../pump.ts`. The wasm browser build keeps importing the byte-fed
    \\// `c_abi_host` root only; its injected adapter ignores the stem here.
    \\//
    \\// Callback discipline: the ONE native callback in the whole binding, the
    \\// shared behavior trampoline (`../../trampoline.ts`), fires synchronously
    \\// on the thread executing the enclosing `pancake_host_*` call. Deno and Bun
    \\// both register callbacks globally, so it is minted through the runtime
    \\// FFI's `makeCallback`, callable from any loaded archive; the wasm adapter
    \\// routes it through the module's single import. Settlements carry no
    \\// callback at all: they ride the action queue as SETTLE/FAIL, popped by
    \\// `pancake_host_next_action` and routed by vow id (`../../action.ts` +
    \\// `../../promise.ts`).
    \\//
    \\// `fetch`/`enliven`/`send` and the `vow_*` verbs each mint a host vow whose id
    \\// lands in the trailing out-buffer; the outcome arrives as that vow's
    \\// SETTLE/FAIL action. The `free` parameter of publish/spawn is always NULL
    \\// from this binding: the JS side owns its behavior entries in the trampoline
    \\// registry, so there is nothing for the library to free.
    \\
    \\import { libPath } from "./load.ts";
    \\import { lazySymbols } from "./runtime.ts";
    \\
    \\
;

const ocapn_ffi_preamble =
    \\// GENERATED by `zig build gen-ts-abi` from src/c_abi/ocapn (the annotated
    \\// symbol inventory in symbols.zig plus each export's reflected signature)
    \\// — do not edit.
    \\// `zig build gen-ts-abi-check` (part of `check`) fails when this is stale.
    \\//
    \\// Internal: the FFI mirror of `libpancake_ocapn` — the core archive (ADR-0059).
    \\//
    \\// Nothing here is part of the public API. The ergonomic surface reaches these
    \\// symbols through `ocapnS`; a consumer never imports this file. This loader
    \\// opens *only* `libpancake_ocapn`, and only the shared-vocabulary rows the
    \\// binding still speaks directly: the ABI version, the core last-error slot, the
    \\// allocation context, managed-frame release, the exporter-locator encoder, and
    \\// the OCapN URI grammar. The peer itself is driven through the byte-fed host
    \\// archive (`host.ts`, `libpancake_host`, ADR-0072), never through raw
    \\// raw per-session engine calls. Each transport archive has its own sibling loader
    \\// here (`tcp.ts`, `inproc.ts`), opened only when that transport is imported.
    \\//
    \\// The one-letter type shorthands (`P`/`B`/`U`/`I`/`V`) let a symbol's whole
    \\// signature sit on one line, so the table reads down like the C header it
    \\// mirrors. Every `internal/ffi` loader opens with the same header.
    \\
    \\import { libPath } from "./load.ts";
    \\import { lazySymbols } from "./runtime.ts";
    \\
    \\
;

pub fn generateHostFfi(gpa: std.mem.Allocator) ![]u8 {
    return renderDlopenFile(gpa, cd, host_ffi_preamble, "pancake_host", "hostS", null);
}

const loop_ffi_preamble =
    \\// GENERATED by `zig build gen-ts-abi` from src/c_abi/driver (the annotated
    \\// symbol inventory in symbols.zig plus each export's reflected signature)
    \\// — do not edit.
    \\// `zig build gen-ts-abi-check` (part of `check`) fails when this is stale.
    \\//
    \\// Internal: the FFI mirror of the `pancake_driver_*` loop family —
    \\// `libpancake_driver`, the driver archive (ADR-0112).
    \\//
    \\// Nothing here is public; `../../driver_loop.ts` is the surface over it.
    \\// The archive exports only this family and consumes a Host transferred from
    \\// `libpancake_host`. One thread drives one loop:
    \\// `pancake_driver_wake` is the one cross-thread call, and borrowed views
    \\// in a popped event die at the next `pancake_driver_next_event`.
    \\
    \\import { libPath } from "./load.ts";
    \\import { lazySymbols } from "./runtime.ts";
    \\
    \\
;

pub fn generateLoopFfi(gpa: std.mem.Allocator) ![]u8 {
    return renderDlopenFile(gpa, cdr, loop_ffi_preamble, "pancake_driver", "loopS", null);
}

pub fn generateOcapnFfi(gpa: std.mem.Allocator) ![]u8 {
    return renderDlopenFile(gpa, c, ocapn_ffi_preamble, "pancake_ocapn", "ocapnS", null);
}

const tcp_ffi_preamble =
    \\// GENERATED by `zig build gen-ts-abi` from src/c_abi/net_transport/tcp (the
    \\// annotated symbol inventory in symbols.zig plus each export's reflected
    \\// signature) — do not edit.
    \\// `zig build gen-ts-abi-check` (part of `check`) fails when this is stale.
    \\//
    \\// Internal: the FFI mirror of `libpancake_net_transport_tcp` — the blocking-TCP
    \\// transport archive (ADR-0059).
    \\//
    \\// Nothing here is public; `tcp.ts` is the ergonomic surface over it. This
    \\// loader opens *only* the TCP archive, so importing `tcp.ts` never pulls in
    \\// the inproc or iroh archives. The TCP archive is symbol-disjoint from the core
    \\// (it shares the frame/context types by layout, not by symbol), so it loads
    \\// alongside `libpancake_ocapn` rather than instead of it, and carries its own
    \\// thread-local last-error read through `pancake_tcp_last_error`.
    \\
    \\import { lazySymbols, libPath } from "@pancake/runtime/ffi";
    \\import { TCP_ARCHIVE_FINGERPRINT } from "@pancake/abi";
    \\
    \\
;

pub fn generateTcpFfi(gpa: std.mem.Allocator) ![]u8 {
    return renderDlopenFile(gpa, ct, tcp_ffi_preamble, "pancake_net_transport_tcp", "tcpS", .{ .stem = "tcp", .constant = "TCP_ARCHIVE_FINGERPRINT" });
}

const inproc_ffi_preamble =
    \\// GENERATED by `zig build gen-ts-abi` from src/c_abi/net_transport/inproc
    \\// (the annotated symbol inventory in symbols.zig plus each export's reflected
    \\// signature) — do not edit.
    \\// `zig build gen-ts-abi-check` (part of `check`) fails when this is stale.
    \\//
    \\// Internal: the FFI mirror of `libpancake_net_transport_inproc` — the
    \\// in-process transport archive (ADR-0059).
    \\//
    \\// Nothing here is public; `inproc.ts` is the ergonomic surface over it. This
    \\// loader opens *only* the inproc archive, so importing `inproc.ts` never pulls
    \\// in the TCP or iroh archives. The inproc family is symbol-disjoint from the
    \\// core and shares the frame/context types by layout; it carries its own
    \\// thread-local last-error read through `pancake_inproc_last_error`.
    \\
    \\import { lazySymbols, libPath } from "@pancake/runtime/ffi";
    \\import { INPROC_ARCHIVE_FINGERPRINT } from "@pancake/abi";
    \\
    \\
;

pub fn generateInprocFfi(gpa: std.mem.Allocator) ![]u8 {
    return renderDlopenFile(gpa, cin, inproc_ffi_preamble, "pancake_net_transport_inproc", "inprocS", .{ .stem = "inproc", .constant = "INPROC_ARCHIVE_FINGERPRINT" });
}

const onion_ffi_preamble =
    \\// GENERATED by `zig build gen-ts-abi` from src/c_abi/net_transport/onion
    \\// (the annotated symbol inventory in symbols.zig plus each export's
    \\// reflected signature) — do not edit.
    \\// `zig build gen-ts-abi-check` (part of `check`) fails when this is stale.
    \\//
    \\// Internal: the FFI mirror of `libpancake_net_transport_onion`'s C ABI.
    \\//
    \\// Nothing here is public; `transport/onion.ts` is the ergonomic surface over
    \\// it. This loader opens *only* the onion archive, so importing that module
    \\// never pulls in the TCP, inproc, or iroh archives. The onion family is
    \\// symbol-disjoint from the core and shares the frame/context types by layout;
    \\// it carries its own thread-local last-error read through
    \\// `pancake_onion_last_error`.
    \\
    \\import { lazySymbols, libPath } from "@pancake/runtime/ffi";
    \\import { ONION_ARCHIVE_FINGERPRINT } from "@pancake/abi";
    \\
    \\
;

pub fn generateOnionFfi(gpa: std.mem.Allocator) ![]u8 {
    return renderDlopenFile(gpa, con, onion_ffi_preamble, "pancake_net_transport_onion", "onionS", .{ .stem = "onion", .constant = "ONION_ARCHIVE_FINGERPRINT" });
}

const relay_ffi_preamble =
    \\// GENERATED by `zig build gen-ts-abi` from src/c_abi/net_transport/relay
    \\// (the annotated symbol inventory in symbols.zig plus each export's
    \\// reflected signature) — do not edit.
    \\// `zig build gen-ts-abi-check` (part of `check`) fails when this is stale.
    \\//
    \\// Internal: the FFI mirror of `libpancake_net_transport_relay`'s C ABI.
    \\// The archive owns one provider package for keyed-relay and noise-relay;
    \\// profile policy remains in the native driver.
    \\//
    \\// Nothing here is public; `transport/relay.ts` is the ergonomic surface.
    \\
    \\import { lazySymbols, libPath } from "@pancake/runtime/ffi";
    \\import { RELAY_ARCHIVE_FINGERPRINT } from "@pancake/abi";
    \\
;

pub fn generateRelayFfi(gpa: std.mem.Allocator) ![]u8 {
    return renderDlopenFile(gpa, cr, relay_ffi_preamble, "pancake_net_transport_relay", "relayS", .{ .stem = "relay", .constant = "RELAY_ARCHIVE_FINGERPRINT" });
}

const iroh_ffi_preamble =
    \\// GENERATED by `zig build gen-ts-abi` from src/c_abi/net_transport/iroh
    \\// (the annotated symbol inventory in symbols.zig plus each export's
    \\// reflected signature) — do not edit.
    \\// `zig build gen-ts-abi-check` (part of `check`) fails when this is stale.
    \\//
    \\// Internal: the FFI mirror of `libpancake_net_transport_iroh`'s C ABI.
    \\//
    \\// The iroh companion library (`libpancake_net_transport_iroh`, ADR-0055) is
    \\// optional — absent unless built with cargo — so it loads lazily on first use
    \\// through `irohS()`, which names how to produce it rather than surfacing a raw
    \\// dlopen failure. This loader opens *only* the iroh archive, through the core's
    \\// shared FFI runtime (`@pancake/runtime/ffi`). Nothing here is public; `mod.ts` is
    \\// the ergonomic surface over it.
    \\
    \\import { ffi, libFile, libPath, requireArchiveFingerprint, type Symbols } from "@pancake/runtime/ffi";
    \\import { IROH_ARCHIVE_FINGERPRINT } from "@pancake/abi";
    \\
    \\
;

const iroh_ffi_postamble =
    "} as const;\n\n" ++
    "let irohSyms: Symbols | null = null;\n\n" ++
    "// Open the iroh ABI library on first use. It is optional — absent unless built\n" ++
    "// with cargo — so a clear error names how to produce it rather than a raw\n" ++
    "// dlopen failure.\n" ++
    "export function irohS(): Symbols {\n" ++
    "\tif (irohSyms !== null) return irohSyms;\n" ++
    "\ttry {\n" ++
    "\t\tirohSyms = ffi.dlopen(\n" ++
    "\t\t\tlibPath(\"pancake_net_transport_iroh\"),\n" ++
    "\t\t\tirohSymbolDefs,\n" ++
    "\t\t);\n" ++
    "\t\trequireArchiveFingerprint(irohSyms, {\n" ++
    "\t\t\tsymbol: \"pancake_iroh_archive_fingerprint\",\n" ++
    "\t\t\texpected: IROH_ARCHIVE_FINGERPRINT,\n" ++
    "\t\t\tarchive: \"pancake_net_transport_iroh\",\n" ++
    "\t\t});\n" ++
    "\t} catch (e) {\n" ++
    "\t\tthrow new Error(\n" ++
    "\t\t\t`iroh transport unavailable: could not load ${\n" ++
    "\t\t\t\tlibFile(\"pancake_net_transport_iroh\")\n" ++
    "\t\t\t} from PANCAKE_LIB_DIR, the abi-versioned cache, zig-out/lib, or the system library path. ` +\n" ++
    "\t\t\t\t\"Build it with `zig build iroh-abi` (needs cargo). \" +\n" ++
    "\t\t\t\t(e instanceof Error ? e.message : String(e)),\n" ++
    "\t\t);\n" ++
    "\t}\n" ++
    "\treturn irohSyms;\n" ++
    "}\n";

pub fn generateIrohFfi(gpa: std.mem.Allocator) ![]u8 {
    var used = UsedClasses{};
    const rows = try renderRows(gpa, ci, &used);
    defer gpa.free(rows);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, iroh_ffi_preamble);
    try renderLetters(gpa, &out, used);
    try out.appendSlice(gpa, "const irohSymbolDefs = {\n");
    try out.appendSlice(gpa, rows);
    try out.appendSlice(gpa, iroh_ffi_postamble);
    return out.toOwnedSlice(gpa);
}
