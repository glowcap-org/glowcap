//! The keyed-relay registered listener: opens and holds a registration at the
//! relay, waits for legs to become acceptable, and presents each accepted leg
//! to the netlayer as a connection under the profile that registered it.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const connection = @import("../../connection.zig");
const netlayer = @import("../../netlayer.zig");
const clock = @import("../../clock.zig");
const operation_owner = @import("../../operation_owner.zig");
const poll = @import("../../poll.zig");
const sync = @import("../../sync.zig");
const wake_channel = @import("../../wake_channel.zig");
const carrier_runtime = @import("carrier/runtime.zig");
const pollable_carrier = @import("carrier/pollable.zig");
const relay_configuration = @import("configuration.zig");
const relay_profile = @import("profile.zig");
const raw_connection = @import("raw_connection.zig");
const relay_stream = @import("stream.zig");
const route = @import("route.zig");

const Buffers = netlayer.Buffers;
const Connection = connection.Connection;
const crypto = foundation.crypto;
const ChannelProfile = relay_profile.Channel;
const RelayUrl = route.RelayUrl;
const RelayStream = relay_stream.RelayStream;
const openLegOutcome = pollable_carrier.openOutcome;
const listener_poll_slice_ms: i32 = 50;
const registration_retry_delay_ms: i64 = 100;

pub fn open(
    allocator: std.mem.Allocator,
    config_view: *const relay_configuration.Config,
    carrier_owner: carrier_runtime.Lease,
    channel_profile: ChannelProfile,
    config: netlayer.ListenConfig,
) netlayer.ListenError!*Box {
    if (config_view.relay_url_text.len > route.max_rendezvous_relay_hint_bytes)
        return error.BindFailed;
    const registered = switch (config_view.registration) {
        .dial_only => return error.InvalidAddress,
        .registered => |configured| configured,
    };
    const identity = config.identity orelse return error.InvalidAddress;
    if (registered.public_key) |expected| {
        if (!std.mem.eql(u8, &identity.bytes, &expected.bytes)) return error.InvalidAddress;
    }
    if (config.designator.len != 0) {
        const expected = identity.toDesignator();
        if (!std.mem.eql(u8, config.designator, &expected)) return error.InvalidAddress;
    }
    const register_url_storage = allocator.dupe(u8, registered.url_text) catch return error.OutOfMemory;
    errdefer allocator.free(register_url_storage);
    const relay_url_storage = allocator.dupe(u8, config_view.relay_url_text) catch return error.OutOfMemory;
    errdefer allocator.free(relay_url_storage);
    const box = allocator.create(Box) catch return error.OutOfMemory;
    errdefer allocator.destroy(box);
    const wake = wake_channel.WakeChannel.open() catch return error.BindFailed;
    errdefer wake.deinit();
    var carrier = carrier_owner.retain();
    errdefer _ = carrier.releaseOutcome();
    box.* = .{
        .carrier = carrier,
        .register_url_storage = register_url_storage,
        .register_url = RelayUrl.parse(register_url_storage) catch unreachable,
        .relay_url_storage = relay_url_storage,
        .public_key = identity,
        .profile = channel_profile,
        .allocator = allocator,
        .ready = null,
        .wake = wake,
        .registrations = undefined,
        .registration = undefined,
    };
    box.registration = .{ .box = box };
    box.registrations.init(carrier_owner.io()) catch return error.BindFailed;
    errdefer box.registrations.join();
    box.startRegistration() catch return error.BindFailed;
    return box;
}

