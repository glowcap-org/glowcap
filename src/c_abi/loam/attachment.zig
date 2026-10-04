//! Registrations borrow the existing Host and one Loam Store.
const std = @import("std");
const common = @import("common.zig");
const callbacks = @import("callbacks.zig");
const vocabulary = @import("vocabulary.zig");
const c = common.c;
const access = common.access;
const core = common.core;
const driver = common.driver;
const shared = common.shared;

pub const Attachment = struct {
    store: *common.Store,
    host_borrow: common.host.embedding.AttachmentBorrow,
    caps: access.storage.Capabilities,
    contents: []callbacks.Content,
    content_behaviors: []access.hosting.ContentBehavior,
    service: access.hosting.Service,
    behaviors: [access.hosting.Service.behavior_count]common.hosting.Behavior,
    value: *common.hosting.Attachment,
    entropy: c.GlowcapLoamEntropyFn,
    context: ?*anyopaque,
    works: usize = 0,
    recovery_work: bool = false,
    work_slots: []@import("work.zig").Work,
    /// Startup reserves declaration/behavior arrays and cache_slots + 1 Work
    /// slots. Their independent admission limit bounds executor custody;
    /// The pool refuses pressure rather than allocating handles in a turn.
    /// Both inventories survive suspended calls and are freed only after detach.
    pub fn create(store: *common.Store, host: ?*common.host.GlowcapHost, contents: []const c.GlowcapLoamContent, entropy: c.GlowcapLoamEntropyFn, ctx: ?*anyopaque) !*Attachment {
        const gpa = store.allocator;
        if (contents.len == 0 or contents.len > 128) return error.InvalidArgument;
        const borrow = try common.host.embedding.borrowForAttachment(host);
        errdefer borrow.release();
        const owner = try gpa.create(Attachment);
        errdefer gpa.destroy(owner);
        const declarations = try gpa.alloc(callbacks.Content, contents.len);
        errdefer gpa.free(declarations);
        var count: usize = 0;
        errdefer for (declarations[0..count]) |*item| item.deinit();
        for (contents, declarations, 0..) |raw, *item, i| {
            const configured = for (store.schemas) |schema| {
                if (schema.id == raw.schema and schema.version == raw.version) break true;
            } else false;
            if (!configured) return error.UnsupportedSchema;
            for (contents[0..i]) |previous| if (previous.schema == raw.schema and previous.version == raw.version) return error.DuplicateSchema;
            item.* = try callbacks.Content.init(gpa, raw);
            count += 1;
        }
        const content_behaviors = try gpa.alloc(access.hosting.ContentBehavior, contents.len);
        errdefer gpa.free(content_behaviors);
        for (declarations, content_behaviors) |*item, *target| {
            item.host = borrow.core();
            target.* = item.behavior();
        }
        // Publish each stable owner only after its fallible construction succeeds.
        owner.store = store;
        owner.host_borrow = borrow;
        owner.contents = declarations;
        owner.content_behaviors = content_behaviors;
        owner.entropy = entropy;
        owner.context = ctx;
        owner.works = 0;
        owner.recovery_work = false;
        const work_slots = try gpa.alloc(@import("work.zig").Work, try std.math.add(usize, store.limits.cache_slots, 1));
        errdefer gpa.free(work_slots);
        for (work_slots) |*slot| slot.* = .{ .owner = owner };
        owner.work_slots = work_slots;
        owner.caps = try access.storage.Capabilities.init(gpa, &store.value, .{ .max_references = store.limits.max_references, .max_operations = store.limits.max_operations });
        errdefer owner.caps.deinit() catch unreachable;
        owner.service = .{ .capabilities = &owner.caps, .contents = content_behaviors, .context = owner, .decode_control = vocabulary.edit, .decode_derive = vocabulary.derive, .decode_managed_derive = vocabulary.managed, .decode_attenuation = vocabulary.attenuate, .entropy = .{ .context = owner, .fill = fillEntropy } };
        owner.behaviors = owner.service.behaviors();
        owner.value = try common.hosting.Attachment.create(gpa, borrow.core(), &store.value, &owner.behaviors, .{ .max_endpoints = store.limits.max_references, .max_calls = store.limits.max_operations });
        errdefer owner.value.destroy() catch unreachable;
        try common.hosting.publication.listen(owner.value, .{ .max_names = store.limits.cache_slots, .max_fetches = store.limits.max_operations });
        store.attachments += 1;
        return owner;
    }
    pub fn destroy(self: *Attachment) !void {
        const gpa = self.store.allocator;
        if (self.works != 0) return error.Busy;
        try self.value.destroy();
        gpa.free(self.work_slots);
        self.caps.deinit() catch unreachable;
        for (self.contents) |*item| item.deinit();
        gpa.free(self.contents);
        gpa.free(self.content_behaviors);
        self.store.attachments -= 1;
        self.host_borrow.release();
        gpa.destroy(self);
    }
};
pub fn attachment(raw: ?*c.GlowcapLoamAttachment) !*Attachment {
    return @ptrCast(@alignCast(raw orelse return error.NullPointer));
}
fn fillEntropy(ctx: ?*anyopaque, entropy: *driver.Host.DurableSwiss.Entropy) !void {
    const self: *Attachment = @ptrCast(@alignCast(ctx.?));
    const host = self.host_borrow.core();
    const previous = host.in_callback;
    host.in_callback = true;
    defer host.in_callback = previous;
    if (self.entropy(self.context, entropy, entropy.len) != shared.GLOWCAP_OK) return error.EntropyFailed;
}
