//! The contract checks name the first operation an engine or backend lacks.
const std = @import("std");
const core = @import("fixture.zig").core;

test "loam engine check names the first absent operation" {
    const Whole = struct {
        pub const ReadTransaction = struct {
            pub fn get() void {}
            pub fn next() void {}
            pub fn end() void {}
        };
        pub const WriteTransaction = struct {
            pub fn get() void {}
            pub fn next() void {}
            pub fn put() void {}
            pub fn commit() void {}
            pub fn abort() void {}
        };
        pub fn beginRead() void {}
        pub fn beginWrite() void {}
        pub fn readerCapacity() void {}
    };
    try std.testing.expectEqualStrings("write transaction lacks remove", core.backend.missingOperation(Whole).?);
    try std.testing.expectEqualStrings("engine lacks beginRead", core.backend.missingOperation(struct {}).?);
    try std.testing.expectEqualStrings("engine lacks readerCapacity", core.backend.missingOperation(struct {
        pub fn beginRead() void {}
        pub fn beginWrite() void {}
    }).?);
}

test "loam backend check names the first absent operation" {
    const Partial = struct {
        pub fn read() void {}
        pub fn commit() void {}
        pub fn recover() void {}
    };
    try std.testing.expectEqualStrings("backend lacks lookup", core.backend.missingBackendOperation(Partial).?);
}
