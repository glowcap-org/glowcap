//! Bounded recursive read interfaces over an immutable source intent.
const std = @import("std");
const driver = @import("driver_core");
const h = @import("attachment.zig");
const calls = @import("calls.zig");
const values = @import("values.zig");
const memory = @import("call_memory.zig");
const Continuation = @import("continuation.zig").Continuation;
const actors = @import("actors");

pub const Scope = struct {
    /// Trusted content declares read verbs and the interface of every returned
    /// capability, in Value traversal order. An empty list forbids capabilities.
    /// Interface indices refer to the same declaration, including recursive ones.
    pub const Method = struct { verb: []const u8, results: []const usize = &.{} };
    pub const Interface = struct { methods: []const Method };
    pub const Bounds = struct { interfaces: usize, methods: usize, verb_bytes: usize, result_roles: usize, targets: usize };

    pub fn sizeBound(arguments: values.Bounds, source_verb_bytes: usize, declaration: Bounds) !usize {
        var bound = try memory.inputAllocationBound(arguments, source_verb_bytes, false);
        try bound.include(try std.math.mul(usize, declaration.interfaces, @sizeOf([]const HeldMethod)), @alignOf([]const HeldMethod), 1);
        try bound.includeTotal(try std.math.mul(usize, declaration.methods, @sizeOf(HeldMethod)), @alignOf(HeldMethod), declaration.interfaces);
        try bound.includeTotal(declaration.verb_bytes, 1, declaration.methods);
        try bound.includeTotal(try std.math.mul(usize, declaration.result_roles, @sizeOf(usize)), @alignOf(usize), declaration.methods);
        try bound.include(try std.math.mul(usize, declaration.targets, @sizeOf(Cache)), @alignOf(Cache), 1);
        try bound.include(@sizeOf(driver.Capability), @alignOf(driver.Capability), 1);
        return std.math.add(usize, @sizeOf(Scope), try bound.physicalBytes());
    }

    owner: *h.Attachment,
    backing: memory.Memory = undefined,
    source: driver.Capability = undefined,
    intent: h.Call.Intent = undefined,
    arguments: []driver.Capability = &.{},
    continuation: ?*Continuation = null,
    interfaces: []const []const HeldMethod = &.{},
    cache: []Cache = &.{},
    references: usize = 1,

    const HeldMethod = struct {
        scope: *Scope,
        verb: []const u8,
        results: []const usize,
        projection: calls.Projection,
    };
    const Cache = struct {
        target: driver.Capability = undefined,
        role: usize = 0,
        front: ?driver.Capability = null,
        occupied: bool = false,
    };

    /// Copies the declaration and original intent before any upstream wait.
    /// Source custody, declarations and weak cache share the continuation count
    /// and physical byte allowance. Host actor storage remains Host-owned.
    pub fn createCopying(call: *h.Call, intent: h.Call.Intent, interfaces: []const Interface) !*Scope {
        const owner = call.attachment;
        const entry = owner.liveEntry(call.view.id) orelse return error.NotDurable;
        return create(owner, .{ .actor = entry.actor.? }, intent, interfaces, null);
    }

    /// Copy only the read declaration. The activated continuation owns the
    /// immutable source intent and all argument custody until the last reader
    /// retires, independently of the executor observer and receipt settlement.
    pub fn createRetaining(continuation: *Continuation, interfaces: []const Interface) !*Scope {
        const admitted = try continuation.admission();
        return create(admitted.owner, .{ .capability = admitted.source }, admitted.intent, interfaces, continuation);
    }

    const Source = union(enum) { actor: actors.Ref, capability: driver.Capability };
    fn create(owner: *h.Attachment, source: Source, intent: h.Call.Intent, interfaces: []const Interface, continuation: ?*Continuation) !*Scope {
        if (owner.closing) return error.AttachmentClosed;
        if (owner.continuations >= owner.options.max_continuations or
            owner.options.continuation_bytes <= @sizeOf(Scope) or interfaces.len == 0) return error.ContinuationCapacity;
        const self = try owner.allocator.create(Scope);
        errdefer owner.allocator.destroy(self);
        self.* = .{ .owner = owner };
        self.backing.init(owner.allocator, owner.options.continuation_bytes - @sizeOf(Scope));
        errdefer self.backing.deinit();
        const arena = self.backing.input.allocator();
        const verb = if (continuation != null) intent.verb else try arena.dupe(u8, intent.verb);
        const args = if (continuation != null) intent.args else copied: {
            const args = try arena.alloc(driver.Value, intent.args.len);
            for (args, intent.args) |*out, item| out.* = try values.copy(driver.Value, arena, item);
            break :copied args;
        };
        const held: []driver.Capability = if (continuation != null) &.{} else try owner.host.retainValueCapabilities(arena, args);
        errdefer owner.host.releaseCapabilityRetains(held);
        const declarations = try arena.alloc([]const HeldMethod, interfaces.len);
        for (declarations, interfaces) |*out, interface| {
            const methods = try arena.alloc(HeldMethod, interface.methods.len);
            for (methods, interface.methods, 0..) |*method, declaration, index| {
                if (declaration.verb.len == 0) return error.InvalidReadInterface;
                for (interface.methods[0..index]) |prior| if (std.mem.eql(u8, prior.verb, declaration.verb)) return error.InvalidReadInterface;
                for (declaration.results) |role| if (role >= interfaces.len) return error.InvalidReadInterface;
                method.* = .{
                    .scope = self,
                    .verb = try arena.dupe(u8, declaration.verb),
                    .results = try arena.dupe(usize, declaration.results),
                    .projection = .{ .context = method, .retain = retainProjection, .release = releaseProjection, .project = projectReply },
                };
            }
            out.* = methods;
        }
        self.cache = try arena.alloc(Cache, owner.options.max_continuation_targets);
        @memset(self.cache, .{});
        if (continuation) |retained| {
            try retained.retainForReadScope();
            self.source = source.capability;
            self.continuation = retained;
        } else self.source = try owner.host.retainLocalCapability(source.actor);
        self.intent = .{ .verb = verb, .args = args };
        self.arguments = held;
        self.interfaces = declarations;
        owner.continuations += 1;
        owner.read_scopes += 1;
        return self;
    }

    /// One owned facade for this exact target and interface. The cache borrows
    /// actors, so readers can be released without a scope/facade retain cycle.
    pub fn project(self: *Scope, target: driver.Capability, role: usize) !driver.Capability {
        if (self.owner.closing) return error.AttachmentClosed;
        if (role >= self.interfaces.len) return error.InvalidReadInterface;
        defer self.backing.working.deinit();
        for (self.cache) |entry| if (entry.occupied and entry.role == role and entry.target.eql(target)) {
            const retained = try self.owner.host.retainValueCapabilities(self.backing.working.allocator(), &.{.{ .capability = entry.front.? }});
            return retained[0];
        };
        const index = for (self.cache, 0..) |entry, index| {
            if (!entry.occupied) break index;
        } else return error.ContinuationCapacity;
        const held = try self.owner.host.retainValueCapabilities(self.backing.working.allocator(), &.{.{ .capability = target }});
        self.retain();
        self.cache[index] = .{ .occupied = true, .target = held[0], .role = role };
        // spawn consumes Endpoint even on refusal; its destructor clears the
        // reserved weak entry and releases the independent target/scope retains.
        const actor = try self.owner.host.vat.spawn(driver.Hosting(Endpoint), .{ .inner = .{ .scope = self, .index = index } });
        errdefer self.owner.host.vat.discardFreshActor(actor);
        const front = try self.owner.host.liftLocalActor(actor);
        self.cache[index].front = front;
        return front;
    }

    fn retain(self: *Scope) void {
        std.debug.assert(self.references != std.math.maxInt(usize));
        self.references += 1;
    }
    pub fn release(self: *Scope) void {
        std.debug.assert(self.references != 0);
        self.references -= 1;
        if (self.references != 0) return;
        const owner = self.owner;
        if (self.continuation) |retained| retained.releaseForReadScope() else owner.host.releaseCapabilityTerminal(self.source, null);
        for (self.arguments) |argument| owner.host.releaseCapabilityTerminal(argument, null);
        self.backing.deinit();
        owner.allocator.destroy(self);
        std.debug.assert(owner.continuations != 0);
        owner.continuations -= 1;
        std.debug.assert(owner.read_scopes != 0);
        owner.read_scopes -= 1;
        h.releaseClosed(owner);
    }

    fn retainProjection(context: *anyopaque) void {
        const method: *HeldMethod = @ptrCast(@alignCast(context));
        method.scope.retain();
    }
    fn releaseProjection(context: *anyopaque) void {
        const method: *HeldMethod = @ptrCast(@alignCast(context));
        method.scope.release();
    }
    fn projectReply(context: *anyopaque, call: *h.Call, reply: driver.Value) !driver.Value {
        const method: *HeldMethod = @ptrCast(@alignCast(context));
        var count: usize = 0;
        try reply.forEachCapability(&count, countCapability);
        if (count != method.results.len) return error.UndeclaredDisclosure;
        if (count == 0) return reply;
        // Only container spines copy. Scalar leaves remain under the forwarded
        // result owner; every replacement facet is independently held by Call.
        var index: usize = 0;
        return transform(method, call, reply, &index, 0);
    }
    fn countCapability(count: *usize, _: driver.Capability) !void {
        count.* = try std.math.add(usize, count.*, 1);
    }
    fn transform(method: *HeldMethod, call: *h.Call, value: driver.Value, index: *usize, depth: usize) !driver.Value {
        if (depth > driver.Value.max_depth) return error.ValueTooDeep;
        switch (value) {
            .capability => |target| {
                try call.held.ensureUnusedCapacity(call.arena(), 1);
                const front = try method.scope.project(target, method.results[index.*]);
                index.* += 1;
                call.adoptRetain(front);
                return .{ .capability = try call.discloseHeld(front) };
            },
            .list, .set, .tagged => {
                const items = switch (value) {
                    .list => value.list,
                    .set => value.set,
                    else => value.tagged.value,
                };
                const out = try call.arena().alloc(driver.Value, items.len);
                for (out, items) |*destination, item| destination.* = try transform(method, call, item, index, depth + 1);
                return switch (value) {
                    .list => .{ .list = out },
                    .set => .{ .set = out },
                    else => .{ .tagged = .{ .tag = value.tagged.tag, .value = out } },
                };
            },
            .@"struct" => |items| {
                const out = try call.arena().alloc(driver.Value.StructEntry, items.len);
                for (out, items) |*destination, item| destination.* = .{ .key = item.key, .value = try transform(method, call, item.value, index, depth + 1) };
                return .{ .@"struct" = out };
            },
            else => return value,
        }
    }

    const Endpoint = struct {
        scope: *Scope,
        index: usize,
        pub fn handle(self: *Endpoint, turn: *driver.HostTurn, verb: []const u8, args: driver.Args) !driver.Value {
            const arg_values = try args.values();
            defer turn.releaseValues(arg_values);
            const scope = self.scope;
            const entry = scope.cache[self.index];
            const method = for (scope.interfaces[entry.role]) |*candidate| {
                if (std.mem.eql(u8, candidate.verb, verb)) break candidate;
            } else return error.NoSuchMethod;
            try calls.admitContinuation(scope.owner, scope.source, turn, scope.intent, entry.target, .{ .verb = verb, .args = arg_values }, .{ .mediated = &method.projection });
            return .{ .void = {} };
        }
        pub fn deinit(self: *Endpoint, _: std.mem.Allocator) void {
            const scope = self.scope;
            const target = scope.cache[self.index].target;
            scope.cache[self.index] = .{};
            scope.owner.host.releaseCapabilityTerminal(target, null);
            scope.release();
        }
    };
};
