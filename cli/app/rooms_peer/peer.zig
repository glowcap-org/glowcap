//! Peer daemon: CapTP/iroh room presence loop for `pancake app rooms-peer`.
const std = @import("std");
const iroh = @import("iroh");
const rooms_profile = @import("rooms_profile");
const signals = @import("../../operability/signals.zig");
const identity_mod = @import("../../operability/identity.zig");
const log = @import("../../operability/log.zig");
const common = @import("common.zig");
const harness = @import("harness.zig");
const phase_mod = @import("phase.zig");
const Flags = @import("flags.zig").Flags;
const st = @import("state.zig");
const wire = @import("wire.zig");
const outbox = @import("outbox.zig");

const Io = common.Io;
const Allocator = common.Allocator;
const model = common.model;
const driver = common.driver;
const net = common.net;
const Host = common.Host;
const RoomsBackend = common.RoomsBackend;
const RoomsLoop = common.RoomsLoop;
const RoomsBridge = common.RoomsBridge;
const frame_cap = common.frame_cap;
const timer_ms = common.timer_ms;
const redial_cooldown_wakes = common.redial_cooldown_wakes;
const dial_timeout_ms = common.dial_timeout_ms;
const readFile = harness.readFile;
const overwriteFile = harness.overwriteFile;
const removeFile = harness.removeFile;
const writeState = harness.writeState;
const loadOutboxOffset = harness.loadOutboxOffset;
const clampOutboxOffset = harness.clampOutboxOffset;
const advanceInboxWatermark = harness.advanceInboxWatermark;

const PeerState = st.PeerState;

// --- loop maintenance -------------------------------------------------------

fn maintain(state: *PeerState) void {
    switch (state.phase) {
        // Join failed under a live session: close the slot so we are not stuck
        // open-but-unjoined with no redial. This arm clears PeerState before
        // any deferred onClose lands, so a late close finds `.down` and no-ops
        // instead of racing a half-cleared state. The redial then waits out
        // the ordinary cooldown: a room that keeps refusing the join backs off
        // like a down room, it does not become a per-tick dial storm.
        .abandoning => |session| {
            state.bridge.closeConn(session.peer_handle);
            state.clearRoomWire();
            state.phase = .{ .down = .{ .cooldown = redial_cooldown_wakes } };
            state.join_attempts += 1;
        },
        // Back off between redials so a down room is retried steadily, not
        // thrashed every wake tick.
        .down => |*down| {
            if (!phase_mod.tickCooldown(&down.cooldown)) return;
            if (PeerState.stopRequested()) return;
            state.bridge.dialOutboundReserved(state.room_locator) catch |err| {
                log.err(state.io, "redial failed: {s}", .{@errorName(err)});
                state.writeStateNow("reconnecting");
                state.phase = .{ .down = .{ .cooldown = redial_cooldown_wakes } };
                return;
            };
            state.writeStateNow("reconnecting");
            state.phase = .{ .dialing = .{ .cooldown = redial_cooldown_wakes } };
        },
        // Connect in flight: keep the countdown running so a refused connect
        // resumes pacing in `.down` (onClose carries it over). Direct legs
        // share this completion loop and need no second pump.
        .dialing => |*dialing| {
            _ = phase_mod.tickCooldown(&dialing.cooldown);
        },
        .joining => |*joining| {
            if (phase_mod.joinDeadlineFires(joining, common.join_deadline_wakes)) {
                log.err(state.io, "join did not complete within the deadline; abandoning", .{});
                state.requestAbandonJoin();
                return;
            }
            // Always flush outside the callback latch so join-path
            // ReenteredHost deferrals (subscribe/register) still armOutbound.
            _ = st.flushBridge(state, .maintain);
        },
        .joined => |*joined| {
            switch (joined.reg) {
                .pending => |*cooldown| {
                    if (phase_mod.tickCooldown(cooldown)) {
                        wire.registerWithDirectory(state);
                        // Re-arm the retry countdown; the phase cannot have
                        // left `.joined` inside registerWithDirectory, but
                        // re-check rather than write through a stale capture.
                        if (state.phase == .joined and state.phase.joined.reg == .pending) {
                            state.phase.joined.reg = .{ .pending = redial_cooldown_wakes };
                        }
                    }
                },
                .registered => {},
            }
            outbox.tickPendingIntroduces(state);
            outbox.tickFailedIntroduces(state);
            wire.drainPendingInboxOffers(state);
            outbox.drainOutbox(state);
            _ = st.flushBridge(state, .maintain);
        },
    }
}

