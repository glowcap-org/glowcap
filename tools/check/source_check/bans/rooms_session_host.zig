//! The durable Rooms session actor is host-agnostic. Deno belongs to the
//! process host (`main.ts`) and the file document adapter, not the actor.

const bans = @import("../bans.zig");
const Ban = bans.Ban;

pub const rows: []const Ban = &.{
    .{
        .where = .{ .tree = .{
            .dir = "apps/rooms/session",
            .suffixes = &.{".ts"},
            .exclude = &.{
                "apps/rooms/session/main.ts",
                "apps/rooms/session/file_documents.ts",
            },
        } },
        .kind = .forbid,
        .needles = &.{ "Deno.", "from \"../lib/durable_file", "from \"./file_documents" },
        .check = "rooms-session-host",
        .why = "the Rooms session actor takes a document store and a running Host; Deno filesystem and process APIs stay in main.ts and file_documents.ts",
    },
};
