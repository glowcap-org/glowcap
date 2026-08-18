//! Formatting seam between relay-owned request targets and RFC 6455 upgrade.

const std = @import("std");

const protocol = @import("../../websocket/client_protocol.zig");
const route = @import("route.zig");

pub const Formatter = struct {
    request: route.OpenRequest,
    key: *const [24]u8,

    pub fn format(self: Formatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(protocol.upgrade_request_fmt, .{
            self.request.path(),
            self.request.fixedQueryPrefix(),
            self.request.queryJoin(),
            self.request.queryName(),
            self.request.query_value,
            self.request.endpoint.authority,
            self.key,
        });
    }
};

pub fn formatter(request: route.OpenRequest, key: *const [24]u8) Formatter {
    return .{ .request = request, .key = key };
}
