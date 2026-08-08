//! The shared C-header emitter behind the `header_gen*` generators.
//!
//! Every generator reflects one `c_abi` module into a byte-exact C header:
//! constants become `#define`s, extern structs become typedefs, and exports
//! become prototypes, all spelled from the real Zig types so the header cannot
//! disagree with the implementation. The reflection machinery is identical
//! across them; only the module, the function table, the curated prose, and
//! (for `libpancake_ocapn`) the three function-pointer typedefs differ. Those
//! differences are a `Spec` type each generator supplies to `Emit`.
//!
//! A `Spec` provides `c` (the reflected module), `emitted_fns` (the prototype
//! table), and optionally `const_docs` (curated `#define` comments) and
//! `special` (a hook mapping a Zig type to a C typedef name the base spelling
//! does not know). The `gen-header-*-check` gates verify the emitted bytes,
//! so a drift in this module fails loudly at the header it breaks.

const std = @import("std");

pub const Buf = std.ArrayList(u8);

pub fn line(b: *Buf, gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    try b.print(gpa, fmt ++ "\n", args);
}

/// Wrap curated prose in a `/* ... */` block comment. An empty interior line
/// separates paragraphs and is emitted bare so the header carries no trailing
/// whitespace.
pub fn emitDoc(b: *Buf, gpa: std.mem.Allocator, comptime doc: []const u8) !void {
    const lines = comptime blk: {
        @setEvalBranchQuota(8000);
        var ls: []const []const u8 = &.{};
        var it = std.mem.splitScalar(u8, doc, '\n');
        while (it.next()) |l| ls = ls ++ .{l};
        break :blk ls;
    };
    inline for (lines, 0..) |l, i| {
        const prefix = if (i == 0) "/* " else if (l.len == 0) "" else "   ";
        const suffix = if (i == lines.len - 1) " */" else "";
        try line(b, gpa, "{s}{s}{s}", .{ prefix, l, suffix });
    }
}

pub fn section(b: *Buf, gpa: std.mem.Allocator, comptime title: []const u8) !void {
    try b.appendSlice(gpa, "\n");
    try line(b, gpa, "/* ── {s} ── */", .{title});
}

/// `c_abi.PancakeFrame` → `PancakeFrame` (strip the module path).
const baseName = @import("reflect").baseName;

