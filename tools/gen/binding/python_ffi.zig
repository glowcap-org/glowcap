//! Generates the Python binding's ctypes signature tables from each
//! archive's annotated symbol inventory.
//!
//! The ctypes dicts are positional, so unlike the Rust extern blocks no
//! parameter-name source is needed: parameter and return *types* reflect from
//! the real Zig exports (`@typeInfo`, so a signature change regenerates a
//! different file) and the inventory supplies order and the `python_omit`
//! rows. The one output is a sibling module the hand-authored `_ffi_*.py`
//! loaders call: each generated function takes the hand-mirrored `Structure`
//! and callback types its archive names as parameters, so the module imports
//! nothing but `ctypes` and no import cycle forms. `zig build
//! gen-binding-python-ffi-check` (part of `check`) holds the committed file
//! against a fresh generation.

const std = @import("std");

const c = @import("c_abi");
const cd = @import("c_abi_host");
const ci = @import("c_abi_net_transport_iroh");
const ct = @import("c_abi_net_transport_tcp");
const cin = @import("c_abi_net_transport_inproc");
const cw = @import("c_abi_net_transport_webrtc");

pub const step_name = "gen-binding-python-ffi";

const Output = @import("output").Output;

pub const outputs = [_]Output{
    .{ .path = "bindings/python/pancake/_sigs_gen.py", .generate = generate },
};

/// `module.PancakeIrohConfig` → `PancakeIrohConfig`.
const baseName = @import("reflect").baseName;

/// `PancakeDialPlan` → `_DialPlan`, the hand mirrors' naming rule.
fn mirrorName(comptime T: type) []const u8 {
    const base = baseName(T);
    if (!std.mem.startsWith(u8, base, "Pancake"))
        @compileError("struct parameter without the Pancake prefix: " ++ base);
    return "_" ++ base["Pancake".len..];
}

/// A named function-pointer alias the base spelling has no case for: the Zig
/// alias's type maps to its ctypes spelling by type equality.
const Special = struct {
    T: type,
    spelling: []const u8,
};

/// The ctypes spelling of one parameter type. Byte and `anyopaque` pointers
/// spell `P` (`c_void_p`, which accepts every call style the binding uses:
/// buffers, casts, and None); a single-pointer out-slot of a handle spells
/// `ctypes.POINTER(P)` while a borrowed *array* of pointers or scalars stays
/// `P`; single-pointer scalars spell their typed `*_p` alias; struct pointers
/// spell `ctypes.POINTER(_X)` through the mirror rule.
fn pyParamType(comptime T: type, comptime specials: []const Special) []const u8 {
    inline for (specials) |s| {
        if (T == s.T) return s.spelling;
    }
    return switch (@typeInfo(T)) {
        .optional => |o| pyParamType(o.child, specials),
        .pointer => |p| blk: {
            if (p.child == u8 or p.child == anyopaque) break :blk "P";
            switch (@typeInfo(p.child)) {
                .optional => break :blk if (p.size == .one) "ctypes.POINTER(P)" else "P",
                .int => break :blk if (p.size == .one) switch (p.child) {
                    u16 => "u16_p",
                    u32 => "u32_p",
                    u64 => "u64_p",
                    usize => "size_p",
                    else => @compileError("unmapped scalar pointer width"),
                } else "P",
                .@"struct" => break :blk "ctypes.POINTER(" ++ mirrorName(p.child) ++ ")",
                .@"opaque" => break :blk "P",
                else => @compileError("unmapped pointer child type"),
            }
        },
        .int => switch (T) {
            i32 => "i32",
            u16 => "u16",
            u32 => "u32",
            u64 => "u64",
            usize => "size",
            else => @compileError("unmapped integer parameter width"),
        },
        else => @compileError("unmapped parameter type"),
    };
}

/// The ctypes restype spelling (`None` for void).
fn pyReturnType(comptime T: type) []const u8 {
    return switch (T) {
        i32 => "i32",
        usize => "size",
        void => "None",
        else => @compileError("unmapped result type"),
    };
}