/// The registered half: one background-owned registration socket, replaced as
/// each accept consumes it — the rendezvous shape of a bound TCP listener. The
/// task answers relay control frames and wakes the listener only when dialer
/// data is ready, so the caller's readiness wait performs no network I/O.
pub const Box = struct {
    carrier: carrier_runtime.Lease,
    /// Sole owner of every slice in `register_url`.
    register_url_storage: []u8,
    register_url: RelayUrl,
    /// Sole owner of the relay URL published in the listener locator.
    relay_url_storage: []u8,
    public_key: crypto.PeerKey,
    profile: ChannelProfile,
    allocator: std.mem.Allocator,
    /// A registration task moved a stream here after it consumed the first
    /// application frame header. The next accept takes it without blocking.
    ready: ?*RelayStream,
    /// Serializes listener state and the readiness wait. The registration task
    /// communicates only through its fixed job record plus the wake channel.
    wake: wake_channel.WakeChannel,
    wake_failure: wake_channel.FailureLatch = .{},
    repair_failure_mutex: sync.SpinLock = .{},
    repair_failure: ?foundation.FailureChain = null,
    /// Registration tasks perform TCP connect, HTTP upgrade, and parked
    /// WebSocket control handling. Close seals, cancels, and joins this owner.
    registrations: operation_owner.OperationOwner,
    registration: RegisterJob,
    registration_active: bool = false,
    /// Construction crossed its first successful registration. Every later
    /// registration is repair work and owns transient retry from its first leg.
    listener_established: bool = false,
    operation_gate: std.Io.Mutex = .init,
    stopping: std.atomic.Value(bool) = .init(false),

    fn registerOne(box: *Box) netlayer.RawConnectionDialOutcome(*RelayStream) {
        const hex = box.public_key.toDesignator();
        return openLegOutcome(
            box.carrier,
            box.allocator,
            box.register_url.openRequest(.register, hex[0..]),
            &box.stopping,
        );
    }

    fn noteRepairFailure(box: *Box, later: foundation.FailureChain) void {
        box.repair_failure_mutex.lock();
        defer box.repair_failure_mutex.unlock();
        if (box.repair_failure) |*failure| failure.noteChain(later) else box.repair_failure = later;
    }

    pub fn claimRepairFailure(box: *Box) ?foundation.FailureChain {
        box.repair_failure_mutex.lock();
        defer box.repair_failure_mutex.unlock();
        const failure = box.repair_failure;
        box.repair_failure = null;
        return failure;
    }

    fn startRegistration(box: *Box) error{ Closing, ConcurrencyUnavailable }!void {
        std.debug.assert(!box.registration_active);
        box.registration.reset(box.listener_established);
        box.registration_active = true;
        box.registrations.start(RegisterJob.run, .{&box.registration}) catch |err| {
            box.registration_active = false;
            return err;
        };
    }

    /// Publish a finished registration task into `ready`. Called under
    /// `operation_gate`; the acquire pairs with the task's release store.
    fn collectRegistration(box: *Box) netlayer.AcceptError!void {
        if (!box.registration_active or !box.registration.done.load(.acquire)) return;
        box.registration_active = false;
        if (box.registration.err != null) return error.ConnectionLost;
        box.ready = box.registration.result orelse return error.ConnectionLost;
        box.registration.result = null;
        box.listener_established = true;
        // The relay spent this registration when it paired the socket with a
        // dialer. It is acceptable now, but no longer a cold-dial route.
    }
};

