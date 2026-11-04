//! Shared Rust support selected from the methods being emitted.
const std = @import("std");
const Kind = @import("calls.zig").Kind;

pub const Needs = struct {
    ordinary: bool = false,
    receipt: bool = false,
    arguments: bool = false,
    references: bool = false,
    optional: bool = false,
    replies: std.EnumSet(Kind) = .{},

    pub fn emit(self: Needs, out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
        const pending = self.receipt or self.replies.count() != 0;
        const imports = .{
            .{ "Argument", self.arguments or self.references or self.optional or pending },
            .{ "AsSendTarget", self.ordinary },
            .{ "Ref", self.references or self.receipt or self.replies.contains(.target) },
            .{ "RemotePromise", self.references or pending },
            .{ "Session", self.ordinary or self.receipt },
        };
        inline for (imports) |item| if (item[1]) {
            try out.print(a, "use glowcap::{s};\n", .{item[0]});
        };
        try out.appendSlice(a, @embedFile("templates/support.rs"));
        if (pending) try out.appendSlice(a, @embedFile("templates/pending.rs"));
        if (self.references) try out.appendSlice(a, @embedFile("templates/references.rs"));
        if (self.optional) try out.appendSlice(a, @embedFile("templates/optional.rs"));
        if (self.receipt) try out.appendSlice(a, @embedFile("templates/receipt.rs"));
        for ([_]Kind{ .target, .text, .nothing, .integer }) |kind| if (self.replies.contains(kind)) {
            try out.appendSlice(a, switch (kind) {
                .target => "fn capability(value: Argument) -> Result<Ref, Error> {\n" ++
                    "\tRef::try_from(&value).map_err(|_| Error::InvalidReply)\n}\n",
                .text => "fn text(value: Argument) -> Result<String, Error> {\n" ++
                    "\tif let Argument::String(text) = value {\n\t\tOk(text)\n" ++
                    "\t} else {\n\t\tErr(Error::InvalidReply)\n\t}\n}\n",
                .integer => "fn integer(value: Argument) -> Result<i64, Error> {\n" ++
                    "\tvalue.as_i64().ok_or(Error::InvalidReply)\n}\n",
                .nothing => "fn nothing(value: Argument) -> Result<(), Error> {\n" ++
                    "\tif matches!(value, Argument::Void) {\n\t\tOk(())\n" ++
                    "\t} else {\n\t\tErr(Error::InvalidReply)\n\t}\n}\n",
                else => unreachable,
            });
        };
    }
};
