//! Ban rows: Zig forms the pinned toolchain still compiles and has marked for
//! removal. Each row names the form that replaces it.
//!
//! The rows restate the `Deprecated` doc comments in the pinned compiler's
//! `lib/std` and its language reference. `surveyed_zig_version` records which
//! compiler they were read from, and `project_shape/zig_version.zig` holds it
//! to the pin, so a toolchain bump rereads both before it lands.
//!
//! A row matches text, so it reaches comments and strings too. It does not
//! reach a default-initialized std hash map (`= .{}` where `.empty` belongs),
//! which only a std with those field defaults removed refuses.

const bans = @import("../bans.zig");
const Ban = bans.Ban;

/// The compiler whose deprecation markers these rows restate.
pub const surveyed_zig_version = "0.17.1";

const Form = struct {
    needles: []const []const u8,
    why: []const u8,
};

const this_file = "tools/check/source_check/bans/zig_deprecations.zig";

/// Forms any Zig file can hold.
const language_and_std = [_]Form{
    .{
        .needles = &.{ "@intFromEnum(", "@enumFromInt(", "@intFromFloat(" },
        .why = "deprecated builtin: use `@backingInt`, `@fromBackingInt`, and `@trunc`, `@floor`, `@ceil`, or `@round` with an integer result type",
    },
    .{
        .needles = &.{ "mem.indexOf", "mem.lastIndexOf" },
        .why = "deprecated: use the `std.mem.find` family (`find`, `findPos`, `findLast`, `findScalar`, `findScalarLast`, `findAny`, `findNone`)",
    },
    .{
        .needles = &.{ "mem.copyForwards", "mem.copyBackwards" },
        .why = "deprecated: use `@memmove(dest, source)` with operands of equal length",
    },
    .{
        .needles = &.{ "fmt.bufPrint", "fmt.allocPrint" },
        .why = "deprecated: use `std.mem.print(buffer, ...)` and the allocator's own `gpa.print(...)`, with `printSentinel` beside each",
    },
    .{
        .needles = &.{ "std.builtin", "OptimizeMode", ".ReleaseSafe", ".ReleaseFast", ".ReleaseSmall", ".Debug" },
        .why = "deprecated: `std.builtin` is `std.lang`, and `std.lang.Optimize` has the fields `.debug`, `.safe`, `.fast`, and `.small`",
    },
    .{
        .needles = &.{
            "builtin.os.",    "builtin.cpu.",    "builtin.abi",    "builtin.object_format",    "builtin.mode",
            "builtin\").os.", "builtin\").cpu.", "builtin\").abi", "builtin\").object_format", "builtin\").mode",
        },
        .why = "deprecated: read `builtin.target.os`, `.target.cpu`, `.target.abi`, `.target.ofmt`, and `builtin.optimize`",
    },
    .{
        .needles = &.{"debug.runtime_safety"},
        .why = "deprecated: use `@import(\"builtin\").optimize.runtimeSafety()`, which answers for the calling module, and read a std type's own `@sizeOf` where its layout is the question",
    },
    .{
        .needles = &.{ "std.fs.path", "std.fs.max_path_bytes", "std.fs.max_name_bytes" },
        .why = "deprecated: use `std.Io.Dir.path`, `std.Io.Dir.max_path_bytes`, and `std.Io.Dir.max_name_bytes`",
    },
    .{
        .needles = &.{ "ArrayListUnmanaged", "ArrayListAligned", "ArrayHashMapUnmanaged", "StaticBitSet", "IntegerBitSet", "ArrayBitSet", "DynamicBitSet" },
        .why = "deprecated alias: use `std.ArrayList`, `std.array_list.Aligned`, `std.array_hash_map.Auto`, `String`, or `Custom`, and `std.bit_set.Static`, `Integer`, `Array`, or `Dynamic`",
    },
    .{
        .needles = &.{ "DebugAllocator", "GeneralPurposeAllocator" },
        .why = "deprecated: use `std.heap.SafeAllocator`, whose `deinit` returns the leak count",
    },
    .{
        .needles = &.{ "meta.fieldInfo(", "meta.fieldNames(", "meta.fieldTypes(" },
        .why = "deprecated: read `field_names`, `field_types`, and `field_attrs` from `@typeInfo`",
    },
    .{
        .needles = &.{ "unicode.utf8Decode(", "unicode.wtf8Decode(" },
        .why = "deprecated: validate with `utf8ValidateSlice`, or decode a known width with `utf8Decode2`, `utf8Decode3`, or `utf8Decode4`",
    },
    .{
        .needles = &.{ ".getLast(", ".getLastOrNull(" },
        .why = "deprecated: use `ArrayList.last()`, which returns an optional",
    },
};

/// Forms only a build script can hold.
const build_api = [_]Form{
    .{
        .needles = &.{ ".lazyDependency(", ".runAllowFail(", ".cwd_relative", "b.dupe(", "b.dupeStrings(", "b.dupePath(", ".enableTestRunnerMode(" },
        .why = "deprecated build API: use `dependencyLazy`, `runFallible`, `enableProtocolMode`, and the graph's own `b.graph.cwdRelativePath`, `b.graph.dupeString`, `b.graph.dupeStrings`, and `b.graph.dupePath`",
    },
    .{
        .needles = &.{
            ".addArtifactArg(",              ".addPrefixedArtifactArg(",    ".addOutputFileArg(",         ".addPrefixedOutputFileArg(",
            ".addFileContentArg(",           ".addPrefixedFileContentArg(", ".addOutputDirectoryArg(",    ".addPrefixedOutputDirectoryArg(",
            ".addDirectoryArg(",             ".addPrefixedDirectoryArg(",   ".addDecoratedDirectoryArg(", ".addDepFileOutputArg(",
            ".addPrefixedDepFileOutputArg(",
        },
        .why = "deprecated build API: use the `Arg2` form, which takes `.{ .prefix = ..., .suffix = ... }`",
    },
};

const zig_dirs = [_][]const u8{
    "src",  "cli",     "test",     "tools",       "examples", "bench",
    "apps", "interop", "bindings", "conformance", "site",
};
const build_dirs = [_][]const u8{ "tools/build", "tools/check", "tools/consumer", "site" };
const root_build_files: []const []const u8 = &.{"build.zig"};

pub const rows: []const Ban = blk: {
    const all_forms = language_and_std ++ build_api;
    var out: [language_and_std.len * (zig_dirs.len + 1) + build_api.len * (build_dirs.len + 1)]Ban = undefined;
    var n: usize = 0;
    for (all_forms, 0..) |form, i| {
        const dirs: []const []const u8 = if (i < language_and_std.len) &zig_dirs else &build_dirs;
        for (dirs) |dir| {
            out[n] = .{
                .where = .{ .tree = .{ .dir = dir, .suffixes = &.{".zig"}, .exclude = &.{this_file} } },
                .kind = .forbid,
                .needles = form.needles,
                .check = "zig-deprecations",
                .why = form.why,
            };
            n += 1;
        }
        out[n] = .{
            .where = .{ .files = root_build_files },
            .kind = .forbid,
            .needles = form.needles,
            .check = "zig-deprecations",
            .why = form.why,
        };
        n += 1;
    }
    const final = out;
    break :blk &final;
};
