//! Whole-frame C ingress preserves the Host's size refusal and typed abort.
const std = @import("std");
const c = @import("c_abi");
const host = @import("c_abi_host");
const harness = @import("harness.zig");

test "libglowcap_host: whole-frame feed refuses an over-cap hello and retains the abort" {
    var tiny: ?*host.GlowcapHost = null;
    const seed = harness.hostSeed(0x91);
    try harness.expectOk(host.glowcap_host_new(&seed, seed.len, 64, 1, c.GLOWCAP_CODEC_SYRUP, c.GLOWCAP_CAPTP_V1_0, c.GLOWCAP_FEATURE_FULL, 0, 1, &tiny));
    defer _ = host.glowcap_host_release(tiny);
    const dialer = try harness.newHost(0x92);
    defer _ = host.glowcap_host_release(dialer);
    const designator = "127.0.0.1:7005";
    try harness.ensureAdvertisedLocator(dialer, "tcp");
    try harness.setAdvertisedLocator(tiny, harness.tcpLocator(designator));
    var accepted: ?*host.GlowcapHostSession = null;
    try harness.expectOk(harness.openAccepted(tiny, "tcp", 3, &accepted));
    var dialed: ?*host.GlowcapHostSession = null;
    try harness.expectOk(harness.openDialed(dialer, "tcp", 3, designator.ptr, designator.len, &dialed));
    var hello: c.GlowcapManagedFrame = undefined;
    try harness.expectOk(harness.takeOutbound(dialed, &hello));
    defer c.glowcap_managed_frame_release(&hello);
    try std.testing.expect(hello.len > 64);
    const borrowed: c.GlowcapFrame = .{ .bytes = hello.bytes, .len = hello.len, .shape = hello.shape };
    try std.testing.expectEqual(c.GLOWCAP_ERR_FRAME_TOO_LARGE, host.glowcap_host_session_feed(accepted, &borrowed));
    var abort_info: c.GlowcapLastAbort = undefined;
    try harness.expectOk(host.glowcap_host_session_last_abort(accepted, &abort_info));
    try std.testing.expect(abort_info.has_kind != 0);
    try std.testing.expectEqualStrings("ResourceExhausted", abort_info.kind_name.?[0..abort_info.kind_name_len]);
}