/// Whether `token` appears in `hay` as a whole identifier (not as a substring
/// of a longer one), so the alias prelude carries exactly the names the rows
/// spell.
fn containsToken(hay: []const u8, token: []const u8) bool {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, hay, search, token)) |at| {
        search = at + 1;
        if (at > 0 and isIdent(hay[at - 1])) continue;
        const after = at + token.len;
        if (after < hay.len and isIdent(hay[after])) continue;
        return true;
    }
    return false;
}

fn isIdent(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
}

/// One local alias a generated function may open with. `also`: a derived
/// alias whose definition reads through this one, so its use marks this one
/// used too.
const Alias = struct {
    name: []const u8,
    def: []const u8,
    also: ?[]const u8 = null,
};

const aliases = [_]Alias{
    .{ .name = "P", .def = "P = ctypes.c_void_p" },
    .{ .name = "size", .def = "size = ctypes.c_size_t", .also = "size_p" },
    .{ .name = "u16", .def = "u16 = ctypes.c_uint16", .also = "u16_p" },
    .{ .name = "u32", .def = "u32 = ctypes.c_uint32", .also = "u32_p" },
    .{ .name = "u64", .def = "u64 = ctypes.c_uint64", .also = "u64_p" },
    .{ .name = "i32", .def = "i32 = ctypes.c_int32" },
    .{ .name = "size_p", .def = "size_p = ctypes.POINTER(size)" },
    .{ .name = "u16_p", .def = "u16_p = ctypes.POINTER(u16)" },
    .{ .name = "u32_p", .def = "u32_p = ctypes.POINTER(u32)" },
    .{ .name = "u64_p", .def = "u64_p = ctypes.POINTER(u64)" },
};

/// Render one archive's sigs function: the def line taking the hand-mirrored
/// types, a one-line docstring, the used-alias prelude, and the dict in the
/// inventory's order. `params` is checked two ways against the rendered rows:
/// every declared type is used and every used `_X` token is declared.
fn renderArchive(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime M: type,
    comptime fn_name: []const u8,
    comptime params: []const []const u8,
    comptime doc: []const u8,
    comptime specials: []const Special,
) !void {
    var rows: std.ArrayList(u8) = .empty;
    defer rows.deinit(gpa);
    inline for (M.symbols.symbols) |row| {
        if (row.python_omit == null) {
            const info = @typeInfo(@TypeOf(@field(M, row.name))).@"fn";
            try rows.print(gpa, "        \"{s}\": ([", .{row.name});
            inline for (info.params, 0..) |p, i| {
                if (i != 0) try rows.appendSlice(gpa, ", ");
                try rows.appendSlice(gpa, comptime pyParamType(p.type.?, specials));
            }
            try rows.print(gpa, "], {s}),\n", .{comptime pyReturnType(info.return_type.?)});
        }
    }

    // Two-way check between the declared type parameters and the rows.
    inline for (params) |param| {
        if (!containsToken(rows.items, param)) return error.UnusedSigTypeParam;
    }
    var scan: usize = 0;
    while (std.mem.indexOfScalarPos(u8, rows.items, scan, '_')) |at| {
        scan = at + 1;
        if (at > 0 and isIdent(rows.items[at - 1])) continue;
        if (at + 1 >= rows.items.len) continue;
        const first = rows.items[at + 1];
        if (first < 'A' or first > 'Z') continue;
        var end = at + 1;
        while (end < rows.items.len and isIdent(rows.items[end])) end += 1;
        const token = rows.items[at..end];
        const declared = inline for (params) |param| {
            if (std.mem.eql(u8, token, param)) break true;
        } else false;
        if (!declared) return error.UndeclaredSigTypeParam;
    }

    // The def line, wrapped one-per-line past 100 columns.
    var def_width: usize = 4 + fn_name.len + 2 + 1;
    inline for (params, 0..) |param, i| {
        if (i != 0) def_width += 2;
        def_width += param.len;
    }
    if (def_width <= 100) {
        try out.print(gpa, "def {s}(", .{fn_name});
        inline for (params, 0..) |param, i| {
            if (i != 0) try out.appendSlice(gpa, ", ");
            try out.appendSlice(gpa, param);
        }
        try out.appendSlice(gpa, "):\n");
    } else {
        try out.print(gpa, "def {s}(\n", .{fn_name});
        inline for (params) |param| {
            try out.print(gpa, "    {s},\n", .{param});
        }
        try out.appendSlice(gpa, "):\n");
    }
    try out.print(gpa, "    \"\"\"{s}\"\"\"\n", .{doc});
    for (aliases) |alias| {
        const used = containsToken(rows.items, alias.name) or
            (alias.also != null and containsToken(rows.items, alias.also.?));
        if (used) try out.print(gpa, "    {s}\n", .{alias.def});
    }
    try out.appendSlice(gpa, "    return {\n");
    try out.appendSlice(gpa, rows.items);
    try out.appendSlice(gpa, "    }\n");
}