/// The reflection primitives, bound to one generator's `Spec`. `Spec` supplies
/// `c` and `emitted_fns` always, and `const_docs` / `special` when it needs
/// them; the primitives that read those check for the declaration first.
pub fn Emit(comptime Spec: type) type {
    return struct {
        const c = Spec.c;
        const emitted_fns = Spec.emitted_fns;

        /// Map a Zig type to its C spelling. Reflection-driven, so a field or
        /// parameter type change in the module flows into the header. `Spec.special`
        /// gets first refusal (it names the function-pointer typedefs the base
        /// spelling has no case for); everything else is the shared table.
        pub fn cType(comptime T: type) []const u8 {
            if (@hasDecl(Spec, "special")) {
                if (Spec.special(T)) |s| return s;
            }
            return switch (T) {
                u8 => "uint8_t",
                u16 => "uint16_t",
                u32 => "uint32_t",
                u64 => "uint64_t",
                i32 => "int32_t",
                i64 => "int64_t",
                usize => "size_t",
                isize => "intptr_t",
                f64 => "double",
                void => "void",
                anyopaque => "void",
                else => switch (@typeInfo(T)) {
                    .optional => |o| cType(o.child), // nullable in C is the same spelling
                    .pointer => |p| blk: {
                        const child = cType(p.child);
                        if (child.len > 0 and child[child.len - 1] == '*') break :blk child ++ "*";
                        const prefix = if (p.is_const) "const " else "";
                        break :blk prefix ++ child ++ " *";
                    },
                    .@"struct", .@"opaque" => baseName(T),
                    // A C array's length is part of the DECLARATOR, not the type
                    // name, so this half spells the element and `arraySuffix`
                    // spells the `[N]` that has to sit after the field name.
                    .array => |a| cType(a.child),
                    else => @compileError("no C mapping for " ++ @typeName(T)),
                },
            };
        }

        /// The `[N]` a fixed-array field carries after its name in C, or the
        /// empty string for every other field. C splits an array declaration
        /// across the type and the name, so this is the half `cType` cannot
        /// return.
        fn arraySuffix(comptime FieldT: type) []const u8 {
            return switch (@typeInfo(FieldT)) {
                .array => |a| std.fmt.comptimePrint("[{d}]", .{a.len}),
                else => "",
            };
        }

        /// A pointer-to-self field must spell `const struct Name *` in C: the
        /// typedef is not complete yet at that point.
        fn selfRef(comptime Owner: type, comptime FieldT: type, comptime name: []const u8) []const u8 {
            if (@typeInfo(FieldT) == .optional) {
                const child = @typeInfo(FieldT).optional.child;
                if (@typeInfo(child) == .pointer and @typeInfo(child).pointer.child == Owner) {
                    const prefix = if (@typeInfo(child).pointer.is_const) "const " else "";
                    return prefix ++ "struct " ++ name ++ " *";
                }
            }
            return cType(FieldT);
        }

        /// Coverage guard, both directions: every `pub fn <prefix>*` in the module
        /// must be in `emitted_fns`, and every table entry must name a real
        /// function. Call from a top-level `comptime` block. `module_name` names
        /// the module in the failure text.
        pub fn guardFns(comptime module_name: []const u8, comptime prefix: []const u8) void {
            @setEvalBranchQuota(40000);
            for (@typeInfo(c).@"struct".decls) |decl| {
                if (!std.mem.startsWith(u8, decl.name, prefix)) continue;
                if (@typeInfo(@TypeOf(@field(c, decl.name))) != .@"fn") continue;
                var found = false;
                for (emitted_fns) |name| {
                    if (std.mem.eql(u8, name, decl.name)) found = true;
                }
                if (!found) @compileError("function in " ++ module_name ++ " but not emitted: " ++ decl.name);
            }
            for (emitted_fns) |name| {
                if (!@hasDecl(c, name)) @compileError("emitted_fns lists '" ++ name ++ "' but " ++ module_name ++ " has no such declaration");
                if (@typeInfo(@TypeOf(@field(c, name))) != .@"fn") @compileError("emitted_fns entry '" ++ name ++ "' is not a " ++ module_name ++ " function");
            }
        }

        /// Emit `#define NAME <value>` with the value reflected from the module.
        /// Values are plain decimal literals (C type `int`): every constant is a
        /// small discriminant callers compare against both `int32_t` returns and
        /// `uint32_t` struct fields, and a `u` suffix would force a cast or a
        /// sign-compare warning on the signed side. A negative code expands
        /// parenthesized, `(-1)` not `-1`, so `x-PANCAKE_ERR_IO` written without
        /// spaces cannot lex as a decrement. A name in `Spec.const_docs` gets its
        /// one curated comment line first.
        pub fn emitConst(b: *Buf, gpa: std.mem.Allocator, comptime name: []const u8) !void {
            if (@hasDecl(Spec, "const_docs")) {
                inline for (Spec.const_docs) |entry| {
                    if (comptime std.mem.eql(u8, entry.name, name)) {
                        try line(b, gpa, "/* {s} */", .{entry.doc});
                    }
                }
            }
            const value = @field(c, name);
            const negative = comptime blk: {
                const T = @TypeOf(value);
                if (@typeInfo(T) != .int) break :blk false;
                if (@typeInfo(T).int.signedness != .signed) break :blk false;
                break :blk value < 0;
            };
            if (negative) {
                try line(b, gpa, "#define {s} ({d})", .{ name, value });
            } else {
                try line(b, gpa, "#define {s} {d}", .{ name, value });
            }
        }

        /// Emit a struct typedef, fields reflected from the real type. `docs`
        /// gives an optional `/* ... */` line per field (field order; "" to skip).
        pub fn emitStruct(
            b: *Buf,
            gpa: std.mem.Allocator,
            comptime T: type,
            comptime name: []const u8,
            comptime docs: []const []const u8,
        ) !void {
            try emitStructBody(b, gpa, T, name, docs, true);
        }

        /// `emitStruct` without the typedef wrapper, for a struct whose typedef was
        /// already forward-declared (a second `typedef struct X X;` would redeclare it).
        pub fn emitBareStruct(
            b: *Buf,
            gpa: std.mem.Allocator,
            comptime T: type,
            comptime name: []const u8,
            comptime docs: []const []const u8,
        ) !void {
            try emitStructBody(b, gpa, T, name, docs, false);
        }

        fn emitStructBody(
            b: *Buf,
            gpa: std.mem.Allocator,
            comptime T: type,
            comptime name: []const u8,
            comptime docs: []const []const u8,
            comptime use_typedef: bool,
        ) !void {
            const fields = @typeInfo(T).@"struct".fields;
            if (docs.len != fields.len) @compileError("field doc count mismatch for " ++ name);
            if (use_typedef) {
                try line(b, gpa, "typedef struct {s} {{", .{name});
            } else {
                try line(b, gpa, "struct {s} {{", .{name});
            }
            inline for (fields, docs) |f, doc| {
                if (doc.len != 0) try line(b, gpa, "    /* {s} */", .{doc});
                const ty = comptime selfRef(T, f.type, name);
                const space = if (ty.len > 0 and ty[ty.len - 1] == '*') "" else " ";
                const suffix = comptime arraySuffix(f.type);
                try line(b, gpa, "    {s}{s}{s}{s};", .{ ty, space, f.name, suffix });
            }
            if (use_typedef) {
                try line(b, gpa, "}} {s};", .{name});
            } else {
                try b.appendSlice(gpa, "};\n");
            }
        }

        /// Emit a function prototype: return and parameter types reflected from the
        /// real export; `param_names` and `doc` curated by the caller. A parameter
        /// added in the module without a name here, a name missing from
        /// `emitted_fns`, or an empty doc is a compile error.
        pub fn emitFn(
            b: *Buf,
            gpa: std.mem.Allocator,
            comptime fn_name: []const u8,
            comptime param_names: []const []const u8,
            comptime doc: []const u8,
        ) !void {
            comptime {
                @setEvalBranchQuota(1_000_000);
                var listed = false;
                for (emitted_fns) |name| {
                    if (std.mem.eql(u8, name, fn_name)) listed = true;
                }
                if (!listed) @compileError("emitFn called for '" ++ fn_name ++ "' which is missing from emitted_fns");
                // The header is the C consumer's only surface, so a bare prototype
                // is an undocumented function no matter what the Zig source says.
                if (doc.len == 0) @compileError("prototype '" ++ fn_name ++ "' has no header doc; write the contract here");
                // The doc lands inside a block comment: prose that itself spells
                // `/*` or `*/` (an out-pointer pair like `*out_a/*out_b`) breaks
                // or nests the comment, a warning -Werror consumers fail on —
                // possibly much later, when a header change first invalidates
                // their compile cache. Space the slash: `*out_a / *out_b`.
                if (std.mem.indexOf(u8, doc, "/*") != null or std.mem.indexOf(u8, doc, "*/") != null)
                    @compileError("prototype '" ++ fn_name ++ "' doc contains /* or */, which breaks the emitted block comment");
            }
            const info = @typeInfo(@TypeOf(@field(c, fn_name))).@"fn";
            if (info.params.len != param_names.len) @compileError("param name count mismatch for " ++ fn_name);
            try emitDoc(b, gpa, doc);

            try b.print(gpa, "{s} {s}(", .{ comptime cType(info.return_type.?), fn_name });
            // A zero-parameter C prototype must spell `(void)`: a bare `()` is a
            // K&R-style unchecked parameter list, not "no parameters".
            if (info.params.len == 0) try b.appendSlice(gpa, "void");
            inline for (info.params, param_names, 0..) |p, pname, i| {
                const ty = comptime cType(p.type.?);
                const sep = if (i == 0) "" else ", ";
                const space = if (ty.len > 0 and ty[ty.len - 1] == '*') "" else " ";
                try b.print(gpa, "{s}{s}{s}{s}", .{ sep, ty, space, pname });
            }
            try b.appendSlice(gpa, ");\n");
        }

        /// After building, assert every `emitted_fns` entry landed as a prototype
        /// in the output text, so the table and the body cannot drift apart.
        pub fn assertAllEmitted(b: *Buf, comptime step: []const u8) !void {
            inline for (emitted_fns) |name| {
                if (std.mem.indexOf(u8, b.items, " " ++ name ++ "(") == null) {
                    std.debug.print(step ++ ": emitted_fns lists `{s}` but no emitFn call emitted it\n", .{name});
                    return error.MissingEmittedFunction;
                }
            }
        }
    };
}
