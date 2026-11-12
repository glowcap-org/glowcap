//! Reflected identity for one separately loaded C archive's callable and data
//! contract. Bindings compare the value before their first ordinary call, so a
//! stale companion refuses at load time instead of crossing an incompatible
//! signature or struct layout.

const std = @import("std");
const ReleaseResult = @import("release_result.zig").ReleaseResult;

const offset_basis: u64 = 14695981039346656037;
const prime: u64 = 1099511628211;

/// One public C struct in the canonical contract manifest. The same manifest
/// drives binding layout generation and archive fingerprints.
pub const Layout = struct {
    stem: []const u8,
    Type: type,
    /// Whether a language binding hand-mirrors this struct and therefore needs
    /// generated size/offset pins. Every layout remains part of the archive
    /// fingerprint. This only controls the binding projection.
    binding_mirror: bool,
};

pub fn layout(comptime stem: []const u8, comptime T: type) Layout {
    return .{ .stem = stem, .Type = T, .binding_mirror = true };
}

/// A public C layout consumed through an opaque/package seam by the language
/// bindings. It remains fingerprinted, but must not reappear as a binding API.
pub fn cOnlyLayout(comptime stem: []const u8, comptime T: type) Layout {
    return .{ .stem = stem, .Type = T, .binding_mirror = false };
}

fn mixByte(hash: *u64, byte: u8) void {
    hash.* ^= byte;
    hash.* *%= prime;
}

fn finishPart(hash: *u64) void {
    // Preserve field and record boundaries: ["ab", "c"] must not name the
    // same contract as ["a", "bc"].
    mixByte(hash, 0xff);
}

fn mix(hash: *u64, bytes: []const u8) void {
    for (bytes) |byte| mixByte(hash, byte);
    finishPart(hash);
}

fn mixInt(hash: *u64, value: u64) void {
    var shift: u7 = 0;
    while (shift < 64) : (shift += 8)
        mixByte(hash, @truncate(value >> @as(u6, @intCast(shift))));
    finishPart(hash);
}

fn mixIndexes(hash: *u64, indexes: []const u8) void {
    mixInt(hash, indexes.len);
    for (indexes) |index| mixInt(hash, index);
}

fn isContractConstant(comptime name: []const u8) bool {
    return std.mem.startsWith(u8, name, "GLOWCAP_") and
        !std.mem.endsWith(u8, name, "_ARCHIVE_FINGERPRINT");
}

fn contractConstantCount(comptime Archive: type) usize {
    var count: usize = 0;
    inline for (comptime std.meta.declarations(Archive)) |name| {
        if (comptime isContractConstant(name)) count += 1;
    }
    return count;
}

fn sortedContractConstantNames(
    comptime Archive: type,
) [contractConstantCount(Archive)][]const u8 {
    comptime var names: [contractConstantCount(Archive)][]const u8 = undefined;
    comptime var count: usize = 0;
    inline for (comptime std.meta.declarations(Archive)) |name| {
        if (comptime !isContractConstant(name)) continue;
        names[count] = name;
        count += 1;
    }
    // Declaration order is not an ABI fact. Canonicalize it before mixing.
    if (names.len > 1) {
        for (1..names.len) |index| {
            var at = index;
            while (at > 0 and std.mem.order(u8, names[at], names[at - 1]) == .lt) : (at -= 1) {
                const prior = names[at - 1];
                names[at - 1] = names[at];
                names[at] = prior;
            }
        }
    }
    return names;
}

fn mixConstantValue(hash: *u64, comptime name: []const u8, comptime value: anytype) void {
    const T = @TypeOf(value);
    mix(hash, name);
    mix(hash, unqualified(@typeName(T)));
    switch (@typeInfo(T)) {
        .int, .comptime_int => mix(hash, std.fmt.comptimePrint("{d}", .{value})),
        .bool => mixInt(hash, @intFromBool(value)),
        .@"enum" => {
            mix(hash, @tagName(value));
            mix(hash, std.fmt.comptimePrint("{d}", .{@backingInt(value)}));
        },
        .array => |array| {
            if (array.child != u8)
                @compileError(name ++ " is a GLOWCAP_* array constant with unsupported element type");
            mix(hash, &value);
        },
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                if (pointer.child != u8)
                    @compileError(name ++ " is a GLOWCAP_* slice constant with unsupported element type");
                mix(hash, value);
            },
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| {
                    if (array.child != u8)
                        @compileError(name ++ " is a GLOWCAP_* pointer constant with unsupported target type");
                    mix(hash, value[0..]);
                },
                else => @compileError(name ++ " is a GLOWCAP_* pointer constant with unsupported target type"),
            },
            else => @compileError(name ++ " is a GLOWCAP_* pointer constant with unsupported shape"),
        },
        else => @compileError(name ++ " is a public GLOWCAP_* declaration the archive fingerprint cannot represent"),
    }
}

fn mixConstants(hash: *u64, comptime Archive: type) void {
    inline for (sortedContractConstantNames(Archive)) |name| {
        mixConstantValue(hash, comptime name, comptime @field(Archive, name));
    }
}

