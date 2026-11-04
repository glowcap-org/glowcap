//! Shared Rust support selected from the methods being emitted.
//! Scalar reply decoders consume Argument and move its owned payload out.
//! They do not allocate or clone the binding snapshot.
const std = @import("std");
const Kind = @import("calls.zig").Kind;

pub const Needs = struct {
    ordinary: bool = false,
    receipt: bool = false,
    arguments: bool = false,
    references: bool = false,
    optional: bool = false,
    replies: std.EnumSet(Kind) = .{},

    pub fn exports(self: Needs) [5]@import("exports.zig").Support {
        const pending = self.receipt or self.replies.count() != 0;
        return .{
            .{ .name = "Error" },
            .{ .name = "Pending", .enabled = pending },
            .{ .name = "Observation", .enabled = pending },
            .{ .name = "Reference", .enabled = self.references },
            .{ .name = "PreparedMutation", .enabled = self.receipt },
        };
    }

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
        for ([_]Kind{ .target, .text, .nothing, .integer, .boolean, .bytes, .symbol, .float64, .error_value }) |kind| if (self.replies.contains(kind)) {
            try out.appendSlice(a, switch (kind) {
                .target => "fn capability(value: Argument) -> Result<Ref, Error> {\n" ++
                    "\tif let Argument::Reference(reference) = value {\n\t\tOk(reference)\n" ++
                    "\t} else {\n\t\tErr(Error::InvalidReply)\n\t}\n}\n",
                .text => "fn text(value: Argument) -> Result<String, Error> {\n" ++
                    "\tif let Argument::String(text) = value {\n\t\tOk(text)\n" ++
                    "\t} else {\n\t\tErr(Error::InvalidReply)\n\t}\n}\n",
                .integer => "fn integer(value: Argument) -> Result<i64, Error> {\n" ++
                    "\tvalue.as_i64().ok_or(Error::InvalidReply)\n}\n",
                .nothing => "fn nothing(value: Argument) -> Result<(), Error> {\n" ++
                    "\tif matches!(value, Argument::Void) {\n\t\tOk(())\n" ++
                    "\t} else {\n\t\tErr(Error::InvalidReply)\n\t}\n}\n",
                .boolean => "fn boolean(value: Argument) -> Result<bool, Error> {\n" ++
                    "\tif let Argument::Boolean(value) = value {\n\t\tOk(value)\n" ++
                    "\t} else {\n\t\tErr(Error::InvalidReply)\n\t}\n}\n",
                .bytes => "fn bytes(value: Argument) -> Result<Vec<u8>, Error> {\n" ++
                    "\tif let Argument::Bytes(value) = value {\n\t\tOk(value)\n" ++
                    "\t} else {\n\t\tErr(Error::InvalidReply)\n\t}\n}\n",
                .symbol => "fn symbol(value: Argument) -> Result<String, Error> {\n" ++
                    "\tif let Argument::Symbol(value) = value {\n\t\tOk(value)\n" ++
                    "\t} else {\n\t\tErr(Error::InvalidReply)\n\t}\n}\n",
                .float64 => "fn float64(value: Argument) -> Result<f64, Error> {\n" ++
                    "\tif let Argument::Float(value) = value {\n\t\tOk(value)\n" ++
                    "\t} else {\n\t\tErr(Error::InvalidReply)\n\t}\n}\n",
                .error_value => "fn error_value(value: Argument) -> Result<String, Error> {\n" ++
                    "\tif let Argument::Error(value) = value {\n\t\tOk(value)\n" ++
                    "\t} else {\n\t\tErr(Error::InvalidReply)\n\t}\n}\n",
                else => unreachable,
            });
        };
    }
};
