//! Shared process context for CLI / REPL / MCP fronts.
const std = @import("std");
const pancake = @import("pancake");
const identity_mod = @import("operability/identity.zig");
const state_lock = @import("operability/state_lock.zig");

const crypto = pancake.foundation.crypto;
const Session = pancake.driver.Session;
const Io = std.Io;

pub const JsonMode = enum { human, json };

/// Which product front owns this process context.
pub const Front = enum { argv, repl, mcp };

/// Where CapTP verb results go (never inferred from a nullable buffer pointer).
pub const Sink = union(enum) {
    stdout,
    buffer: *std.ArrayList(u8),
};

pub const Ctx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    front: Front = .argv,
    sink: Sink = .stdout,
    json: JsonMode = .human,
    identity_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    identity_path: []const u8 = "",
    secret: ?crypto.SecretKey = null,
    /// Live session for REPL / MCP multi-command context.
    /// The dial transports a retained session keeps reaching through. The
    /// session's host resolves later dials against this slice — a redeem
    /// reaches an exporter this way (ADR-0090) — so the residents and the
    /// slice storage must outlive the session, not the dialing frame. Slot 0
    /// is always tcp; slots 1 and 2 join when `PANCAKE_RENDEZVOUS` configures
    /// the relay provider's clear and sealed rendezvous profiles.
    dial_resident: pancake.net.tcp.Resident = undefined,
    rendezvous_provider: ?pancake.net.relay.Provider = null,
    dial_netlayers: [3]pancake.net.netlayer.Netlayer = undefined,
    session: ?*Session = null,
    /// The non-argv fronts' background listener (`listen` on MCP or the
    /// REPL), or null. One per context; `close` and `deinit` stop it.
    background_listener: ?*@import("ocapn/listen_background.zig").Handle = null,
    /// Last listen locator minted in this process (owned).
    last_locator: ?[]const u8 = null,
    /// Exclusive identity/state lock; held while this process owns CapTP identity.
    state_guard: ?state_lock.Guard = null,
    /// Borrowed argv `std.process.Init` for leaves that need the full process handle (rooms-peer).
    argv_init: ?*const std.process.Init = null,

    fn statePosture(self: *const Ctx) @import("operability/xdg.zig").StatePosture {
        return if (self.front == .mcp) .mcp_local else .product;
    }

    pub fn resolveIdentityPath(self: *Ctx) !void {
        self.identity_path = try identity_mod.defaultIdentityPath(self.io, &self.identity_path_buf, self.environ, self.statePosture());
    }

    /// Path used by `pancake init` (XDG state / overrides; never legacy config).
    pub fn resolveMintIdentityPath(self: *Ctx) !void {
        self.identity_path = try identity_mod.mintIdentityPath(&self.identity_path_buf, self.environ, self.statePosture());
    }

    /// Acquire the product identity/state lock once (non-blocking). Idempotent.
    pub fn ensureStateLock(self: *Ctx) !void {
        if (self.state_guard != null) return;
        if (self.identity_path.len == 0) try self.resolveIdentityPath();
        self.state_guard = try state_lock.tryAcquireForIdentity(self.io, self.identity_path);
    }

    pub fn ensureSecret(self: *Ctx) !crypto.SecretKey {
        if (self.secret) |s| return s;
        try self.ensureStateLock();
        if (self.identity_path.len == 0) try self.resolveIdentityPath();
        const s = try identity_mod.loadOrMint(self.io, self.identity_path);
        self.secret = s;
        return s;
    }

    /// CapTP session signing posture from the product identity file.
    pub fn dialIdentity(self: *Ctx) !pancake.driver.Identity {
        const secret = try self.ensureSecret();
        return .{ .keyed = .{
            .secret = secret,
            .designator = pancake.driver.unreachable_client_designator,
        } };
    }

    pub fn acceptIdentity(self: *Ctx) !pancake.driver.AcceptIdentity {
        return .{ .keyed = try self.ensureSecret() };
    }

    pub fn writeResult(self: *Ctx, bytes: []const u8) !void {
        switch (self.sink) {
            // One authority for product stdout: `argv.writeStdout` owns the
            // choice between the process stream and the test capture.
            .stdout => try @import("argv.zig").writeStdout(self.io, bytes),
            .buffer => |cap| try cap.appendSlice(self.gpa, bytes),
        }
    }

    /// Product log line for CapTP verbs. Honors the lab divert when the TUI
    /// alt-screen is active (see `operability/log.setDivert`); else stderr.
    pub fn logInfo(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        const log = @import("operability/log.zig");
        log.info(self.io, fmt, args);
    }

    pub fn logErr(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        const log = @import("operability/log.zig");
        log.err(self.io, fmt, args);
        // MCP/REPL capture sinks: also emit a `--json` failure body so tools/call
        // text is never blank on isError. Skip `.stdout` — Zig's test runner owns
        // stdout via `--listen=-`, and argv `--json` keeps failures on stderr today.
        if (self.json != .json) return;
        const cap = switch (self.sink) {
            .buffer => |b| b,
            .stdout => return,
        };
        var msg_buf: [512]u8 = undefined;
        const msg = log.renderBounded(&msg_buf, fmt, args);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        body.appendSlice(self.gpa, "{\"ok\":false,\"error\":") catch return;
        @import("argv.zig").writeJsonString(&body, self.gpa, msg) catch return;
        body.appendSlice(self.gpa, "}\n") catch return;
        cap.appendSlice(self.gpa, body.items) catch {};
    }

    pub fn closeSession(self: *Ctx) void {
        if (self.session) |s| {
            s.deinit();
            self.session = null;
        }
        if (self.rendezvous_provider) |*provider| {
            provider.deinit();
            self.rendezvous_provider = null;
        }
    }

    /// Stop the background listener's accept thread and free it. Idempotent.
    pub fn closeBackgroundListener(self: *Ctx) void {
        if (self.background_listener) |handle| {
            handle.shutdown();
            self.background_listener = null;
        }
    }

    pub fn deinit(self: *Ctx) void {
        self.closeBackgroundListener();
        self.closeSession();
        if (self.last_locator) |loc| {
            self.gpa.free(loc);
            self.last_locator = null;
        }
        if (self.state_guard) |*g| {
            g.deinit();
            self.state_guard = null;
        }
    }
};