fn generate(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\# GENERATED by `zig build gen-binding-python-ffi` (the annotated symbol
        \\# inventory in each archive's symbols.zig and each export's reflected
        \\# signature) -- do not edit. `zig build gen-binding-python-ffi-check`
        \\# (part of `check`) fails when this is stale.
        \\"""Internal: the generated ``ctypes`` signature tables, one function per
        \\archive.
        \\
        \\Each function takes the hand-mirrored ``Structure`` and callback types its
        \\archive's signatures name and returns the ``{symbol: (argtypes, restype)}``
        \\dict its ``_ffi_*`` loader binds. Passing the types in keeps this module
        \\import-free below ``ctypes``, so no import cycle forms with the hand
        \\modules that own the mirrors.
        \\"""
        \\
        \\from __future__ import annotations
        \\
        \\import ctypes
        \\
        \\
        \\
    );
    try renderArchive(gpa, &out, c, "ocapn_sigs", &.{ "_Allocator", "_ManagedFrame" }, "``libpancake_ocapn`` signatures, in the inventory's order.", &.{});
    try out.appendSlice(gpa, "\n\n");
    try renderArchive(gpa, &out, cd, "driver_sigs", &.{
        "_Argument",     "_Reference",       "_ManagedFrame",  "_LastAbort",
        "_DialPlan",     "_AcceptPlan",      "_PendingDial",   "_HostPumpHooks",
        "_HostBehavior", "_PartnerIdentity", "_TraceCallback",
    }, "``libpancake_host`` signatures, in the inventory's order.", &.{
        .{ .T = cd.PancakeHostBehavior, .spelling = "_HostBehavior" },
        .{ .T = cd.PancakeHostCtxFree, .spelling = "P" },
        .{ .T = cd.PancakeTraceCallback, .spelling = "_TraceCallback" },
    });
    try out.appendSlice(gpa, "\n\n");
    try renderArchive(gpa, &out, ct, "tcp_sigs", &.{ "_Frame", "_ManagedFrame" }, "``libpancake_net_transport_tcp`` signatures, in the inventory's order.", &.{});
    try out.appendSlice(gpa, "\n\n");
    try renderArchive(gpa, &out, cin, "inproc_sigs", &.{ "_Frame", "_ManagedFrame" }, "``libpancake_net_transport_inproc`` signatures, in the inventory's order.", &.{});
    try out.appendSlice(gpa, "\n\n");
    try renderArchive(gpa, &out, ci, "iroh_sigs", &.{ "_IrohReadyEvent", "_IrohConfig" }, "``libpancake_net_transport_iroh`` signatures, in the inventory's order.", &.{});
    try out.appendSlice(gpa, "\n\n");
    try renderArchive(gpa, &out, cw, "webrtc_sigs", &.{ "_WebrtcReadyEvent", "_WebrtcConfig" }, "``libpancake_net_transport_webrtc`` signatures, in the inventory's order.", &.{});
    return out.toOwnedSlice(gpa);
}
