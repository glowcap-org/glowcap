//! Compile independently from the test executable: native archives do not
//! share the addresses of private Host callbacks, even with identical source.
const core = @import("driver_core");
const actors = @import("actors");

export fn glowcap_test_archive_enliven(host: *core.Host) ?*core.Host.Enliven {
    return host.enlivenCapability(host.allocator, .{
        .peer = .{ .transport = "tcp", .designator = "127.0.0.1:7911" },
        .swissnum = "widget",
    }) catch null;
}

export fn glowcap_test_archive_call(host: *core.Host, session: *core.HostSession, target: *const core.Capability) ?*core.Host.Call {
    return host.callCapability(host.allocator, session, target.*, "poke", &.{}, 4096) catch null;
}

export fn glowcap_test_archive_send(host: *core.Host, target: *const core.Capability) u64 {
    return host.sendApplicationValues(target.*, "poke", &.{}, host.allocator) catch 0;
}

export fn glowcap_test_archive_forward(turn: *actors.Turn, vow: *const actors.Vow) bool {
    turn.forwardVow(vow.*) catch return false;
    return true;
}
