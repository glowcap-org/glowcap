//! Shared harness for the onion C-ABI loopback proofs: the fake-daemon
//! netlayer mint, the frame-shuttling loopback transport, and the release
//! helpers every scenario family funnels through. Both daemons are fakes on
//! loopback; their bytes are pinned against the reference implementations in
//! `test/net/onion_socks5_test.zig` and `test/net/onion_control_test.zig`.

const std = @import("std");
const glowcap = @import("glowcap");

const c = @import("c_abi");
const co = @import("c_abi_net_transport_onion");
const model = glowcap.ocapn.model;
const onion = glowcap.net.onion;
const c_abi_loopback = @import("../../support/c_abi_loopback.zig");
const handshake = @import("../../support/handshake.zig");
const fake = @import("../../support/onion_fake_daemon.zig");
const fetch_pump = @import("../../support/fetch_pump.zig");
const wait = @import("../../support/wait.zig");

pub const frame_cap = c_abi_loopback.frame_cap;

pub fn releaseOnionListener(listener: *co.GlowcapOnionListener) void {
    std.testing.expectEqual(c.GLOWCAP_OK, co.glowcap_onion_listener_release(listener, null, 0, null)) catch unreachable;
}

pub fn releaseOnionNetlayer(netlayer: ?*co.GlowcapOnionNetlayer) void {
    std.testing.expectEqual(c.GLOWCAP_OK, co.glowcap_onion_netlayer_release(netlayer, null, 0, null)) catch unreachable;
}

pub const Transport = struct {
    pub const Conn = *co.GlowcapOnionConn;
    pub const Listener = *co.GlowcapOnionListener;

    pub fn writeFrame(conn: Conn, cf: *c.GlowcapFrame) i32 {
        return co.glowcap_onion_conn_write_frame(conn, cf, null, 0, null);
    }

    pub fn readFrame(conn: Conn, mf: *c.GlowcapManagedFrame) i32 {
        return co.glowcap_onion_conn_read_frame(conn, mf, null, 0, null);
    }

    pub fn accept(
        listener: Listener,
        codec: u32,
        max_frame_bytes: usize,
        out_conn: *?Conn,
    ) i32 {
        return co.glowcap_onion_accept(listener, codec, max_frame_bytes, out_conn, null, 0, null);
    }

    pub fn releaseConn(conn: Conn) void {
        _ = co.glowcap_onion_conn_release(conn, null, 0, null);
    }
};

pub const Loopback = c_abi_loopback.Harness(Transport);

pub fn startSession(name: []const u8) model.Message {
    return handshake.startSession(onion.transport_name, name);
}

/// Build a netlayer against `daemon`, both endpoints.
pub fn netlayerFor(daemon: *fake.Daemon) !*co.GlowcapOnionNetlayer {
    var netlayer: ?*co.GlowcapOnionNetlayer = null;
    var config: co.GlowcapOnionConfig = .{};
    config.socks = daemon.socksText().ptr;
    config.socks_len = daemon.socksText().len;
    config.control_endpoint = daemon.controlText().ptr;
    config.control_endpoint_len = daemon.controlText().len;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        co.glowcap_onion_netlayer_new(&config, &netlayer),
    );
    return netlayer.?;
}

/// A real, checksum-valid version 3 id, from the pinned Goblins source.
pub const service_id = fake.service_id;