const RegisterJob = struct {
    box: *Box,
    result: ?*RelayStream = null,
    err: ?netlayer.DialError = null,
    /// The first WebSocket registration upgrade completed. Construction is
    /// monotonic after this edge even while the task repairs a transient leg.
    established: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),

    retry_initial_failure: bool = false,

    fn reset(job: *RegisterJob, retry_initial_failure: bool) void {
        job.result = null;
        job.err = null;
        job.retry_initial_failure = retry_initial_failure;
        job.established.store(false, .monotonic);
        job.done.store(false, .monotonic);
    }

    fn run(job: *RegisterJob) std.Io.Cancelable!void {
        const wake = job.box.wake;
        const wake_failure = &job.box.wake_failure;
        defer {
            job.done.store(true, .release);
            // The acquire-side collector may reset and resubmit `job` as soon
            // as `done` is visible. This worker must not touch the reusable
            // record after the release store; `wake` is the local copy captured
            // above, and nudging it afterward prevents a lost completion wake.
            _ = wake.nudge() catch |err| wake_failure.record(err);
        }
        var has_registered = job.retry_initial_failure;
        while (true) {
            const rs = switch (job.box.registerOne()) {
                .connected => |stream| stream,
                .failed => |failure| {
                    // Listener close interrupts a connect/upgrade in progress.
                    // That refusal is the requested teardown working, not a
                    // background repair failure for the close barrier to
                    // report back to its caller.
                    if (job.box.stopping.load(.acquire)) return;
                    job.box.noteRepairFailure(failure.chain);
                    if (!has_registered) {
                        job.err = failure.classification;
                        return;
                    }
                    try std.Io.checkCancel(job.box.carrier.io());
                    try std.Io.sleep(
                        job.box.carrier.io(),
                        std.Io.Duration.fromMilliseconds(registration_retry_delay_ms),
                        .real,
                    );
                    continue;
                },
            };
            has_registered = true;
            if (!job.established.swap(true, .release))
                _ = wake.nudge() catch |err| wake_failure.record(err);

            var frame_failed = false;
            const has_data = rs.nextDataFrame() catch |err| blk: {
                if (job.box.stopping.load(.acquire)) {
                    // The stop owner requested this cancellation and joins the
                    // worker below; it is completion, not a listener failure.
                    _ = rs.destroy();
                    return;
                }
                job.box.noteRepairFailure(rs.takeFailure() orelse .init(err));
                frame_failed = true;
                break :blk false;
            };
            if (has_data) {
                job.result = rs;
                return;
            }

            if (rs.destroy()) |failure| job.box.noteRepairFailure(failure);
            if (job.box.stopping.load(.acquire)) return;
            if (!frame_failed) job.box.noteRepairFailure(.init(error.ConnectionLost));
            try std.Io.checkCancel(job.box.carrier.io());
            try std.Io.sleep(
                job.box.carrier.io(),
                std.Io.Duration.fromMilliseconds(registration_retry_delay_ms),
                .real,
            );
        }
    }
};

pub const keyed_vtable: netlayer.Listener.VTable = vtable(.keyed);
pub const noise_vtable: netlayer.Listener.VTable = vtable(.noise);

pub fn vtable(comptime profile: ChannelProfile) netlayer.Listener.VTable {
    return .{
        .transport_name = profile.transportName(),
        .designator_scheme = profile.known().metadata().designator_scheme,
        .sealed_channel = profile.known().metadata().sealed_channel,
        .accept = listenerAcceptOutcome,
        .wait_acceptable = listenerWaitAcceptableOutcome,
        .readiness_fd = listenerReadinessFd,
        .local_locator = netlayer.adaptListenerLocator(listenerLocalLocator),
        .canonicalize_locator = netlayer.adaptListenerCanonicalize(listenerCanonicalizeLocator),
        .close = listenerClose,
    };
}

