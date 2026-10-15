//! A Tor daemon an interop driver starts, owns, and takes down again.
//!
//! It exists so the live onion checks are one command rather than a setup
//! procedure: each run gets a private data directory under the system temporary
//! directory, and the whole tree goes away on the way out. The daemon listens
//! twice over: on Unix sockets inside that directory for the Goblins onion
//! netlayer, which speaks only to socket paths, and on loopback TCP ports Tor
//! picks for glowcap's stream stack, which dials Tor as a platform address.
//!
//! This is harness code, not a product path. The transport itself starts,
//! supervises, and configures nothing, which is why `onion.Config` names where a
//! daemon already listens rather than describing one to launch.

const std = @import("std");

const wait = @import("support_wait");

/// How long to wait for Tor to reach `Bootstrapped 100%`.
const bootstrap_budget_ms = 120_000;

/// How the daemon should be configured for the peers that will drive it.
pub const Options = struct {
    /// Whether the control endpoint demands the cookie file's bytes.
    ///
    /// It is a choice rather than a default because the two peers differ: glowcap
    /// sends a cookie or a password, and the onion netlayer upstream Goblins
    /// ships sends a bare `AUTHENTICATE`. A check with a Goblins vat in it has to
    /// take the narrower of the two.
    cookie_authentication: bool,
};

