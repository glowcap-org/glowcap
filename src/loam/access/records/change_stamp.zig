//! A scoped model revision and its owner batch position travel together.
const syntax = @import("syrup").RecordSyntax;

pub const ChangeStamp = struct {
    revision: u64 = 0,
    position: u64 = 0,

    pub fn validate(self: ChangeStamp, model_revision: u64) error{InvalidRecord}!void {
        if (self.revision > model_revision) return error.InvalidRecord;
    }
    pub fn write(self: ChangeStamp, sink: anytype) !void {
        try syntax.writePositiveInt(sink, self.revision);
        try syntax.writePositiveInt(sink, self.position);
    }
    pub fn read(bytes: []const u8, cursor: *usize) !ChangeStamp {
        return .{ .revision = try syntax.readPositiveInt(bytes, cursor), .position = try syntax.readPositiveInt(bytes, cursor) };
    }
};