fn listenerAcceptOutcome(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptOutcome {
    var stream = switch (acceptOutcome(@ptrCast(@alignCast(ctx)), peer.allocator)) {
        .accepted => |value| value,
        .failed => |failure| return .{ .failed = failure },
    };
    const conn = stream.intoConnection(peer, bufs) catch |err| {
        var failure = netlayer.AcceptFailure.init(error.ConnectionLost);
        failure.chain = stream.destroy() orelse .init(err);
        return .{ .failed = failure };
    };
    return .{ .accepted = conn };
}

fn listenerReadinessFd(ctx: *anyopaque) i32 {
    return readinessFd(@ptrCast(@alignCast(ctx)));
}

fn listenerWaitAcceptableOutcome(ctx: *anyopaque, timeout_ms: i32) netlayer.AcceptReadinessOutcome {
    return waitOutcome(@ptrCast(@alignCast(ctx)), timeout_ms, .acceptable);
}

fn listenerLocalLocator(ctx: *anyopaque, allocator: std.mem.Allocator) netlayer.ListenError!model.PeerLocator {
    return localLocator(@ptrCast(@alignCast(ctx)), allocator);
}

fn listenerCanonicalizeLocator(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
) netlayer.ListenError!model.PeerLocator {
    return canonicalizeLocator(@ptrCast(@alignCast(ctx)), allocator, locator);
}

fn listenerClose(ctx: *anyopaque) ?netlayer.ListenerCloseFailure {
    return close(@ptrCast(@alignCast(ctx)));
}

pub const WaitTarget = enum { established, acceptable };

/// The one deadline/poll loop for the listener's two distinct readiness
/// questions. Established means the first registration succeeded; acceptable
/// means a dialer has delivered application bytes and `accept` will not park. The
/// background task owns connect, upgrade, and control-frame I/O; this function
/// owns only the wake descriptor, so zero and finite timeouts are hard bounds.
pub fn wait(box: *Box, timeout_ms: i32, target: WaitTarget) netlayer.AcceptError!bool {
    return switch (waitOutcome(box, timeout_ms, target)) {
        .ready => |ready| ready,
        .failed => |failure| failure.classification,
    };
}

pub fn waitOutcome(box: *Box, timeout_ms: i32, target: WaitTarget) netlayer.AcceptReadinessOutcome {
    box.operation_gate.lockUncancelable(box.carrier.io());
    defer box.operation_gate.unlock(box.carrier.io());
    return waitLockedOutcome(box, timeout_ms, target);
}

pub fn readinessFd(box: *Box) i32 {
    return box.wake.read;
}

pub fn claimFailure(box: *Box) ?foundation.FailureChain {
    return box.claimRepairFailure();
}

pub fn accept(box: *Box, allocator: std.mem.Allocator) netlayer.AcceptError!*RelayStream {
    return switch (acceptOutcome(box, allocator)) {
        .accepted => |stream| stream,
        .failed => |failure| failure.classification,
    };
}

const AcceptStreamOutcome = union(enum) {
    accepted: *RelayStream,
    failed: netlayer.AcceptFailure,
};

pub fn acceptOutcome(box: *Box, allocator: std.mem.Allocator) AcceptStreamOutcome {
    box.operation_gate.lockUncancelable(box.carrier.io());
    defer box.operation_gate.unlock(box.carrier.io());
    switch (waitLockedOutcome(box, -1, .acceptable)) {
        .ready => {},
        .failed => |failure| return .{ .failed = failure },
    }
    var stream = box.ready orelse return .{ .failed = acceptFailure(box, error.ConnectionLost) };
    box.wake.drain() catch |err| {
        box.wake_failure.record(err);
        return .{ .failed = acceptFailure(box, err) };
    };
    box.ready = null;
    box.startRegistration() catch |err| switch (err) {
        error.Closing => {
            var failure = acceptFailure(box, error.ConnectionLost);
            if (stream.destroy()) |cleanup| failure.chain.noteChain(cleanup);
            return .{ .failed = failure };
        },
        error.ConcurrencyUnavailable => box.noteRepairFailure(.init(err)),
    };
    stream = stream.moveToAllocator(allocator) catch |err| {
        var failure = netlayer.AcceptFailure.init(error.OutOfMemory);
        failure.chain = .init(err);
        if (stream.destroy()) |cleanup| failure.chain.noteChain(cleanup);
        return .{ .failed = failure };
    };
    return .{ .accepted = stream };
}

fn waitLockedOutcome(
    box: *Box,
    timeout_ms: i32,
    target: WaitTarget,
) netlayer.AcceptReadinessOutcome {
    const started_at = if (timeout_ms > 0) clock.nowMs(box.carrier.io()) else 0;
    while (true) {
        box.wake_failure.check() catch |err| return .{ .failed = acceptFailure(box, err) };
        if (box.stopping.load(.acquire))
            return .{ .failed = acceptFailure(box, error.ConnectionLost) };

        // A cached arrival retains its readable token until accept claims it.
        if (box.ready != null) return .{ .ready = true };
        box.wake.drain() catch |err| {
            box.wake_failure.record(err);
            return .{ .failed = acceptFailure(box, err) };
        };
        box.collectRegistration() catch |err| return .{ .failed = acceptFailure(box, err) };

        if (box.ready != null) {
            _ = box.wake.nudge() catch |err| {
                box.wake_failure.record(err);
                return .{ .failed = acceptFailure(box, err) };
            };
            return .{ .ready = true };
        }

        if (target == .established and
            box.registration_active and box.registration.established.load(.acquire))
        {
            box.listener_established = true;
            return .{ .ready = true };
        }

        if (!box.registration_active)
            return .{ .failed = acceptFailure(box, error.ConnectionLost) };

        if (timeout_ms == 0) return .{ .ready = false };

        const remaining: i32 = if (timeout_ms <= 0)
            listener_poll_slice_ms
        else blk: {
            const elapsed = clock.nowMs(box.carrier.io()) - started_at;
            if (elapsed >= timeout_ms) return .{ .ready = false };
            break :blk @intCast(@as(i64, timeout_ms) - elapsed);
        };
        const poll_timeout = @min(remaining, listener_poll_slice_ms);

        std.Io.checkCancel(box.carrier.io()) catch
            return .{ .failed = acceptFailure(box, error.ConnectionLost) };
        var fds = [_]std.posix.pollfd{.{
            .fd = box.wake.read,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = poll.wait(&fds, poll_timeout) catch |err| {
            box.noteRepairFailure(.init(err));
            return .{ .failed = acceptFailure(box, error.ConnectionLost) };
        };
        if (ready == 0 and
            timeout_ms > 0 and clock.nowMs(box.carrier.io()) - started_at >= timeout_ms)
            return .{ .ready = false };
    }
}

fn acceptFailure(box: *Box, fallback: netlayer.AcceptError) netlayer.AcceptFailure {
    return .fromChain(
        fallback,
        box.claimRepairFailure() orelse foundation.FailureChain.init(fallback),
    );
}

/// The dialable designator is the registered identity key's canonical hex.
/// The locator describes the stable route the listener repairs; it is not a
/// reachability probe for the current registration leg.
pub fn localLocator(box: *Box, allocator: std.mem.Allocator) netlayer.ListenError!model.PeerLocator {
    if (box.stopping.load(.acquire)) return error.BindFailed;
    const hex = box.public_key.toDesignator();
    const hints = [_]model.HintEntry{.{
        .name = route.rendezvous_relay_hint,
        .value = .{ .string = box.relay_url_storage },
    }};
    return model.clonePeerLocator(allocator, .{
        .transport = box.profile.transportName(),
        .designator = &hex,
        .hints = .{ .entries = &hints },
    });
}

pub fn canonicalizeLocator(
    box: *Box,
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
) netlayer.ListenError!model.PeerLocator {
    const designator = box.public_key.toDesignator();
    return netlayer.canonicalizeFixedLocator(
        allocator,
        locator,
        box.profile.transportName(),
        &designator,
    );
}

pub fn close(box: *Box) ?netlayer.ListenerCloseFailure {
    box.stopping.store(true, .release);
    _ = box.wake.nudge() catch |err| box.wake_failure.record(err);
    box.registrations.shutdown();
    box.operation_gate.lockUncancelable(box.carrier.io());
    box.operation_gate.unlock(box.carrier.io());
    box.registrations.join();
    var failure = box.claimRepairFailure();
    if (box.ready) |rs| if (rs.destroy()) |cleanup| {
        if (failure) |*primary| primary.noteChain(cleanup) else failure = cleanup;
    };
    if (box.registration.result) |rs| if (rs.destroy()) |cleanup| {
        if (failure) |*primary| primary.noteChain(cleanup) else failure = cleanup;
    };
    box.wake.deinit();
    box.allocator.free(box.register_url_storage);
    box.allocator.free(box.relay_url_storage);
    if (box.wake_failure.failure()) |err| {
        if (failure) |*primary| primary.note(err) else failure = .init(err);
    }
    const allocator = box.allocator;
    var carrier = box.carrier;
    allocator.destroy(box);
    if (carrier.releaseOutcome()) |cleanup| {
        if (failure) |*primary| primary.noteChain(cleanup) else failure = cleanup;
    }
    return failure;
}