/// Sleep up to `total_ms`, waking promptly on a stop. A `Threaded` sleep
/// swallows the SIGTERM `EINTR` and re-waits, so one long sleep is signal-deaf;
/// chunking it at the tick cadence lets the supervisor observe the shared stop
/// latch during a reconnect backoff instead of parking past `stop`'s SIGTERM grace.
fn sleepUntilStop(io: Io, total_ms: i64) void {
    var slept: i64 = 0;
    while (slept < total_ms and !PeerState.stopRequested()) {
        const chunk = @min(@as(i64, @intCast(timer_ms)), total_ms - slept);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(chunk), .real) catch {};
        slept += chunk;
    }
}

// --- peer daemon entry ------------------------------------------------------

/// Treat current inbox scrollback as already answered without stuffing
/// replied.json (which caps and can resurface ancient ids after restart).
fn seedRepliedBacklog(io: Io, gpa: Allocator, dir: []const u8, nick: []const u8) void {
    _ = nick;
    advanceInboxWatermark(io, gpa, dir);
}

pub fn runPeer(init: std.process.Init, flags: Flags) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (init.environ_map.get("PANCAKE_ROOMS_PEER_SUPERVISED") == null) {
        log.err(io, "`peer` is the internal daemon — start it with: pancake app rooms-peer start --dir <DIR> --nick <NICK>", .{});
        return error.Unsupervised;
    }
    if (flags.dir.len == 0 or flags.nick.len == 0 or flags.locator.len == 0) return error.MissingFlags;

    // Detach into our own session so a reaped launcher shell cannot SIGHUP us.
    _ = std.os.linux.setsid();
    signals.install();

    Io.Dir.cwd().createDirPath(io, flags.dir) catch {};
    var pid_buf: [24]u8 = undefined;
    const pid_text = std.fmt.bufPrint(&pid_buf, "{d}\n", .{std.os.linux.getpid()}) catch "0\n";
    overwriteFile(io, flags.dir, "peer.pid", pid_text) catch {};
    // Mark the existing scrollback answered once, so a restart never re-answers
    // lines from before we joined.
    seedRepliedBacklog(io, gpa, flags.dir, flags.nick);

    // Honor the persisted already-sent mark; the drain compacts only past it.
    // Never seed to EOF: that skipped undrained lines written while the peer
    // was down or wedged before tell.
    const outbox_bytes = readFile(io, gpa, flags.dir, "outbox.jsonl") catch try gpa.dupe(u8, "");
    defer gpa.free(outbox_bytes);
    st.g_offset = clampOutboxOffset(loadOutboxOffset(io, gpa, flags.dir), outbox_bytes.len);

    // Supervisor. Keep a functional iroh stack up until a stop signal. A
    // connection drop is recovered inside runStack (maintain redials in place); a
    // fatal loop error — the endpoint or backend itself failing — returns out of
    // runStack, and we build a fresh stack and reconnect. Each rebuild re-resolves
    // an `http(s)://…/locator` bootstrap so a reminted room node id is followed
    // instead of hammering a dead `ocapn://`. Back off when the environment stays
    // broken, and snap back to a fast retry once a stack has actually joined.
    // Only a stop signal ends the daemon.
    var backoff_ms: i64 = 500;
    defer signals.requestStop();
    while (!PeerState.stopRequested()) {
        st.g_ever_joined = false;
        const dial_target = common.resolveLocator(io, gpa, flags.locator) catch |err| {
            log.err(io, "locator resolve failed: {s}; retrying", .{@errorName(err)});
            writeState(io, gpa, flags.dir, "reconnecting", flags.nick, flags.room, flags.locator, false, 0);
            sleepUntilStop(io, backoff_ms);
            backoff_ms = @min(backoff_ms * 2, 30_000);
            continue;
        };
        defer gpa.free(dial_target);
        const loc = model.uri.parsePeer(gpa, dial_target) catch |err| {
            log.err(io, "locator parse failed: {s}; retrying", .{@errorName(err)});
            writeState(io, gpa, flags.dir, "reconnecting", flags.nick, flags.room, flags.locator, false, 0);
            sleepUntilStop(io, backoff_ms);
            backoff_ms = @min(backoff_ms * 2, 30_000);
            continue;
        };
        defer model.freePeerLocator(gpa, loc);
        if (!std.mem.eql(u8, loc.transport, model.transport.iroh)) {
            log.err(io, "locator is not iroh; refusing", .{});
            return error.NotIroh;
        }
        const hint = net.netlayer.directAddrHint(loc.hints) orelse "";
        const reachability: iroh.Reachability = if (hint.len > 0) .direct else .discovery;
        const rendezvous_url = common.resolveRendezvousUrl(gpa, init.environ_map.get("PANCAKE_RENDEZVOUS"), flags.locator) catch |err| {
            log.err(io, "rendezvous URL refused: {s}", .{@errorName(err)});
            return err;
        };
        defer if (rendezvous_url) |u| gpa.free(u);
        runStack(io, gpa, flags, loc, reachability, dial_target, rendezvous_url) catch |err| {
            log.err(io, "iroh stack failed: {s}; rebuilding", .{@errorName(err)});
        };
        if (PeerState.stopRequested()) break;
        writeState(io, gpa, flags.dir, "reconnecting", flags.nick, flags.room, dial_target, false, 0);
        sleepUntilStop(io, backoff_ms);
        backoff_ms = if (st.g_ever_joined) 500 else @min(backoff_ms * 2, 30_000);
    }

    writeState(io, gpa, flags.dir, "closed", flags.nick, flags.room, flags.locator, false, 0);
    removeFile(io, flags.dir, "peer.pid");
}

