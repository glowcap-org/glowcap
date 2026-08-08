//! The CapTP I/O spine checks: one Bridge, one Loop, one dial contract.
//!
//! The require-groups and structural walks that hold the completion-loop
//! product spine to its settled shape — Backend/Locator dial contracts, the
//! Bridge as the one loop-to-Host seam, per-binding pump convergence needles,
//! and the transport-constant presence rows. The forbid/file-absent half of
//! the same apex lives in `bans.zig` (`captp_io_spine_table`). Wired by the
//! meta-check driver (`tools/check/meta_check.zig`).

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

/// Apex for one CapTP I/O spine. The forbid/file-absent rows live in
/// `meta_check/bans.zig` (`captp_io_spine_table`); this keeps the
/// require-groups and walks: the Backend/Locator dial contracts, the
/// binding spines, and the structural scans.
pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    root.access(io, "src/driver/bridge.zig", .{}) catch {
        try appendViolation(gpa, violations, "src/driver/bridge.zig: file must exist — `driver.Bridge` lives here (not `loop_bridge.zig`)", .{});
    };

    // Every completion Backend must declare the total dial contract.
    // Transport-bound Locators own OCapN resolve; platform Backends are connect-only.
    const backend_paths = [_][]const u8{
        "src/net/transport/iroh.zig",
    };
    const required_dial = [_][]const u8{
        "pub const ConnectTarget",
        "startDial",
        "shutdownFd",
    };
    const platform_paths = [_][]const u8{
        "src/net/completion/uring.zig",
        "src/net/completion/kqueue.zig",
    };
    const required_platform_dial = [_][]const u8{
        "pub const ConnectTarget",
        "startDial",
        "shutdownFd",
    };
    const locator_paths = [_][]const u8{
        "src/net/transport/tcp.zig",
        "src/net/transport/iroh.zig",
    };
    const required_locator = [_][]const u8{
        "pub const DialResolver",
        "pub fn resolve(",
    };
    for (platform_paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for platform dial-contract check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (required_platform_dial) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — platform Backend dial contract", .{ path, needle });
            }
        }
    }
    for (backend_paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for Backend dial-contract check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (required_dial) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — Backend total dial contract", .{ path, needle });
            }
        }
    }
    for (locator_paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for Locator contract check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (required_locator) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — netlayer DialResolver contract", .{ path, needle });
            }
        }
    }

    // kqueue Pending is tagged unions; flaggy `read_is_recv` / `connecting` are deleted.
    // Both readiness backends share `ScratchPool` (no hand-copied pool logic).
    {
        const kq_path = "src/net/completion/kqueue.zig";
        const kq = root.readFileAlloc(io, kq_path, gpa, .limited(2 << 20)) catch |err| blk: {
            try appendViolation(gpa, violations, "{s}: failed to read for Pending/ScratchPool apex check with {s}", .{ kq_path, @errorName(err) });
            break :blk null;
        };
        defer if (kq) |bytes| gpa.free(bytes);
        if (kq) |kq_bytes| {
            for ([_][]const u8{ "read_is_recv", "connecting" }) |needle| {
                if (std.mem.indexOf(u8, kq_bytes, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — kqueue Pending is tagged unions (`read`/`write`), not flaggy fields", .{ kq_path, needle });
                }
            }
        }
        // The iroh Pending dropped its `read_is_recv` flag too (ADR-0057), so
        // hold the flag out of iroh the same way it is held out of kqueue.
        const iroh_path = "src/net/transport/iroh.zig";
        const iroh_src = root.readFileAlloc(io, iroh_path, gpa, .limited(2 << 20)) catch |err| blk: {
            try appendViolation(gpa, violations, "{s}: failed to read for iroh Pending flag check with {s}", .{ iroh_path, @errorName(err) });
            break :blk null;
        };
        defer if (iroh_src) |bytes| gpa.free(bytes);
        if (iroh_src) |bytes| {
            if (std.mem.indexOf(u8, bytes, "read_is_recv") != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `read_is_recv`; iroh Pending distinguishes read from write by its request kind, not a flag (ADR-0057)", .{iroh_path});
            }
        }
        const pool_paths = [_][]const u8{
            "src/net/completion/kqueue.zig",
            "src/net/transport/iroh.zig",
        };
        for (pool_paths) |path| {
            const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for ScratchPool apex check with {s}", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            const has_pool = std.mem.indexOf(u8, contents, "scratch_pool") != null or
                std.mem.indexOf(u8, contents, "ScratchPool") != null;
            if (!has_pool) {
                try appendViolation(gpa, violations, "{s}: missing ScratchPool — readiness backends share `src/net/completion/scratch_pool.zig`", .{path});
            }
        }
    }

    // Platform TCP socket policy (bind/listen/reuseaddr, openSocket, dial sockaddr)
    // lives in `socket_tcp.zig`. Both backends must call it; neither reimplements.
    // A full readiness mixin (`readiness_backend.zig`) is a rejected shape.
    {
        root.access(io, "src/net/completion/socket_tcp.zig", .{}) catch {
            try appendViolation(gpa, violations, "src/net/completion/socket_tcp.zig: file must exist — shared kqueue/uring TCP socket helpers", .{});
        };
        if (root.access(io, "src/net/completion/readiness_backend.zig", .{})) |_| {
            try appendViolation(gpa, violations, "src/net/completion/readiness_backend.zig: file must not exist — rejected readiness mixin; share ScratchPool + socket_tcp only", .{});
        } else |_| {}
        const sock_paths = [_][]const u8{
            "src/net/completion/kqueue.zig",
            "src/net/completion/uring.zig",
        };
        for (sock_paths) |path| {
            const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for socket_tcp share check with {s}", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, "socket_tcp") == null) {
                try appendViolation(gpa, violations, "{s}: missing `socket_tcp` — platform backends share `src/net/completion/socket_tcp.zig`", .{path});
            }
            for ([_][]const u8{ "SO.REUSEADDR", "SO_REUSEADDR", "0x7f00_0001" }) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — loopback bind/listen/reuseaddr lives in socket_tcp.zig", .{ path, needle });
                }
            }
        }
    }

    // `tcp.connectAddress` is post-admission I/O only. Production `src/` dials
    // must go through `Locator.resolve` (or `tcp.connect` / netlayer dial) first;
    // only the tcp transport modules may call connectAddress.
    {
        var src_dir = try root.openDir(io, "src", .{ .iterate = true });
        defer src_dir.close(io);
        var walker = try src_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const rel = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
            defer gpa.free(rel);
            if (std.mem.eql(u8, rel, "src/net/transport/tcp.zig")) continue;
            if (std.mem.eql(u8, rel, "src/net/transport/tcp_keyed.zig")) continue;
            const contents = root.readFileAlloc(io, rel, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for connectAddress ban with {s}", .{ rel, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, "connectAddress") != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `connectAddress` — dial through `Locator.resolve` / `tcp.connect` / netlayer dial; only tcp.zig and tcp_keyed.zig may call the post-admission connect", .{rel});
            }
        }
    }

    // Ghost test/path vocabulary that named the deleted blocking Host tier.
    const ghost_docs = [_][]const u8{
        "docs/shipped.md",
        "docs/boundaries.md",
        "docs/architecture.md",
        "docs/roadmap.md",
        ".agents/rules/architecture.md",
        ".agents/rules/memory.md",
        ".agents/rules/cli.md",
    };
    const ghosts = [_]struct { needle: []const u8, reason: []const u8 }{
        .{
            .needle = "host_three_party_test",
            .reason = "byte-fed three-party is `test/driver/core_host_test.zig`; loop-fed is `test/driver/bridge_test.zig`",
        },
        .{
            .needle = "three real residents",
            .reason = "do not recite a fixed resident count in prose; the roster is `tcp`, `keyed-tcp`, `inproc`, `iroh`, and `webrtc`, pinned per doc by `checkResidentRoster`",
        },
    };
    for (ghost_docs) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch continue;
        defer gpa.free(contents);
        for (ghosts) |ghost| {
            if (std.mem.indexOf(u8, contents, ghost.needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — {s}", .{ path, ghost.needle, ghost.reason });
            }
        }
    }

    // Dead Host.pumped must not return (Bridge uses serveEvent).
    {
        const path = "src/driver/core/host.zig";
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for pumped ban with {s}", .{ path, @errorName(err) });
            return;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "pub fn pumped") != null) {
            try appendViolation(gpa, violations, "{s}: forbidden `pub fn pumped` — use `serveEvent` / `feed` / `feedBytes` only", .{path});
        }
    }

    // Dead BlockingSession.openKeyedSession: connectTcp/connectVia open the
    // session; a tcp-hardcoded parallel hello must not return.
    {
        const path = "src/driver/blocking_session.zig";
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for openKeyedSession ban with {s}", .{ path, @errorName(err) });
            return;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "fn openKeyedSession") != null) {
            try appendViolation(gpa, violations, "{s}: forbidden `openKeyedSession` — session open is `connectVia` / `connectTcp` / `startKeyedSession`", .{path});
        }
        // acceptTcp must stay a thin tcp-named wrapper over acceptVia.
        if (std.mem.indexOf(u8, contents, "pub fn acceptTcp") != null and
            std.mem.indexOf(u8, contents, "acceptVia(") == null)
        {
            try appendViolation(gpa, violations, "{s}: `acceptTcp` must call `acceptVia` — no parallel accept hello path", .{path});
        }
        // connectTcp must stay a thin tcp-named wrapper over connectVia.
        if (std.mem.indexOf(u8, contents, "pub fn connectTcp") != null and
            std.mem.indexOf(u8, contents, "connectVia(") == null)
        {
            try appendViolation(gpa, violations, "{s}: `connectTcp` must call `connectVia` — no parallel dial hello path", .{path});
        }
    }

    // Hint name literal lives only in model.transport; production code aliases.
    {
        var src_dir = try root.openDir(io, "src", .{ .iterate = true });
        defer src_dir.close(io);
        var walker = try src_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const rel = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
            defer gpa.free(rel);
            if (std.mem.eql(u8, rel, "src/ocapn/model/transport.zig")) continue;
            const contents = root.readFileAlloc(io, rel, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for hint-literal ban with {s}", .{ rel, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            // Assignment / compare sites; comments may still name the wire bytes.
            if (std.mem.indexOf(u8, contents, ".name = \"direct-addresses\"") != null or
                std.mem.indexOf(u8, contents, "eql(u8, entry.name, \"direct-addresses\")") != null or
                std.mem.indexOf(u8, contents, "eql(u8, entry.name,\"direct-addresses\")") != null)
            {
                try appendViolation(gpa, violations, "{s}: forbidden `direct-addresses` literal — use `model.transport.hint_direct_addresses` (or vocab/netlayer alias)", .{rel});
            }
        }
    }

    // Binding dial executors resolve `host:port` only in the core: the TS
    // binding delegates the whole dial to the `pancake_host_plan_dial` resolver,
    // the others still split through the `pancake_designator_host_port` grammar
    // wrapper. Either way a local regexp that re-teaches the designator grammar
    // on the dial path is forbidden.
    const dial_host_port = [_]struct {
        path: []const u8,
        required: []const u8,
        banned: []const []const u8,
    }{
        .{
            // The Python dial delegates the whole resolution to the core resolver.
            .path = "bindings/python/pancake/_dial.py",
            .required = "pancake_host_plan_dial",
            .banned = &.{ "re.match(", "rsplit(\":\"", ".rsplit(\":\"" },
        },
        .{
            // The Rust dial delegates the whole resolution to the core resolver.
            .path = "bindings/rust/src/dial.rs",
            .required = "pancake_host_plan_dial",
            .banned = &.{ "rsplit_once(':')", "split_once(':')" },
        },
        .{
            // The TS dial delegates the whole resolution (grammar + hint +
            // posture) to the core, so it requires the resolver, not the split.
            .path = "bindings/ts/stack/dial.ts",
            .required = "pancake_host_plan_dial",
            .banned = &.{ "lastIndexOf(\":\")", "match(/^(.+):([0-9]+)$/)" },
        },
        .{
            // The Racket dial delegates the whole resolution to the core resolver.
            .path = "bindings/racket/private/dial.rkt",
            .required = "pancake_host_plan_dial",
            .banned = &.{"#rx\"^(.+):([0-9]+)$\""},
        },
    };
    for (dial_host_port) |entry| {
        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for dial host:port check with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, entry.required) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — dials must resolve host:port in the core, not a local splitter", .{ entry.path, entry.required });
        }
        for (entry.banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use `{s}` / pancake_designator_host_port, not a local host:port splitter", .{ entry.path, needle, entry.required });
            }
        }
    }

    // Rooms demos must split host:port through the core grammar, not a local
    // last-colon heuristic (IPv6-unsafe).
    const rooms_host_port = [_]struct {
        path: []const u8,
        required: []const u8,
        banned: []const []const u8,
    }{
        .{
            .path = "apps/rooms/lib/locator.ts",
            .required = "designatorHostPort",
            .banned = &.{ "lastIndexOf(\":\")", "`127.0.0.1:${token}`", "`127.0.0.1:${port}`" },
        },
        .{
            .path = "apps/rooms/demos/dm_demo.ts",
            .required = "loopbackTcpDesignator",
            .banned = &.{"`127.0.0.1:${"},
        },
        .{
            .path = "apps/rooms/web/serve.ts",
            .required = "loopbackTcpDesignator",
            .banned = &.{"`127.0.0.1:${"},
        },
        .{
            .path = "apps/rooms/demos/demo.ts",
            .required = "loopbackTcpDesignator",
            .banned = &.{"`127.0.0.1:${"},
        },
        .{
            .path = "apps/rooms/server/main.ts",
            .required = "designatorHostPort",
            .banned = &.{"lastIndexOf(\":\")"},
        },
        .{
            .path = "apps/rooms/clients/python/room_client.py",
            .required = "designator_host_port",
            .banned = &.{"rfind(\":\")"},
        },
        .{
            .path = "apps/rooms/clients/rust/room.rs",
            .required = "designator_host_port",
            .banned = &.{"rsplit_once(':')"},
        },
        .{
            .path = "apps/rooms/clients/racket/room-client.rkt",
            .required = "designator-host-port",
            .banned = &.{"(char=? (string-ref locator i) #\\:)"},
        },
    };
    for (rooms_host_port) |entry| {
        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for rooms host:port check with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, entry.required) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — rooms dials must split host:port through the core grammar", .{ entry.path, entry.required });
        }
        for (entry.banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use core host:port grammar / loopbackTcpDesignator", .{ entry.path, needle });
            }
        }
    }
    // Zig demo clients mint tcp designators through tcp.locator, not bufPrint.
    const zig_demo_locator = [_]struct { path: []const u8, required: []const u8, banned: []const []const u8 }{
        .{
            .path = "apps/tasks/zig/client.zig",
            .required = "tcp.locator(",
            .banned = &.{ "bufPrint(&designator_buf, \"{s}:{d}\"", "127.0.0.1:{d}" },
        },
        .{
            .path = "apps/tools/zig/agent.zig",
            .required = "tcp.locator(",
            .banned = &.{ "bufPrint(&designator_buf, \"{s}:{d}\"", "127.0.0.1:{d}" },
        },
        .{
            .path = "examples/zig/02_introduce_and_redeem.zig",
            .required = "tcp.locator(",
            .banned = &.{ "lastIndexOfScalar(u8, bound, ':')", "127.0.0.1:{d}" },
        },
        .{
            .path = "test/driver/bridge_test.zig",
            .required = "tcp.locator(",
            .banned = &.{"127.0.0.1:{d}"},
        },
        .{
            .path = "test/driver/blocking_session_test.zig",
            .required = "tcp.locator(",
            .banned = &.{ "bufPrint(&designator_buf, \"{f}\"", "127.0.0.1:{d}" },
        },
        .{
            .path = "test/driver/pluggability_test.zig",
            .required = "tcp.designatorOnListener(",
            .banned = &.{ "bufPrint(out, \"{f}\"", "127.0.0.1:{d}" },
        },
        .{
            .path = "interop/tcp_loop/driver.zig",
            .required = "tcp.locator(",
            .banned = &.{"127.0.0.1:{d}"},
        },
        .{
            .path = "interop/goblins_interop/handoff_driver.zig",
            .required = "tcp.locator(",
            .banned = &.{"127.0.0.1:{d}"},
        },
        .{
            .path = "interop/goblins_interop/driver.zig",
            .required = "tcp.locator(",
            .banned = &.{ "host ++ \":1\"", "127.0.0.1:{d}" },
        },
        .{
            .path = "bench/peer_scaling_bench.zig",
            .required = "tcp.locator(",
            .banned = &.{"127.0.0.1:{d}"},
        },
        .{
            .path = "conformance/ocapn-conformance/pancake_peer.zig",
            .required = "tcp.locator(",
            .banned = &.{ "bufPrint(&designator_buf, \"{s}:{d}\"", "allocPrint(allocator, \"{s}:{s}\"", "indexOfScalar(u8, exporter_location, ':')" },
        },
    };
    for (zig_demo_locator) |entry| {
        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for zig demo locator check with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, entry.required) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — Zig demos mint tcp locators through tcp.locator", .{ entry.path, entry.required });
        }
        for (entry.banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use tcp.parseHostPort + tcp.locator", .{ entry.path, needle });
            }
        }
    }

    // Byte-fed Host dials through openDialedLocator only; the URI wrapper is gone.
    const open_dialed_ban = [_]struct { path: []const u8, banned: []const []const u8 }{
        .{ .path = "src/driver/core/host.zig", .banned = &.{"pub fn openDialed(self: *Host, locator_uri"} },
        .{ .path = "test/driver/core_host_test.zig", .banned = &.{".openDialed("} },
        .{ .path = "test/driver/core_host_budget_test.zig", .banned = &.{".openDialed("} },
        .{ .path = "test/driver/core_host_adopt_test.zig", .banned = &.{".openDialed("} },
        .{ .path = "apps/rooms/clients/zig/client.zig", .banned = &.{"fn dialTcp("} },
    };
    for (open_dialed_ban) |entry| {
        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for openDialed ban with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (entry.banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use openDialedLocator / parts-in-hand dial", .{ entry.path, needle });
            }
        }
    }

    // Host:port dial helpers must not mint a peer URI only to re-parse it.
    // The one C ABI dial mint is open_dialed_locator (parts in hand); URI
    // holders parse first. Ban the deleted URI-string entry and round-trips.
    const dial_uri_mint = [_]struct {
        path: []const u8,
        banned: []const []const u8,
    }{
        .{
            .path = "bindings/python/pancake/_session.py",
            .banned = &.{
                "establish_dialed(node, tcp_locator",
                "establish_dialed(cls, tcp_locator",
                "await cls.establish_dialed(node, tcp_locator",
                "def _mint_dialed(",
                "def _open_dialed(",
                "pancake_host_session_open_dialed(",
            },
        },
        .{
            .path = "bindings/python/zig_smoke.py",
            .banned = &.{
                "_mint_dialed(Node(), tcp_locator",
                "._mint_dialed_locator(",
                "Connection.connect(",
            },
        },
        .{
            .path = "bindings/python/pancake/_session.py",
            .banned = &.{
                "async def connect(cls, host",
                "Connection.connect(",
            },
        },
        .{
            .path = "bindings/rust/src/session.rs",
            .banned = &.{
                "establish_dialed(node.shared(), &tcp_locator",
                "establish_dialed(node.shared(), &locator",
                "let locator = tcp_locator(",
                "designator_host_port(&loc.designator)",
                "pub async fn connect_with_node<",
                "Connection::connect(addr)",
            },
        },
        .{
            .path = "bindings/ts/stack/session.ts",
            // The formatter-pinned `static async connect(\n\t\thost` variant
            // is retired: `Connection.connect(` catches any resurrection
            // without depending on rewrap.
            .banned = &.{
                "establishDialed(node, tcpLocator",
                "Connection.connect(",
            },
        },
        .{
            .path = "apps/rooms/demos/dm_demo.ts",
            .banned = &.{"Connection.connect("},
        },
        .{
            .path = "apps/rooms/lib/locator.ts",
            .banned = &.{"Connection.connect("},
        },
        .{
            .path = "interop/goblins_interop/deno_gift_client.ts",
            .banned = &.{"Connection.connect("},
        },
        .{
            .path = "bindings/racket/private/session.rkt",
            .banned = &.{
                "(establish-dialed-connection m (tcp-locator",
                "(define (establish-dialed-connection ",
                "pancake_host_session_open_dialed ",
                "(define (dial-tcp ",
                "(define (connect-tcp ",
            },
        },
        .{
            .path = "bindings/racket/private/ffi-host.rkt",
            .banned = &.{"(define-driver pancake_host_session_open_dialed\n"},
        },
        .{
            .path = "src/c_abi/host/mod.zig",
            .banned = &.{"pub export fn pancake_host_session_open_dialed("},
        },
    };
    for (dial_uri_mint) |entry| {
        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for dial URI-mint ban with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (entry.banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — host:port dials use establish_dialed_locator / open_dialed_locator, not tcp_locator→open_dialed", .{ entry.path, needle });
            }
        }
    }

    // Binding hint name literal lives only in each language's constant home
    // (mirrors model.transport.hint_direct_addresses).
    {
        const allowed = [_][]const u8{
            "bindings/python/pancake/_constants.py",
            "bindings/rust/src/abi_constants.rs",
            "bindings/ts/stack/locator.ts",
            "bindings/racket/private/constants.rkt",
        };
        const roots = [_][]const u8{
            "bindings/python",
            "bindings/rust/src",
            "bindings/ts",
            "bindings/racket",
            "apps/rooms",
        };
        const exts = [_][]const u8{ ".py", ".rs", ".ts", ".rkt" };
        for (roots) |bind_root| {
            var dir = root.openDir(io, bind_root, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var walker = try dir.walk(gpa);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if (entry.kind != .file) continue;
                var ok_ext = false;
                for (exts) |ext| {
                    if (std.mem.endsWith(u8, entry.path, ext)) {
                        ok_ext = true;
                        break;
                    }
                }
                if (!ok_ext) continue;
                if (std.mem.indexOf(u8, entry.path, "node_modules") != null) continue;
                if (std.mem.indexOf(u8, entry.path, "/target/") != null) continue;
                const rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ bind_root, entry.path });
                defer gpa.free(rel);
                var allow = false;
                for (allowed) |a| {
                    if (std.mem.eql(u8, rel, a)) {
                        allow = true;
                        break;
                    }
                }
                if (allow) continue;
                const contents = root.readFileAlloc(io, rel, gpa, .limited(2 << 20)) catch |err| {
                    try appendViolation(gpa, violations, "{s}: failed to read for binding hint-literal ban with {s}", .{ rel, @errorName(err) });
                    continue;
                };
                defer gpa.free(contents);
                if (std.mem.indexOf(u8, contents, "\"direct-addresses\"") != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `direct-addresses` literal — use HINT_DIRECT_ADDRESSES / HINT-DIRECT-ADDRESSES (mirrors model.transport.hint_direct_addresses)", .{rel});
                }
                if (std.mem.indexOf(u8, contents, "\"keyed-tcp\"") != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `keyed-tcp` literal — use TRANSPORT_KEYED_TCP / TRANSPORT-KEYED-TCP (mirrors model.transport.keyed_tcp)", .{rel});
                }
            }
        }
        // Grammar helpers live in locator modules; connection modules import them.
        // Hint→host:port for dial is core `planDial` / `tcpConnectHostPort` (ADR-0078);
        // bindings must not keep a twin `host_port_from_direct_hint`.
        const locator_grammar_home = [_]struct {
            connection: []const u8,
            locator: []const u8,
            banned_in_connection: []const []const u8,
            required_in_locator: []const []const u8,
        }{
            .{
                .connection = "bindings/python/pancake/_session.py",
                .locator = "bindings/python/pancake/_locator.py",
                .banned_in_connection = &.{
                    "def _socket_addr_designator",
                    "def _host_port_from_direct_hint",
                    "def socket_addr_designator",
                    "def host_port_from_direct_hint",
                },
                .required_in_locator = &.{
                    "def socket_addr_designator",
                },
            },
            .{
                .connection = "bindings/ts/stack/session.ts",
                .locator = "bindings/ts/stack/locator.ts",
                .banned_in_connection = &.{
                    "function socketAddrDesignator",
                    "function hostPortFromDirectHint",
                },
                .required_in_locator = &.{
                    "export function socketAddrDesignator",
                },
            },
            .{
                .connection = "bindings/rust/src/session.rs",
                .locator = "bindings/rust/src/uri.rs",
                .banned_in_connection = &.{
                    "fn host_port_from_direct_hint",
                    "fn socket_addr_designator",
                },
                .required_in_locator = &.{
                    "pub fn socket_addr_designator",
                },
            },
            .{
                .connection = "bindings/racket/private/session.rkt",
                .locator = "bindings/racket/private/locator.rkt",
                .banned_in_connection = &.{
                    "(define (socket-addr-designator",
                    "(define (host-port-from-direct-hint",
                },
                .required_in_locator = &.{
                    "(define (socket-addr-designator",
                },
            },
        };
        for (locator_grammar_home) |entry| {
            const conn_contents = root.readFileAlloc(io, entry.connection, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for locator-grammar home check with {s}", .{ entry.connection, @errorName(err) });
                continue;
            };
            defer gpa.free(conn_contents);
            for (entry.banned_in_connection) |needle| {
                if (std.mem.indexOf(u8, conn_contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — define grammar helpers in {s}", .{ entry.connection, needle, entry.locator });
                }
            }
            const loc_contents = root.readFileAlloc(io, entry.locator, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for locator-grammar home check with {s}", .{ entry.locator, @errorName(err) });
                continue;
            };
            defer gpa.free(loc_contents);
            for (entry.required_in_locator) |needle| {
                if (std.mem.indexOf(u8, loc_contents, needle) == null) {
                    try appendViolation(gpa, violations, "{s}: missing `{s}` — locator grammar helper home", .{ entry.locator, needle });
                }
            }
        }
        // One unified dial executor owns the transport switch per binding.
        const unified_dial_executor = [_]struct { path: []const u8, symbol: []const u8 }{
            .{ .path = "bindings/python/pancake/_dial.py", .symbol = "dial_parsed_locator" },
            .{ .path = "bindings/ts/stack/dial.ts", .symbol = "dialParsedLocator" },
            .{ .path = "bindings/rust/src/dial.rs", .symbol = "dial_parsed_locator" },
            .{ .path = "bindings/racket/private/dial.rkt", .symbol = "dial-parsed-locator" },
        };
        for (unified_dial_executor) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for unified dial executor check with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, entry.symbol) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — connect and redeem share one dial executor", .{ entry.path, entry.symbol });
            }
        }
        // TCP dials always split the designator through the core host:port grammar;
        // connect must not bypass with a parse-time hostPort cache.
        const tcp_dial_one_path = [_]struct {
            path: []const u8,
            banned: []const []const u8,
        }{
            .{ .path = "bindings/ts/stack/dial.ts", .banned = &.{ "opts.hostPort", "hostPort: loc.hostPort" } },
            .{ .path = "bindings/rust/src/dial.rs", .banned = &.{ "tcp_host_port", "loc.host_port" } },
            .{ .path = "bindings/python/pancake/_dial.py", .banned = &.{ "tcp_host", "tcp_port", "loc.host", "loc.port" } },
            .{ .path = "bindings/racket/private/dial.rkt", .banned = &.{ "#:tcp-host", "#:tcp-port", "(locator-host loc)", "(locator-port loc)" } },
        };
        for (tcp_dial_one_path) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for tcp dial one-path check with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — tcp dials split designator via designator_host_port only", .{ entry.path, needle });
                }
            }
        }
        // DialPlan open-shape: peer_id (not product iroh); PeerKey refuse before I/O.
        {
            const plan_src = root.readFileAlloc(io, "src/driver/core/dial_plan.zig", gpa, .limited(2 << 20)) catch |err| blk: {
                try appendViolation(gpa, violations, "src/driver/core/dial_plan.zig: failed to read for peer_id gate with {s}", .{@errorName(err)});
                break :blk @as(?[]u8, null);
            };
            defer if (plan_src) |c| gpa.free(c);
            if (plan_src) |contents| {
                if (std.mem.indexOf(u8, contents, "peer_id:") == null) {
                    try appendViolation(gpa, violations, "src/driver/core/dial_plan.zig: missing `peer_id:` — DialPlan open-shape arm", .{});
                }
                if (std.mem.indexOf(u8, contents, "iroh:") != null) {
                    try appendViolation(gpa, violations, "src/driver/core/dial_plan.zig: forbidden `iroh:` — DialPlan arm is peer_id, not the product name", .{});
                }
                if (std.mem.indexOf(u8, contents, "PeerKey.fromDesignator") == null) {
                    try appendViolation(gpa, violations, "src/driver/core/dial_plan.zig: missing `PeerKey.fromDesignator` — keyed-tcp/iroh refuse before I/O", .{});
                }
            }
            const core_import_ban = [_]struct { path: []const u8, needles: []const []const u8 }{
                .{ .path = "src/driver/core/dial_plan.zig", .needles = &.{ "@import(\"iroh\")", "net/transport/iroh", "net_transport_iroh" } },
                .{ .path = "src/driver/core/vocab.zig", .needles = &.{ "@import(\"iroh\")", "net/transport/iroh", "net_transport_iroh" } },
                .{ .path = "src/driver/core/host.zig", .needles = &.{ "@import(\"iroh\")", "net/transport/iroh", "net_transport_iroh" } },
            };
            for (core_import_ban) |entry| {
                const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                    try appendViolation(gpa, violations, "{s}: failed to read for iroh-import ban with {s}", .{ entry.path, @errorName(err) });
                    continue;
                };
                defer gpa.free(contents);
                for (entry.needles) |needle| {
                    if (std.mem.indexOf(u8, contents, needle) != null) {
                        try appendViolation(gpa, violations, "{s}: forbidden `{s}` — driver_core must not import the iroh netlayer", .{ entry.path, needle });
                    }
                }
            }
            // Only the C ABI source row: the generated header and binding
            // mirrors are held in lockstep by `gen-header-host-check`,
            // `gen-ts-abi-check`, and `gen-binding-constants-check`, so
            // per-mirror rows here were redundant.
            const shape_peer = [_]struct { path: []const u8, required: []const u8, banned: []const u8 }{
                .{ .path = "src/c_abi/host/mod.zig", .required = "PANCAKE_DIAL_SHAPE_PEER_ID", .banned = "PANCAKE_DIAL_SHAPE_IROH" },
            };
            for (shape_peer) |entry| {
                const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                    try appendViolation(gpa, violations, "{s}: failed to read for DIAL_SHAPE_PEER_ID gate with {s}", .{ entry.path, @errorName(err) });
                    continue;
                };
                defer gpa.free(contents);
                if (std.mem.indexOf(u8, contents, entry.required) == null) {
                    try appendViolation(gpa, violations, "{s}: missing `{s}` — peer-id open shape", .{ entry.path, entry.required });
                }
                if (std.mem.indexOf(u8, contents, entry.banned) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — product name is not the DialPlan shape", .{ entry.path, entry.banned });
                }
            }
        }
        // Binding locator modules must not resurrect hint→host:port twins.
        const retired_hint_split = [_]struct {
            path: []const u8,
            banned: []const []const u8,
        }{
            .{ .path = "bindings/python/pancake/_locator.py", .banned = &.{ "def host_port_from_direct_hint", "def _host_port_from_direct_hint" } },
            .{ .path = "bindings/ts/stack/locator.ts", .banned = &.{ "function hostPortFromDirectHint", "export function hostPortFromDirectHint" } },
            .{ .path = "bindings/rust/src/uri.rs", .banned = &.{ "fn host_port_from_direct_hint", "pub fn host_port_from_direct_hint" } },
            .{ .path = "bindings/racket/private/locator.rkt", .banned = &.{"(define (host-port-from-direct-hint"} },
        };
        for (retired_hint_split) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for retired hint-split ban with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — hint→host:port is planDial policy (ADR-0078), not a binding helper", .{ entry.path, needle });
                }
            }
        }
        // Binding pump feed posture: one borrowed call per chunk — the core
        // owns framing and the unconsumed stream tail, so a binding-side
        // inbox must not come back.
        const pump_borrow = [_]struct { path: []const u8, required: []const []const u8, banned: []const []const u8 }{
            .{
                .path = "bindings/ts/stack/pump.ts",
                .required = &.{"ab(chunk)"},
                .banned = &.{ "appendInbox", "h.inbox" },
            },
            .{
                .path = "bindings/rust/src/pump.rs",
                .required = &.{"chunk.as_ptr()"},
                .banned = &.{"shared.inbox"},
            },
            .{
                .path = "bindings/python/pancake/_pump.py",
                .required = &.{"ctypes.c_char_p(chunk)"},
                .banned = &.{"session.inbox"},
            },
            .{
                .path = "bindings/racket/private/pump.rkt",
                .required = &.{"pin-immobile got"},
                .banned = &.{"async-connection-inbox"},
            },
        };
        for (pump_borrow) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for pump borrow gate with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            for (entry.required) |needle| {
                if (std.mem.indexOf(u8, contents, needle) == null) {
                    try appendViolation(gpa, violations, "{s}: missing `{s}` — the feed borrows the fresh chunk for one call", .{ entry.path, needle });
                }
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — the core owns the stream tail; a binding inbox must not return", .{ entry.path, needle });
                }
            }
        }
        // Binding RemotePromise: sum state, not nullable vow discriminant.
        const promise_sum = [_]struct { path: []const u8, required: []const []const u8, banned: []const []const u8 }{
            .{
                .path = "bindings/ts/stack/promise.ts",
                .required = &.{ "export type PromiseState", "static far(", "static local(" },
                .banned = &.{"readonly vow: bigint | null"},
            },
            .{
                .path = "bindings/python/pancake/_promise.py",
                .required = &.{ "class PromiseState", "class Far", "class Local", "def far(", "def local(", "self._kind" },
                .banned = &.{ "vow: Optional[int]", "vow: Optional[int] = None", "self._state =" },
            },
            .{
                .path = "bindings/rust/src/promise.rs",
                .required = &.{ "enum PromiseState", "Far(", "Local {" },
                .banned = &.{},
            },
        };
        for (promise_sum) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for PromiseState gate with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            for (entry.required) |needle| {
                if (std.mem.indexOf(u8, contents, needle) == null) {
                    try appendViolation(gpa, violations, "{s}: missing `{s}` — RemotePromise sum state", .{ entry.path, needle });
                }
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — nullable vow is not the discriminant", .{ entry.path, needle });
                }
            }
        }
        // Dial plan alias decode + peer-id shape; language sum; no opaque rematerialize.
        // retire-by: the next rewrite of a binding dial module it guards —
        // retire that file's `dispatching on the locator` / `beyond the tcp
        // host:port split` prose needles in that same diff.
        const dial_alias = [_]struct { path: []const u8, required: []const []const u8, banned: []const []const u8 }{
            .{
                .path = "bindings/ts/stack/dial.ts",
                .required = &.{ "decodePlanView", "DIAL_SHAPE_PEER_ID", "DIAL_SHAPE_HOST_PORT", "tag: \"peer_id\"", "tag: \"host_port\"" },
                .banned = &.{ "DIAL_SHAPE_IROH", "beyond the tcp host:port split", "dispatching on the locator", "readBytes(ptr, len)" },
            },
            .{
                .path = "bindings/python/pancake/_dial.py",
                .required = &.{ "def _decode_plan_view", "DIAL_SHAPE_PEER_ID", "DIAL_SHAPE_HOST_PORT", "memoryview(buf)", "class _PeerIdDial", "class _HostPortDial" },
                .banned = &.{ "DIAL_SHAPE_IROH", "bytes(buf)[", "dispatching on the locator", "return ctypes.string_at" },
            },
            .{
                .path = "bindings/rust/src/dial.rs",
                .required = &.{ "fn decode_plan_view", "DIAL_SHAPE_PEER_ID", "DIAL_SHAPE_HOST_PORT", "DialPlan::PeerId", "DialPlan::HostPort" },
                .banned = &.{ "DIAL_SHAPE_IROH", "beyond the tcp host:port split", "dispatching on the locator", "view_string(ptr, len)" },
            },
            .{
                .path = "bindings/racket/private/dial.rkt",
                .required = &.{ "decode-plan-view", "DIAL-SHAPE-PEER-ID", "DIAL-SHAPE-HOST-PORT", "peer-id-dial", "host-port-dial" },
                .banned = &.{ "DIAL-SHAPE-IROH", "dispatching on the locator", "(bytes<-c ptr len)" },
            },
        };
        for (dial_alias) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for dial-alias gate with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            for (entry.required) |needle| {
                if (std.mem.indexOf(u8, contents, needle) == null) {
                    try appendViolation(gpa, violations, "{s}: missing `{s}` — dial plan alias / peer-id shape", .{ entry.path, needle });
                }
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — stale dial prose or product shape", .{ entry.path, needle });
                }
            }
        }
        {
            const action_src = root.readFileAlloc(io, "bindings/rust/src/action.rs", gpa, .limited(1 << 20)) catch |err| blk: {
                try appendViolation(gpa, violations, "bindings/rust/src/action.rs: failed to read for FAIL→CLOSED gate with {s}", .{@errorName(err)});
                break :blk @as(?[]u8, null);
            };
            defer if (action_src) |c| gpa.free(c);
            if (action_src) |contents| {
                if (std.mem.indexOf(u8, contents, "vow_session_closing") == null) {
                    try appendViolation(gpa, violations, "bindings/rust/src/action.rs: missing `vow_session_closing` — FAIL must classify disconnect as CLOSED", .{});
                }
                if (std.mem.indexOf(u8, contents, "ERR_CLOSED") == null) {
                    try appendViolation(gpa, violations, "bindings/rust/src/action.rs: missing `ERR_CLOSED` on FAIL path", .{});
                }
            }
            const host_src = root.readFileAlloc(io, "bindings/rust/src/host.rs", gpa, .limited(2 << 20)) catch |err| blk: {
                try appendViolation(gpa, violations, "bindings/rust/src/host.rs: failed to read for FAIL→CLOSED gate with {s}", .{@errorName(err)});
                break :blk @as(?[]u8, null);
            };
            defer if (host_src) |c| gpa.free(c);
            // retire-by: the next rewrite of bindings/rust/src/host.rs —
            // retire the `siblings type it Closed` prose needle in that diff.
            if (host_src) |contents| {
                if (std.mem.indexOf(u8, contents, "siblings type it Closed") != null) {
                    try appendViolation(gpa, violations, "bindings/rust/src/host.rs: forbidden papering comment — FAIL classifies CLOSED in-tree", .{});
                }
                if (std.mem.indexOf(u8, contents, "fn vow_session_closing") == null) {
                    try appendViolation(gpa, violations, "bindings/rust/src/host.rs: missing `vow_session_closing`", .{});
                }
            }
        }
        // Peer-id open-shape vocabulary: no product-named shape error / FFI prose.
        // retire-by: the next rewrite of a guarded FFI module — retire that
        // file's `IROH fills` prose needle in that same diff.
        {
            const peer_id_vocab = [_]struct { path: []const u8, banned: []const []const u8 }{
                .{ .path = "src/c_abi/host/host.zig", .banned = &.{"an iroh locator requires a reachability posture"} },
                .{ .path = "bindings/python/pancake/_ffi_host.py", .banned = &.{"IROH fills"} },
                .{ .path = "bindings/racket/private/ffi-host.rkt", .banned = &.{"IROH fills"} },
                .{ .path = "bindings/rust/src/sys/host.rs", .banned = &.{"IROH fills"} },
            };
            for (peer_id_vocab) |entry| {
                const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                    try appendViolation(gpa, violations, "{s}: failed to read for peer-id vocab gate with {s}", .{ entry.path, @errorName(err) });
                    continue;
                };
                defer gpa.free(contents);
                for (entry.banned) |needle| {
                    if (std.mem.indexOf(u8, contents, needle) != null) {
                        try appendViolation(gpa, violations, "{s}: forbidden `{s}` — open shape is peer_id, not product iroh", .{ entry.path, needle });
                    }
                }
            }
        }
        // Gift interop argv must mint host:port designators through socket_addr_designator.
        const gift_addr_designator = [_]struct {
            path: []const u8,
            required: []const u8,
            banned: []const []const u8,
        }{
            .{
                .path = "interop/goblins_interop/deno_gift_client.ts",
                .required = "socketAddrDesignator",
                .banned = &.{"`${HOST}:${gifterPort}`,"},
            },
            .{
                .path = "interop/goblins_interop/python_gift_client.py",
                .required = "socket_addr_designator",
                .banned = &.{"f\"{HOST}:{gifter_port}\""},
            },
            .{
                .path = "interop/goblins_interop/racket_gift_client.rkt",
                .required = "socket-addr-designator",
                .banned = &.{"(format \"~a:~a\" HOST gifter-port)"},
            },
            .{
                .path = "interop/goblins_interop/rust_gift_client.rs",
                .required = "socket_addr_designator",
                .banned = &.{"format!(\"{HOST}:{gifter_port}\")"},
            },
        };
        for (gift_addr_designator) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for gift addr designator check with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, entry.required) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — gift interop argv must use socket_addr_designator", .{ entry.path, entry.required });
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use socket_addr_designator for gift argv", .{ entry.path, needle });
                }
            }
        }
        // Rooms iroh dials parse first; hint→Direct, else discovery — never blanket Direct on `://`.
        // Each `required` names the invariant — the parsed locator itself is
        // what gets dialed, through the one `connect` — and stops at the
        // argument that carries it. Pinning a whole argument list makes every
        // new dial option (a codec, a timeout) read as a violation of a rule
        // it does not touch.
        const rooms_iroh_dial = [_]struct {
            path: []const u8,
            required: []const u8,
            banned: []const []const u8,
        }{
            .{
                .path = "apps/rooms/lib/locator.ts",
                .required = "connect(locator,",
                .banned = &.{ "connectIroh(", "import { connectIroh" },
            },
            .{
                .path = "apps/rooms/clients/python/room_client.py",
                .required = "await connect(locator, reach",
                .banned = &.{"connect_iroh("},
            },
            .{
                .path = "apps/rooms/clients/racket/room-client.rkt",
                .required = "(connect locator reach",
                .banned = &.{"(connect-iroh "},
            },
            .{
                .path = "apps/rooms/clients/rust/room.rs",
                .required = "connect(locator, Some(reachability)",
                .banned = &.{"connect_iroh("},
            },
            .{
                .path = "apps/rooms/clients/zig/client.zig",
                .required = "parsePeer",
                .banned = &.{"init(io, null, .direct)"},
            },
            .{
                .path = "apps/rooms/test/server_test.ts",
                .required = "await dial(uri)",
                .banned = &.{ "connect(uri, Reachability.Direct)", "Reachability.Direct)" },
            },
        };
        for (rooms_iroh_dial) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for rooms iroh dial check with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, entry.required) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — rooms iroh dials must parse the locator first", .{ entry.path, entry.required });
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — rooms iroh posture follows hints, not blanket Direct", .{ entry.path, needle });
                }
            }
        }
        // Dogfood / unit tests mint host:port designators through socket_addr_designator.
        const dogfood_addr_designator = [_]struct {
            path: []const u8,
            required: []const u8,
            banned: []const []const u8,
        }{
            .{
                .path = "bindings/racket/zig-smoke.rkt",
                .required = "socket-addr-designator",
                .banned = &.{ "\"127.0.0.1:9\"", "\"127.0.0.1:1\"", "\"127.0.0.1:2\"", "format-peer-uri \"tcp\"" },
            },
            .{
                .path = "bindings/python/zig_smoke.py",
                .required = "socket_addr_designator",
                .banned = &.{"\"127.0.0.1:1\""},
            },
            .{
                .path = "bindings/rust/src/session_tests.rs",
                .required = "socket_addr_designator(&peer.ip().to_string(), peer.port())",
                .banned = &.{ "peer.to_string()", "\"127.0.0.1:0\".to_string()" },
            },
        };
        for (dogfood_addr_designator) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for dogfood addr designator check with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, entry.required) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — dogfood designators must use socket_addr_designator", .{ entry.path, entry.required });
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use socket_addr_designator", .{ entry.path, needle });
                }
            }
        }
        // External dialers use connect(locator); parallel connect_iroh* is binding-internal.
        const no_public_iroh_connect = [_]struct { path: []const u8, banned: []const []const u8 }{
            .{ .path = "interop/iroh_loop/deno_client.ts", .banned = &.{ "connectIroh(", "_connectIroh(" } },
            .{ .path = "interop/iroh_loop/python_client.py", .banned = &.{"connect_iroh("} },
            .{ .path = "interop/iroh_loop/racket_client.rkt", .banned = &.{ "(connect-iroh ", "(connect-iroh/node " } },
            .{ .path = "interop/iroh_reachability/deno_client.ts", .banned = &.{ "connectIroh(", "_connectIroh(" } },
            .{ .path = "interop/iroh_reachability/python_client.py", .banned = &.{"connect_iroh("} },
            .{ .path = "interop/iroh_reachability/racket_client.rkt", .banned = &.{ "(connect-iroh ", "(connect-iroh/node " } },
            .{ .path = "interop/iroh_handoff/deno_client.ts", .banned = &.{ "connectIroh(", "_connectIroh(" } },
            .{ .path = "interop/iroh_handoff/python_client.py", .banned = &.{ "connect_iroh(", "connect_iroh_with_node(" } },
            .{ .path = "interop/iroh_handoff/racket_client.rkt", .banned = &.{ "(connect-iroh ", "(connect-iroh/node " } },
            .{ .path = "bindings/proofs/iroh_redeem_posture/python_client.py", .banned = &.{ "connect_iroh(", "connect_iroh_with_node(" } },
            .{ .path = "bindings/proofs/iroh_redeem_posture/racket_client.rkt", .banned = &.{ "(connect-iroh ", "(connect-iroh/node " } },
            .{ .path = "bindings/proofs/iroh_redeem_posture/deno_client.ts", .banned = &.{ "connectIroh(", "_connectIroh(" } },
            .{ .path = "bindings/rust/examples/iroh_loop.rs", .banned = &.{"connect_iroh("} },
            .{ .path = "bindings/rust/examples/iroh_reachability.rs", .banned = &.{"connect_iroh("} },
            .{ .path = "bindings/rust/examples/iroh_handoff.rs", .banned = &.{ "connect_iroh(", "connect_iroh_with_node(" } },
            .{ .path = "bindings/rust/examples/iroh_redeem_posture.rs", .banned = &.{ "connect_iroh(", "connect_iroh_with_node(" } },
            .{ .path = "bindings/python/pancake/iroh.py", .banned = &.{ "\"connect_iroh\"", "async def connect_iroh(", "async def connect_iroh_with_node(" } },
            .{ .path = "bindings/rust/src/iroh.rs", .banned = &.{ "pub async fn connect_iroh(", "pub async fn connect_iroh_with_node(" } },
            .{ .path = "bindings/ts/iroh/mod.ts", .banned = &.{ "connectIroh", "_connectIroh" } },
            .{ .path = "bindings/racket/pancake-iroh.rkt", .banned = &.{"(provide connect-iroh/node\n         listen-iroh"} },
        };
        for (no_public_iroh_connect) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for iroh-connect ban with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — dial iroh through connect(locator)", .{ entry.path, needle });
                }
            }
        }
        // Public barrel must not export the dial; the dial module loads
        // `@pancake/iroh/internal` from `stack/dial.ts`.
        iroh_public_surface: {
            const mod_contents = root.readFileAlloc(io, "bindings/ts/iroh/mod.ts", gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "bindings/ts/iroh/mod.ts: failed to read with {s}", .{@errorName(err)});
                break :iroh_public_surface;
            };
            defer gpa.free(mod_contents);
            if (std.mem.indexOf(u8, mod_contents, "listenIroh") == null) {
                try appendViolation(gpa, violations, "bindings/ts/iroh/mod.ts: missing listenIroh re-export", .{});
            }
            const internal_contents = root.readFileAlloc(io, "bindings/ts/iroh/internal.ts", gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "bindings/ts/iroh/internal.ts: failed to read with {s}", .{@errorName(err)});
                break :iroh_public_surface;
            };
            defer gpa.free(internal_contents);
            if (std.mem.indexOf(u8, internal_contents, "_connectIroh") == null) {
                try appendViolation(gpa, violations, "bindings/ts/iroh/internal.ts: missing `_connectIroh` export", .{});
            }
            const dial_contents = root.readFileAlloc(io, "bindings/ts/stack/dial.ts", gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "bindings/ts/stack/dial.ts: failed to read with {s}", .{@errorName(err)});
                break :iroh_public_surface;
            };
            defer gpa.free(dial_contents);
            if (std.mem.indexOf(u8, dial_contents, "import(\"@pancake/iroh/internal\")") == null) {
                try appendViolation(gpa, violations, "bindings/ts/stack/dial.ts: iroh dial must lazy-import `@pancake/iroh/internal`", .{});
            }
            if (std.mem.indexOf(u8, dial_contents, "import(\"@pancake/iroh\")") != null) {
                try appendViolation(gpa, violations, "bindings/ts/stack/dial.ts: forbidden public `@pancake/iroh` dial import — use `/internal`", .{});
            }
            const conn_contents = root.readFileAlloc(io, "bindings/ts/stack/session.ts", gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "bindings/ts/stack/session.ts: failed to read with {s}", .{@errorName(err)});
                break :iroh_public_surface;
            };
            defer gpa.free(conn_contents);
            if (std.mem.indexOf(u8, conn_contents, "import(\"@pancake/iroh\")") != null) {
                try appendViolation(gpa, violations, "bindings/ts/stack/session.ts: forbidden public `@pancake/iroh` dial import — use the dial module", .{});
            }
            const rkt_contents = root.readFileAlloc(io, "bindings/racket/pancake-iroh.rkt", gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "bindings/racket/pancake-iroh.rkt: failed to read with {s}", .{@errorName(err)});
                break :iroh_public_surface;
            };
            defer gpa.free(rkt_contents);
            // `connect-iroh/node` is binding-internal, and what keeps it that way
            // is living in the private tree while the barrel re-exports only the
            // hosting surface. It must not become a submodule again: Racket's
            // compile manager does not manage submodule requests, so a program
            // running against compiled bytecode cannot reach one without
            // re-expanding the module it sits in.
            if (std.mem.indexOf(u8, rkt_contents, "(module* dial") != null) {
                try appendViolation(gpa, violations, "bindings/racket/pancake-iroh.rkt: `connect-iroh/node` must stay in private/iroh.rkt, not a `dial` submodule", .{});
            }
            const rkt_impl = root.readFileAlloc(io, "bindings/racket/private/iroh.rkt", gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "bindings/racket/private/iroh.rkt: failed to read with {s}", .{@errorName(err)});
                break :iroh_public_surface;
            };
            defer gpa.free(rkt_impl);
            if (std.mem.indexOf(u8, rkt_impl, "(provide connect-iroh/node") == null) {
                try appendViolation(gpa, violations, "bindings/racket/private/iroh.rkt: must provide `connect-iroh/node` for the binding's dial", .{});
            }
            // One owner for reaching the transport, and it loads a plain module.
            const rkt_dial = root.readFileAlloc(io, "bindings/racket/private/iroh-companion.rkt", gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "bindings/racket/private/iroh-companion.rkt: failed to read with {s}", .{@errorName(err)});
                break :iroh_public_surface;
            };
            defer gpa.free(rkt_dial);
            if (std.mem.indexOf(u8, rkt_dial, "(submod") != null) {
                try appendViolation(gpa, violations, "bindings/racket/private/iroh-companion.rkt: reach the iroh transport as a plain module, never a submodule", .{});
            }
        }
        // keyed_tcp_locator must assemble direct-addresses through
        // socket_addr_designator so IPv6 hints stay unambiguous.
        const keyed_hint_home = [_]struct {
            path: []const u8,
            required: []const u8,
            banned: []const []const u8,
        }{
            .{
                .path = "bindings/python/pancake/_locator.py",
                .required = "socket_addr_designator(host, port)",
                .banned = &.{"{_abi.HINT_DIRECT_ADDRESSES: f\"{host}:{port}\"}"},
            },
            .{
                .path = "bindings/ts/stack/locator.ts",
                .required = "socketAddrDesignator(hostname, port)",
                .banned = &.{"HINT_DIRECT_ADDRESSES, `${hostname}:${port}`"},
            },
            .{
                .path = "bindings/rust/src/uri.rs",
                .required = "socket_addr_designator(host, port)",
                // No banned twin: the rustfmt-pinned `\n\t\t` needle could
                // never re-match after a rewrap; the required needle carries
                // the invariant.
                .banned = &.{},
            },
            .{
                .path = "bindings/racket/private/locator.rkt",
                .required = "(socket-addr-designator host port)",
                .banned = &.{"(hash HINT-DIRECT-ADDRESSES (format \"~a:~a\" host port))"},
            },
        };
        for (keyed_hint_home) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for keyed-tcp hint grammar with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, entry.required) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — keyed-tcp direct-addresses hint must use socket_addr_designator", .{ entry.path, entry.required });
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use socket_addr_designator for keyed-tcp hints", .{ entry.path, needle });
                }
            }
        }
        // tcp_locator must assemble the designator through socket_addr_designator
        // so IPv6 stays unambiguous (sibling of keyed_tcp_locator hint ring).
        const tcp_locator_home = [_]struct {
            path: []const u8,
            required: []const u8,
            banned: []const []const u8,
        }{
            .{
                .path = "bindings/python/pancake/_locator.py",
                .required = "socket_addr_designator(host, port)",
                .banned = &.{
                    "format_peer_uri(_abi.TRANSPORT_TCP, f\"{host}:{port}\")",
                },
            },
            .{
                .path = "bindings/ts/stack/locator.ts",
                .required = "socketAddrDesignator(hostname, port)",
                .banned = &.{
                    "formatPeerUri(TRANSPORT_TCP, `${hostname}:${port}`)",
                },
            },
            .{
                .path = "bindings/rust/src/uri.rs",
                .required = "socket_addr_designator(host, port)",
                // No banned twin: the rustfmt-pinned `\n\t\t` needle could
                // never re-match after a rewrap; the required needle carries
                // the invariant.
                .banned = &.{},
            },
            .{
                .path = "bindings/racket/private/locator.rkt",
                .required = "(socket-addr-designator host port)",
                .banned = &.{
                    "(format-peer-uri TRANSPORT-TCP (format \"~a:~a\" host port))",
                },
            },
        };
        for (tcp_locator_home) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for tcp locator grammar with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, entry.required) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — tcp locator designator must use socket_addr_designator", .{ entry.path, entry.required });
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use socket_addr_designator for tcp locator designators", .{ entry.path, needle });
                }
            }
        }
        // KeyedTcpServer.uri must not remint from the bind-host string.
        {
            const path = "bindings/ts/stack/listen.ts";
            const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for keyed-uri bind-host ban with {s}", .{ path, @errorName(err) });
                return;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, "keyedTcpLocator(this.#designator, this.#host") != null) {
                try appendViolation(gpa, violations, "{s}: forbidden keyedTcpLocator(..., this.#host) — use listener.localAddr()", .{path});
            }
        }
        {
            const path = "bindings/racket/private/listen.rkt";
            const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for keyed-uri bind-host ban with {s}", .{ path, @errorName(err) });
                return;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, "(keyed-tcp-locator (keyed-tcp-server-designator s) (keyed-tcp-server-host s)") != null) {
                try appendViolation(gpa, violations, "{s}: forbidden CapTP host as keyed-tcp URI bind address — use tcp-addresses bound host", .{path});
            }
        }
        // Rust listen/accept designators go through socket_addr_designator, not
        // SocketAddr::to_string (Display is close but not the shared grammar).
        {
            const path = "bindings/rust/src/listen.rs";
            const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for rust designator grammar with {s}", .{ path, @errorName(err) });
                return;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, "socket_addr_designator(&") == null) {
                try appendViolation(gpa, violations, "{s}: missing socket_addr_designator on listen/accept paths", .{path});
            }
            if (std.mem.indexOf(u8, contents, "set_self_designator(&local.to_string())") != null or
                std.mem.indexOf(u8, contents, ".map(|addr| addr.to_string())") != null or
                std.mem.indexOf(u8, contents, ".map(|a| a.to_string())") != null)
            {
                try appendViolation(gpa, violations, "{s}: forbidden SocketAddr::to_string for designators — use socket_addr_designator", .{path});
            }
        }
        // Constant homes must name the full model.transport table.
        const must_have = [_]struct { path: []const u8, needles: []const []const u8 }{
            .{
                .path = "bindings/python/pancake/_constants.py",
                .needles = &.{ "TRANSPORT_TCP", "TRANSPORT_KEYED_TCP", "TRANSPORT_INPROC", "TRANSPORT_IROH", "TRANSPORT_KEYED_RELAY", "TRANSPORT_WEBRTC", "HINT_DIRECT_ADDRESSES" },
            },
            .{
                .path = "bindings/rust/src/abi_constants.rs",
                .needles = &.{ "TRANSPORT_TCP", "TRANSPORT_KEYED_TCP", "TRANSPORT_INPROC", "TRANSPORT_IROH", "TRANSPORT_KEYED_RELAY", "TRANSPORT_WEBRTC", "HINT_DIRECT_ADDRESSES" },
            },
            .{
                .path = "bindings/ts/stack/locator.ts",
                .needles = &.{ "TRANSPORT_TCP", "TRANSPORT_KEYED_TCP", "TRANSPORT_INPROC", "TRANSPORT_IROH", "TRANSPORT_KEYED_RELAY", "TRANSPORT_WEBRTC", "HINT_DIRECT_ADDRESSES" },
            },
            .{
                .path = "bindings/racket/private/constants.rkt",
                .needles = &.{ "TRANSPORT-TCP", "TRANSPORT-KEYED-TCP", "TRANSPORT-INPROC", "TRANSPORT-IROH", "TRANSPORT-KEYED-RELAY", "TRANSPORT-WEBRTC", "HINT-DIRECT-ADDRESSES" },
            },
        };
        for (must_have) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(1 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for transport-constant presence with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            for (entry.needles) |needle| {
                if (std.mem.indexOf(u8, contents, needle) == null) {
                    try appendViolation(gpa, violations, "{s}: missing `{s}` — binding transport vocabulary mirrors model.transport", .{ entry.path, needle });
                }
            }
        }
    }

    // The structural guard against a resident-local serve loop re-growing lives
    // in `checkIrohLoopConvergence`, which bans `LoopHost` as a Zig symbol in the
    // iroh resident source. A prose ban on the dead word across binding docs was
    // a stabilized-rename tombstone and was pruned (see the gate-accretion rule).
}