fn mixLayout(hash: *u64, comptime entry: Layout) void {
    const T = entry.Type;
    const info = @typeInfo(T).@"struct";
    mix(hash, entry.stem);
    mix(hash, unqualified(@typeName(T)));
    mixInt(hash, info.field_names.len);
    // The declaration, never the resolved bytes: an extern struct's layout on
    // any one target is a pure function of its declared field types and their
    // order, and `usize` spells the same on every target while resolving to
    // different widths. Hashing `@sizeOf`/`@offsetOf` here made the same
    // checkout's wasm32 archive fail the value generated on the build host, so
    // no browser peer could open. Field names and symbolic type names move
    // for every real contract change; per-target resolved layout is the C
    // compiler's and each binding's generated layout table's to hold.
    inline for (info.field_names, info.field_types) |field_name, FieldT| {
        mix(hash, field_name);
        mix(hash, unqualified(@typeName(FieldT)));
    }
}

/// `name` with every module path cut to its last segment, so
/// `*c_abi.loam.layouts.Store` reads `*Store`: a C consumer observes a type's
/// name, never the Zig file that declares it, so moving a declaration between
/// files leaves the fingerprint alone. A path is a run of identifiers joined
/// by dots that starts with a letter or underscore. Digits, punctuation, and
/// spaces pass through, so `1.5` and `fn (*a.B) callconv(.c) u32` keep their
/// shape.
pub fn unqualified(comptime name: []const u8) []const u8 {
    comptime {
        var buf: [name.len]u8 = undefined;
        var len: usize = 0;
        var i: usize = 0;
        while (i < name.len) {
            if (!isIdentStart(name[i])) {
                buf[len] = name[i];
                len += 1;
                i += 1;
                continue;
            }
            var segment = i;
            while (i < name.len and (isIdentChar(name[i]) or (name[i] == '.' and i + 1 < name.len and isIdentStart(name[i + 1])))) : (i += 1) {
                if (name[i] == '.') segment = i + 1;
            }
            @memcpy(buf[len..][0 .. i - segment], name[segment..i]);
            len += i - segment;
        }
        const final = buf[0..len].*;
        return &final;
    }
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The first inventory fact an archive breaks, with the symbol it concerns.
/// An archive's `symbols.zig` has exactly one row per public `glowcap_*`
/// function, and every row names one.
pub const InventoryFault = struct {
    kind: Kind,
    name: []const u8,

    pub const Kind = enum { missing_row, duplicate_row, unknown_export, not_function };

    pub fn message(comptime self: InventoryFault, comptime archive_name: []const u8) []const u8 {
        return archive_name ++ " archive: `" ++ self.name ++ "` " ++ switch (self.kind) {
            .missing_row => "is an export with no row in its symbols.zig inventory",
            .duplicate_row => "has more than one row in its symbols.zig inventory",
            .unknown_export => "has an inventory row but no declaration",
            .not_function => "has an inventory row but is not a function declaration",
        };
    }
};

/// The first broken inventory fact of `Archive`, or null when its rows and
/// its public `glowcap_*` functions match one to one.
pub fn inventoryFault(comptime Archive: type) ?InventoryFault {
    comptime {
        @setEvalBranchQuota(10_000_000);
        const rows = Archive.symbols.symbols;
        for (rows, 0..) |row, i| {
            if (!@hasDecl(Archive, row.name)) return .{ .kind = .unknown_export, .name = row.name };
            if (@typeInfo(@TypeOf(@field(Archive, row.name))) != .@"fn") return .{ .kind = .not_function, .name = row.name };
            for (rows[0..i]) |prior| {
                if (std.mem.eql(u8, prior.name, row.name)) return .{ .kind = .duplicate_row, .name = row.name };
            }
        }
        for (@typeInfo(Archive).@"struct".decl_names) |name| {
            if (!std.mem.startsWith(u8, name, "glowcap_")) continue;
            if (@typeInfo(@TypeOf(@field(Archive, name))) != .@"fn") continue;
            const listed = for (rows) |row| {
                if (std.mem.eql(u8, row.name, name)) break true;
            } else false;
            if (!listed) return .{ .kind = .missing_row, .name = name };
        }
        return null;
    }
}

/// Fingerprint an archive from facts its C consumers can observe: every
/// exported symbol's reflected function type and crossing annotations, every
/// public `GLOWCAP_*` value, and every struct in its canonical layout
/// manifests. Implementation and comment edits do not perturb the value, and
/// neither does the Zig file a type is declared in. Binding-owned declaration
/// omissions are outside this C contract. An inventory that `inventoryFault`
/// refuses fails the archive's compile, so each archive checks its own rows.
pub fn fingerprint(
    comptime archive_name: []const u8,
    comptime Archive: type,
    comptime layout_groups: anytype,
) u64 {
    if (comptime inventoryFault(Archive)) |broken| @compileError(broken.message(archive_name));
    @setEvalBranchQuota(10_000_000);
    var hash = offset_basis;
    mix(&hash, "glowcap-c-archive-contract-v5");
    mix(&hash, archive_name);
    mixConstants(&hash, Archive);

    inline for (Archive.symbols.symbols) |symbol| {
        const Fn = @TypeOf(@field(Archive, symbol.name));
        mix(&hash, symbol.name);
        mix(&hash, unqualified(@typeName(Fn)));
        // Return types alone cannot identify ownership semantics. Bindings
        // must refuse an archive whose release word uses another encoding.
        if (comptime ReleaseResult.isFunction(symbol.name, Fn))
            mix(&hash, ReleaseResult.contract);
        mixIndexes(&hash, symbol.out_params);
        mixIndexes(&hash, symbol.pointer_params);
        mixInt(&hash, @intFromBool(symbol.nonblocking));
        mixInt(&hash, @intFromBool(symbol.blocking));
    }

    inline for (layout_groups) |layouts| {
        inline for (layouts) |entry| mixLayout(&hash, entry);
    }
    return hash;
}
