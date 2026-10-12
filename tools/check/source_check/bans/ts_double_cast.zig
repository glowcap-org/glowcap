//! TypeScript double-cast ban for the two reviewed lanes.

const bans = @import("../bans.zig");
const Ban = bans.Ban;

/// `as unknown as` widens through `unknown` to defeat the type system between
/// two unrelated types. In `bindings/ts` and `apps/rooms` a value like that is
/// a defect: the seam gets a real type (`Timer`, an ambient `Navigator.gpu`),
/// the readers narrow, or the foreign boundary names itself in a comment. The
/// two boundary files and the dogfood and test trees keep their legitimate
/// uses. Other app trees keep their own bars.
pub const rows: []const Ban = &.{
    .{
        .where = .{ .tree = .{
            .dir = "bindings/ts",
            .suffixes = &.{".ts"},
            .skip_dirs = &.{ "node_modules/", "dogfood/", "test/" },
            .exclude = &.{
                "bindings/ts/web/mod.ts",
                "bindings/ts/runtime/internal/ffi/load.ts",
            },
        } },
        .kind = .forbid,
        .needles = &.{"as unknown as"},
        .check = "ts-double-cast",
        .why = "a double cast hides a real type, so seams are typed, narrowed, or named at their boundary instead",
    },
    .{
        .where = .{ .tree = .{
            .dir = "apps/rooms",
            .suffixes = &.{ ".ts", ".tsx" },
            .skip_dirs = &.{ "node_modules/", "test/" },
        } },
        .kind = .forbid,
        .needles = &.{"as unknown as"},
        .check = "ts-double-cast",
        .why = "a double cast hides a real type, so seams are typed, narrowed, or named at their boundary instead",
    },
};