/// A Tor daemon a driver owns for the length of its run.
pub const Tor = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    dir: []u8,
    /// The Unix socket forms, for the Goblins netlayer.
    socks_path: []u8,
    control_path: []u8,
    /// The `127.0.0.1:<port>` forms, for `driver.Transports.onion`.
    socks_tcp: []u8,
    control_tcp: []u8,
    log_path: []u8,
    cookie_bytes: []u8,

    pub fn start(gpa: std.mem.Allocator, io: std.Io, options: Options) !Tor {
        // A private data directory per run, so a stale one cannot make a failure
        // look like a success or the other way round.
        var seed: [8]u8 = undefined;
        try io.randomSecure(&seed);
        const dir = try std.fmt.allocPrint(gpa, "/tmp/glowcap-onion-{x}", .{&seed});
        errdefer gpa.free(dir);
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, dir);
        // Tor refuses to put a socket in a directory anyone but its own user can
        // list, so this is a precondition rather than tidiness.
        try cwd.setFilePermissions(io, dir, .fromMode(0o700), .{});

        const socks_path = try std.fmt.allocPrint(gpa, "{s}/socks", .{dir});
        errdefer gpa.free(socks_path);
        const control_path = try std.fmt.allocPrint(gpa, "{s}/control", .{dir});
        errdefer gpa.free(control_path);
        const log_path = try std.fmt.allocPrint(gpa, "{s}/tor.log", .{dir});
        errdefer gpa.free(log_path);

        const socks_arg = try std.fmt.allocPrint(gpa, "unix:{s}", .{socks_path});
        defer gpa.free(socks_arg);
        const control_arg = try std.fmt.allocPrint(gpa, "unix:{s}", .{control_path});
        defer gpa.free(control_arg);
        const log_arg = try std.fmt.allocPrint(gpa, "notice file {s}", .{log_path});
        defer gpa.free(log_arg);

        const child = try std.process.spawn(io, .{
            .argv = &.{
                "tor",
                "--DataDirectory",
                dir,
                "--SocksPort",
                socks_arg,
                "--SocksPort",
                "auto",
                "--ControlPort",
                control_arg,
                "--ControlPort",
                "auto",
                "--CookieAuthentication",
                if (options.cookie_authentication) "1" else "0",
                "--Log",
                log_arg,
            },
            .stdout = .ignore,
            .stderr = .ignore,
        });

        var self: Tor = .{
            .gpa = gpa,
            .io = io,
            .child = child,
            .dir = dir,
            .socks_path = socks_path,
            .control_path = control_path,
            .socks_tcp = &.{},
            .control_tcp = &.{},
            .log_path = log_path,
            .cookie_bytes = &.{},
        };
        errdefer self.child.kill(io);

        try self.awaitBootstrap();
        self.socks_tcp = try self.readListenerPort("Socks");
        errdefer gpa.free(self.socks_tcp);
        self.control_tcp = try self.readListenerPort("Control");
        errdefer gpa.free(self.control_tcp);
        // Only when it was asked for: an unauthenticated daemon writes no cookie
        // file at all, so reading one unconditionally would fail the start.
        if (options.cookie_authentication) self.cookie_bytes = try self.readCookie();
        return self;
    }

    /// Poll the log until Tor reports a finished bootstrap.
    ///
    /// The log rather than the control port, because the control port is exactly
    /// what glowcap's own client speaks and this wait must not depend on the code
    /// under test.
    fn awaitBootstrap(self: *Tor) !void {
        const deadline = wait.deadlineAfter(self.io, bootstrap_budget_ms);
        while (true) {
            if (std.Io.Dir.cwd().readFileAlloc(self.io, self.log_path, self.gpa, .limited(1 << 20))) |text| {
                defer self.gpa.free(text);
                if (std.mem.indexOf(u8, text, "Bootstrapped 100%") != null) return;
                if (std.mem.indexOf(u8, text, "[err]")) |at| {
                    const line_end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
                    std.debug.print("tor: {s}\n", .{text[at..line_end]});
                    return error.TorFailed;
                }
            } else |_| {
                // tolerant: Tor creates its log after launch, so an unreadable log is retried on the next poll until the bootstrap deadline below.
            }
            if (wait.expired(self.io, deadline)) return error.TorBootstrapTimedOut;
            try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(250), .real);
        }
    }

    /// The loopback port Tor chose for the `auto` listener of `kind` (`Socks`
    /// or `Control`), as `127.0.0.1:<port>`. Tor reports each chosen port on
    /// one notice line, so it is read from the same log the bootstrap wait
    /// reads.
    fn readListenerPort(self: *Tor, comptime kind: []const u8) ![]u8 {
        const text = try std.Io.Dir.cwd().readFileAlloc(self.io, self.log_path, self.gpa, .limited(1 << 20));
        defer self.gpa.free(text);
        const marker = kind ++ " listener listening on port ";
        const at = std.mem.indexOf(u8, text, marker) orelse return error.TorListenerPortMissing;
        const digits_at = at + marker.len;
        const digits_end = std.mem.indexOfScalarPos(u8, text, digits_at, '.') orelse return error.TorListenerPortMissing;
        const port = std.fmt.parseInt(u16, text[digits_at..digits_end], 10) catch return error.TorListenerPortMissing;
        return std.fmt.allocPrint(self.gpa, "127.0.0.1:{d}", .{port});
    }

    /// The control cookie Tor wrote, read only when `Options.cookie_authentication`
    /// asked for one.
    fn readCookie(self: *Tor) ![]u8 {
        const path = try std.fmt.allocPrint(self.gpa, "{s}/control_auth_cookie", .{self.dir});
        defer self.gpa.free(path);
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(4096));
    }

    /// The cookie bytes for `onion.Config.auth`, empty when the daemon was
    /// started unauthenticated.
    pub fn cookie(self: *const Tor) []const u8 {
        return self.cookie_bytes;
    }

    pub fn stop(self: *Tor) void {
        self.child.kill(self.io);
        // best-effort: a data directory that cannot be removed stays behind in the run's scratch location and holds no live process.
        std.Io.Dir.cwd().deleteTree(self.io, self.dir) catch {};
        self.gpa.free(self.cookie_bytes);
        self.gpa.free(self.log_path);
        self.gpa.free(self.control_tcp);
        self.gpa.free(self.socks_tcp);
        self.gpa.free(self.control_path);
        self.gpa.free(self.socks_path);
        self.gpa.free(self.dir);
    }
};
