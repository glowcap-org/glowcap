//! Every error a public Host verb can return reaches the C ABI through
//! `HostFailure.classify`. An error neither the Host nor the engine names
//! falls to `GLOWCAP_ERR_INTERNAL`, so a caller's own misuse, such as an
//! over-release, reads as a host-internal failure. Host verbs infer their error
//! sets, so this walks them at comptime: one test fails on any name with no
//! category, the other on any verb whose set widened to `anyerror`, which
//! would hide its names from the first.
//!
//! Deleting one category arm makes the first test name that error. Returning
//! `anyerror` from `failDispatch` makes the second name the four feed verbs.
//! Generic verbs (`comptime` or `anytype` parameters) have no error set before
//! instantiation and are not walked.
const std = @import("std");
const glowcap = @import("glowcap");
const Host = glowcap.driver.core.Host;
const HostFailure = glowcap.driver.core.HostFailure;
const abort = glowcap.ocapn.engine.abort_projection;

fn openVerbs() []const []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var names: []const []const u8 = &.{};
        for (std.meta.declarations(Host)) |name| {
            const T = @TypeOf(@field(Host, name));
            if (@typeInfo(T) != .@"fn" or @typeInfo(T).@"fn".is_generic) continue;
            const R = @typeInfo(T).@"fn".return_type orelse continue;
            if (@typeInfo(R) != .error_union) continue;
            if (@typeInfo(@typeInfo(R).error_union.error_set).error_set.error_names == null) names = names ++ .{name};
        }
        const final = names[0..names.len].*;
        return &final;
    }
}

fn hostErrorNames() []const []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var names: []const []const u8 = &.{};
        for (std.meta.declarations(Host)) |name| {
            const T = @TypeOf(@field(Host, name));
            if (@typeInfo(T) != .@"fn" or @typeInfo(T).@"fn".is_generic) continue;
            const R = @typeInfo(T).@"fn".return_type orelse continue;
            if (@typeInfo(R) != .error_union) continue;
            const set = @typeInfo(@typeInfo(R).error_union.error_set).error_set.error_names orelse continue;
            outer: for (set) |err_name| {
                for (names) |seen| if (std.mem.eql(u8, seen, err_name)) continue :outer;
                names = names ++ .{err_name};
            }
        }
        const final = names[0..names.len].*;
        return &final;
    }
}

test "every error a public Host verb returns has a Host failure category" {
    var missing: usize = 0;
    inline for (comptime hostErrorNames()) |name| {
        const err: anyerror = @field(anyerror, name);
        if (HostFailure.named(err) == null and abort.classify(err).domain == .foreign) {
            std.debug.print("unclassified Host error: {s}\n", .{name});
            missing += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}

test "a caller's over-release is an invalid argument, not a host-internal failure" {
    try std.testing.expectEqual(HostFailure.Kind.invalid_argument, HostFailure.classify(error.ReleaseExceedsRetains));
}

test "a public Host verb returns an exact error set" {
    const open = comptime openVerbs();
    inline for (open) |name| std.debug.print("Host verb returns anyerror: {s}\n", .{name});
    try std.testing.expectEqual(@as(usize, 0), open.len);
}