/// Resolve the CapTP Host seed: `--identity PATH`, else `DIR/identity` (minted
/// if missing), so presence is stable across restart under the same harness dir.
fn hostSeed(io: Io, dir: []const u8, identity_flag: []const u8) ![32]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path: []const u8 = if (identity_flag.len > 0)
        identity_flag
    else
        try std.fmt.bufPrint(&path_buf, "{s}/identity", .{dir});
    const secret = try identity_mod.loadOrMint(io, path);
    return secret.seed();
}

/// Wait until the endpoint reports at least one direct address, or until
/// `budget_ms` elapses.
fn directAddrsReady(io: Io, resident: *iroh.Resident, out: []u8, budget_ms: i64) bool {
    var slept: i64 = 0;
    while (slept <= budget_ms) {
        if (resident.directAddrs(out)) |result| {
            switch (result) {
                .written => |addrs| if (addrs.len > 0) return true,
                .too_small => return true,
            }
        } else |_| {}
        if (slept == budget_ms) break;
        const chunk = @min(@as(i64, 50), budget_ms - slept);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(chunk), .real) catch {};
        slept += chunk;
    }
    return false;
}

/// Build a fresh iroh stack (endpoint, host, bridge, completion loop), dial the
/// room, and run the loop. Returns normally when a stop is requested, or returns
/// the error when the loop fails fatally so the supervisor can rebuild. A
/// per-connection drop is recovered here without a rebuild: `on_close` nulls the
/// session and `maintain` redials it.
fn runStack(
    io: Io,
    gpa: Allocator,
    flags: Flags,
    loc: model.PeerLocator,
    reachability: iroh.Reachability,
    dial_target: []const u8,
    rendezvous_url: ?[]const u8,
) !void {
    // Key unification: the CapTP Host and the iroh endpoint share one seed so
    // accepted hellos (redeem dials) sign the dialed node id.
    const seed = try hostSeed(io, flags.dir, flags.identity);
    var resident = try iroh.Resident.init(io, &seed, .{
        .reachability = reachability,
        .connect_timeout_ms = dial_timeout_ms,
    });
    defer resident.deinit() catch |err| log.err(io, "iroh teardown failed: {s}", .{@errorName(err)});

    var id_buf: [iroh.node_id_len]u8 = undefined;
    const node_id = resident.nodeId(&id_buf);
    if (node_id.len == 0) {
        log.err(io, "iroh endpoint has no node id", .{});
        return error.NoNodeId;
    }

    // Direct demos stamp address hints on the registered locator so a redeem
    // dial reaches the member without Discovery. Discovery peers advertise a
    // bare node id — the same shape `serve.ts` uses for browser DM members — so
    // redeem uses Discovery rather than private container/LAN binds the public
    // recipient cannot reach.
    var owned_addrs: ?[]u8 = null;
    defer if (owned_addrs) |addrs| gpa.free(addrs);
    const addrs: []const u8 = if (reachability == .direct) blk: {
        var addrs_buf: [512]u8 = undefined;
        if (!directAddrsReady(io, &resident, &addrs_buf, 5_000)) break :blk "";
        owned_addrs = resident.directAddrsOwned(gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SidecarFailed, error.AddressListTooLarge => {
                log.err(io, "iroh endpoint direct-address snapshot failed: {s}", .{@errorName(err)});
                return error.NoDirectAddrs;
            },
        };
        break :blk owned_addrs.?;
    } else "";
    if (reachability == .direct and addrs.len == 0) {
        log.err(io, "iroh endpoint has no direct addresses (needed for DM register)", .{});
        return error.NoDirectAddrs;
    }

    var hint_entry: [1]model.HintEntry = undefined;
    const member_hints = model.Hints.forDirectAddresses(addrs, &hint_entry);
    const member_locator = try model.uri.writePeer(gpa, .{
        .transport = iroh.transport_name,
        .designator = node_id,
        .hints = member_hints,
    });
    defer gpa.free(member_locator);

    // The room's profile, not the interop floor: this peer only ever talks to
    // other pancake peers, and the directory it dials offers the same pair.
    var session_root: [32]u8 = undefined;
    io.randomSecure(&session_root) catch return error.HandshakeEntropyFailed;
    var host = try Host.init(gpa, seed, session_root, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = driver.core.default_loop_local_turn_budget,
        .codec = rooms_profile.codec,
        .captp_version = rooms_profile.captp_version,
    });
    defer host.deinit();

    var loop: RoomsLoop = undefined;
    var state = PeerState{
        .io = io,
        .gpa = gpa,
        .host = &host,
        .bridge = undefined,
        .dir = flags.dir,
        .nick = flags.nick,
        .room_name = flags.room,
        .locator_str = dial_target,
        .member_locator = member_locator,
        .room_locator = loc,
    };
    defer state.deinitTables();
    // No per-session publish hook: an inbox belongs to one named peer, and the
    // host's giftable registry already puts each on every connection, including
    // the ones a redeem opens later.
    var bridge = RoomsBridge.init(gpa, &host, io, &loop, .{
        .on_open = wire.onOpen,
        .on_open_ctx = &state,
    });
    defer bridge.deinit();
    state.bridge = &bridge;
    if (rendezvous_url == null) {
        log.err(io, "no relay rendezvous configured (set PANCAKE_RENDEZVOUS or pass an http://host:port/locator); browser DM introduce will fail", .{});
    }

    const read_buffer_bytes: u32 = @intCast(@min(frame_cap, 16 * 1024));
    const relay_platform = if (rendezvous_url) |url| blk: {
        var entropy_seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        try io.randomSecure(&entropy_seed);
        break :blk try net.KeyedRelayBackend.initWithRelay(
            gpa,
            common.completion_queue_entries,
            common.read_buffers,
            read_buffer_bytes,
            .{ .url = url, .entropy_seed = entropy_seed, .resolver_io = io },
        );
    } else try net.KeyedRelayBackend.init(
        gpa,
        common.completion_queue_entries,
        common.read_buffers,
        read_buffer_bytes,
    );
    const identity = common.crypto.SecretKey.fromSeed(seed);
    var noise_seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try io.randomSecure(&noise_seed);
    const platform = net.NoiseRelayBackend.initSealing(
        gpa,
        relay_platform,
        &identity,
        noise_seed,
    );
    const backend = try RoomsBackend.initBoundWithPlatform(gpa, &resident, platform, common.read_buffers, read_buffer_bytes);
    // This peer interposes its own close hook (DM lifecycle bookkeeping), so
    // it overrides the bridge's spliced `on_close` after `hookOptions`.
    var loop_options = RoomsBridge.hookOptions(.{
        .max_conns = common.max_sessions,
        .reserved_dial_conns = common.reserved_room_sessions,
        .listen = 0,
    });
    loop_options.on_close = wire.onClose;
    loop = try RoomsLoop.initWithBackend(gpa, backend, RoomsBridge.makePeer, @ptrCast(&bridge), loop_options);
    defer loop.deinit();

    // Advertise the same locator hellos will claim. After ADR-0109, introduce
    // gifts embed the exporter's signed hello location — not the directory
    // `register` URI — so an empty attach here made every redeem dial hintless
    // (InvalidAddress / iroh DNS spam) even when `member_locator` already
    // carried direct-addresses. Discovery posture leaves `addrs` empty on
    // purpose; Direct must publish the addrs already collected above.
    try bridge.attach(model.transport.Known.iroh.metadata(), node_id, addrs);

    state.phase = .{ .dialing = .{ .cooldown = 0 } };
    bridge.dialOutboundReserved(loc) catch |err| {
        log.err(io, "dial failed: {s}", .{@errorName(err)});
        state.phase = .{ .down = .{ .cooldown = 0 } };
    };

    // The flag deliberately remains false: `runUntil`'s wall-clock deadline is
    // the maintenance timer. One bounded reactor wait replaces the former
    // sleep task, which set a flag but could not wake this poll.
    var maintain_due = std.atomic.Value(bool).init(false);
    while (!PeerState.stopRequested()) {
        loop.runUntil(&maintain_due, timer_ms) catch |err| switch (err) {
            error.Timeout => {},
            else => {
                loop.closeAndDrain() catch {};
                return err;
            },
        };
        maintain(&state);
    }
    loop.closeAndDrain() catch {};
}
