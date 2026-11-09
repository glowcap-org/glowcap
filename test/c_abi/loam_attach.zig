//! Attaching content through a C-created context. A refused attach keeps
//! nothing, whether the allocator failed or the registration declared more
//! methods than the C boundary copies, and the context's allocator ends
//! balanced once everything is released.
const std = @import("std");
const c = @import("c_abi_loam");
const shared = @import("c_abi_shared");
const h = @import("c_abi_host");
const root = @import("c_abi");
const core = @import("loam_core");
const CountingHost = @import("support_c_abi_counting_alloc").CountingHost;
const callbacks = @import("loam_callbacks.zig");

/// A store on a counted context, and a host to attach content to. Opened in
/// place, because the counter's address is the allocator the context holds.
const Fixture = struct {
    counter: CountingHost = .{},
    context: ?*root.GlowcapContext = null,
    store: ?*c.GlowcapLoamStore = null,
    host: ?*h.GlowcapHost = null,
    /// What the store alone holds, before any attach.
    store_bytes: usize = 0,

    fn open(self: *Fixture) !void {
        const spec = self.counter.spec();
        try std.testing.expectEqual(shared.GLOWCAP_OK, root.glowcap_context_new_with_allocator(&spec, &self.context));
        const metadata = (core.Metadata{ .store = @fromBackingInt(3), .incarnation = 1 }).encode();
        const limits: c.GlowcapLoamLimits = .{ .resident_bytes = 4 * 1024 * 1024, .staging_bytes = 4 * 1024 * 1024, .cache_slots = 64, .max_leases = 128, .max_changes = 64, .max_references = 128, .max_operations = 32 };
        const schemas = [_]c.GlowcapLoamSchema{.{ .id = 7, .version = 1, .max_payload = 256, .max_edges = 8 }};
        try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_new_in(self.context, &metadata, metadata.len, &schemas, schemas.len, &limits, &self.store));
        self.store_bytes = self.counter.live_bytes;
        const seed: [64]u8 = @splat(8);
        try std.testing.expectEqual(shared.GLOWCAP_OK, h.glowcap_host_new(&seed, seed.len, 4096, 1, shared.GLOWCAP_CODEC_SYRUP, shared.GLOWCAP_CAPTP_V1_0, shared.GLOWCAP_FEATURE_FULL, 0, 1, &self.host));
    }

    /// Nothing may be attached any more. The store goes, then the context,
    /// which must have given back every byte, and the host last.
    fn close(self: *Fixture) void {
        std.debug.assert(c.glowcap_loam_store_release(self.store) == shared.GLOWCAP_OK);
        root.glowcap_context_release(self.context);
        std.debug.assert(self.counter.balanced());
        std.debug.assert(h.glowcap_host_release(self.host) == shared.GLOWCAP_OK);
    }

    fn attach(self: *Fixture, methods: []const c.GlowcapLoamMethod, attachment: *?*c.GlowcapLoamAttachment) i32 {
        const contents = [_]c.GlowcapLoamContent{.{ .schema = 7, .version = 1, .context = null, .methods = methods.ptr, .method_count = methods.len, .requirement = callbacks.requirements, .invoke = callbacks.invoke }};
        return c.glowcap_loam_attach(self.store, self.host, &contents, contents.len, callbacks.entropy, null, attachment);
    }
};

const one_method = [_]c.GlowcapLoamMethod{.{ .verb = "get", .verb_len = 3, .retry = 0 }};

test "Loam attach on a C context keeps nothing when allocation fails, and the store outlives its attachment" {
    var f: Fixture = .{};
    try f.open();
    defer f.close();
    var attachment: ?*c.GlowcapLoamAttachment = null;
    f.counter.allocations_before_failure = 2;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INTERNAL, f.attach(&one_method, &attachment));
    try std.testing.expect(attachment == null);
    try std.testing.expectEqual(f.store_bytes, f.counter.live_bytes);
    f.counter.allocations_before_failure = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, f.attach(&one_method, &attachment));
    try std.testing.expect(f.counter.live_bytes > f.store_bytes);
    // The store refuses to go while something is attached to it.
    try std.testing.expectEqual(shared.GLOWCAP_ERR_WOULD_BLOCK, c.glowcap_loam_store_release(f.store));
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_attachment_release(attachment));
    try std.testing.expectEqual(f.store_bytes, f.counter.live_bytes);
}

test "Loam attach refuses a registration with more methods than the C boundary copies" {
    var f: Fixture = .{};
    try f.open();
    defer f.close();
    // One past the bound: the registration is refused whole, by name, and nothing of it is kept.
    var methods: [c.max_content_methods + 1]c.GlowcapLoamMethod = undefined;
    for (&methods) |*method| method.* = one_method[0];
    var attachment: ?*c.GlowcapLoamAttachment = null;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INVALID_ARGUMENT, f.attach(&methods, &attachment));
    try std.testing.expect(attachment == null);
    var said: [64]u8 = undefined;
    try std.testing.expectEqualStrings("loam: TooManyMethods", said[0..shared.lastErrorRead(&said, said.len)]);
    try std.testing.expectEqual(f.store_bytes, f.counter.live_bytes);
}
