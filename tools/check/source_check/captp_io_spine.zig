//! The CapTP I/O spine checks: one Bridge, one Loop, one dial contract.
//!
//! The require-groups and structural walks that hold the completion-loop
//! product spine to its settled shape, Backend/Locator dial contracts, the
//! Bridge as the one loop-to-Host seam, per-binding pump convergence needles,
//! and the transport-constant presence rows. The forbid half of
//! the same apex lives in `bans.zig` (`captp_io_spine_table`). Wired by the
//! source-check driver (`tools/check/source_check.zig`).

const std = @import("std");
const locator_sites = @import("locator_sites.zig");
const util = @import("util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const readSourceSubject = util.readSourceSubject;

/// Apex for one CapTP I/O spine. The forbid rows live in
/// `source_check/bans.zig` (`captp_io_spine_table`). This keeps the
/// require-groups and walks: the Backend/Locator dial contracts, the
/// binding spines, and the structural scans.
pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // Every completion Backend must declare the total dial contract.
    // Transport-bound DialResolvers interpret OCapN locators; platform Backends are connect-only.
    const backend_paths = [_][]const u8{
        "src/net/transport/iroh/backend.zig",
    };
    const required_dial = [_][]const u8{
        "pub const ConnectTarget",
        "startDial",
        "shutdownFd",
    };
    const platform_paths = [_][]const u8{
        "src/net/completion/epoll.zig",
        "src/net/completion/linux.zig",
        "src/net/completion/uring.zig",
        "src/net/completion/kqueue.zig",
    };
    const required_platform_dial = [_][]const u8{
        "pub const ConnectTarget",
        "startDial",
        "shutdownFd",
    };
    const locator_paths = [_][]const u8{
        "src/net/transport/tcp/addressing.zig",
        "src/net/transport/iroh/resolver.zig",
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

    // Readiness Pending rows are tagged unions. Flaggy `read_is_recv` /
    // `connecting` fields are deleted. Readiness backends share `BufferPool`.
    {
        const os_readiness_paths = [_][]const u8{
            "src/net/completion/epoll.zig",
            "src/net/completion/kqueue.zig",
        };
        for (os_readiness_paths) |path| {
            const source = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for readiness Pending check with {s}", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(source);
            for ([_][]const u8{ "read_is_recv", "connecting" }) |needle| {
                if (std.mem.indexOf(u8, source, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}`: readiness Pending is tagged unions (`read`/`write`), not flaggy fields", .{ path, needle });
                }
            }
        }
        // The iroh Pending dropped its `read_is_recv` flag too (ADR-0019), so
        // hold the flag out of iroh the same way it is held out of native readiness backends.
        const iroh_path = "src/net/transport/iroh/backend.zig";
        const iroh_src = root.readFileAlloc(io, iroh_path, gpa, .limited(2 << 20)) catch |err| blk: {
            try appendViolation(gpa, violations, "{s}: failed to read for iroh Pending flag check with {s}", .{ iroh_path, @errorName(err) });
            break :blk null;
        };
        defer if (iroh_src) |bytes| gpa.free(bytes);
        if (iroh_src) |bytes| {
            if (std.mem.indexOf(u8, bytes, "read_is_recv") != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `read_is_recv`: iroh Pending distinguishes read from write by its request kind, not a flag (ADR-0019)", .{iroh_path});
            }
        }
        const pool_paths = [_][]const u8{
            "src/net/completion/epoll.zig",
            "src/net/completion/kqueue.zig",
            "src/net/transport/iroh/backend.zig",
        };
        for (pool_paths) |path| {
            const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for BufferPool apex check with {s}", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            const has_pool = std.mem.indexOf(u8, contents, "buffer_pool") != null or
                std.mem.indexOf(u8, contents, "BufferPool") != null;
            if (!has_pool) {
                try appendViolation(gpa, violations, "{s}: missing BufferPool — readiness backends share `src/net/completion/buffer_pool.zig`", .{path});
            }
        }
    }

    // Platform TCP socket policy (bind/listen/reuseaddr, openSocket, dial sockaddr)
    // lives in `socket_tcp.zig`. Every native backend calls it rather than
    // reimplementing socket setup.
    // A full readiness mixin (`readiness_backend.zig`) is a rejected shape.
    {
        root.access(io, "src/net/completion/socket_tcp.zig", .{}) catch {
            try appendViolation(gpa, violations, "src/net/completion/socket_tcp.zig: file must exist: shared epoll/kqueue/uring TCP socket helpers", .{});
        };
        if (root.access(io, "src/net/completion/readiness_backend.zig", .{})) |_| {
            try appendViolation(gpa, violations, "src/net/completion/readiness_backend.zig: file must not exist — rejected readiness mixin; share BufferPool + socket_tcp only", .{});
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        const sock_paths = [_][]const u8{
            "src/net/completion/epoll.zig",
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
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — IPv4 bind/listen/reuseaddr policy lives in socket_tcp.zig", .{ path, needle });
                }
            }
        }
    }

    try expectFileContains(io, gpa, root, violations, "src/net/transport/tcp.zig", &.{
        "pub const DialResolver = addressing.DialResolver",
    });

    // `tcp.connectAddress` is post-admission I/O only. Production `src/` dials
    // must go through `DialResolver.resolve` (or `tcp.connect` / netlayer dial) first;
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
            if (std.mem.eql(u8, rel, "src/net/transport/tcp/stream.zig")) continue;
            if (std.mem.eql(u8, rel, "src/net/transport/tcp/profile.zig")) continue;
            const contents = root.readFileAlloc(io, rel, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for connectAddress ban with {s}", .{ rel, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, "connectAddress") != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `connectAddress` — dial through `DialResolver.resolve` / `tcp.connect` / netlayer dial; only tcp's socket/profile modules may call the post-admission connect", .{rel});
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
        ".agents/skills/memory-ledger/SKILL.md",
        ".agents/skills/memory-ledger/references/transports.md",
        ".agents/rules/cli.md",
    };
    const ghosts = [_]struct { needle: []const u8, reason: []const u8 }{
        .{
            .needle = "host_three_party_test",
            .reason = "byte-fed three-party is `test/driver/core_host/`; resident-fed is `test/driver/host_runtime_multiplexed/`",
        },
        .{
            .needle = "three real residents",
            .reason = "do not recite a fixed resident count in prose; the roster is `tcp`, `keyed-tcp`, `inproc`, `iroh`, and `webrtc`, pinned per doc by `checkResidentRoster`",
        },
    };
    for (ghost_docs) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| switch (err) {
            // tolerant: a ghost doc that no longer exists has nothing to recite.
            error.FileNotFound => continue,
            else => {
                try appendViolation(gpa, violations, "{s}: cannot be read for the resident-roster check ({s})", .{ path, @errorName(err) });
                continue;
            },
        };
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

    // Generic Runtime/dial modules do not interpret transport locators. In
    // particular they must not re-teach the host:port grammar owned by TCP.
    const dial_host_port = [_]struct {
        path: []const u8,
        banned: []const []const u8,
    }{
        .{
            .path = "bindings/python/glowcap/_dial.py",
            .banned = &.{ "re.match(", "rsplit(\":\"", ".rsplit(\":\"" },
        },
        .{
            .path = "bindings/rust/src/dial.rs",
            .banned = &.{ "rsplit_once(':')", "split_once(':')" },
        },
        .{
            .path = "bindings/ts/runtime/dial.ts",
            .banned = &.{ "lastIndexOf(\":\")", "match(/^(.+):([0-9]+)$/)" },
        },
        .{
            .path = "bindings/racket/private/dial.rkt",
            .banned = &.{"#rx\"^(.+):([0-9]+)$\""},
        },
    };
    for (dial_host_port) |entry| {
        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for dial host:port check with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (entry.banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — generic Runtime code leaves locator interpretation to the transport package", .{ entry.path, needle });
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
            .path = "apps/rooms/rust/services/src/web/relay.rs",
            .required = "glowcap::designator_host_port",
            .banned = &.{"rsplit_once(':')"},
        },
        .{
            .path = "apps/rooms/demos/demo.ts",
            .required = "loopbackTcpDesignator",
            .banned = &.{"`127.0.0.1:${"},
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
    const zig_demo_locator = locator_sites.zig_demo_locator;
    for (zig_demo_locator) |entry| {
        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for zig demo locator check with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, entry.required) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — Zig callers must use a complete advertised locator or the transport's locator constructor", .{ entry.path, entry.required });
        }
        for (entry.banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — preserve the advertised locator or use the transport's locator constructor", .{ entry.path, needle });
            }
        }
    }
    // Byte-fed Host dials through openDialedLocator only; the URI wrapper is gone.
    const open_dialed_ban = [_]struct { path: []const u8, banned: []const []const u8 }{
        .{ .path = "src/driver/core/host.zig", .banned = &.{"pub fn openDialed(self: *Host, locator_uri"} },
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
    // The byte-fed Host suite holds the same ban as one rule over its whole
    // directory, so a new test file there cannot reopen the URI wrapper.
    if (util.concatDirFiles(io, gpa, root, "test/driver/core_host", allZig) catch null) |suite| {
        defer gpa.free(suite);
        if (std.mem.indexOf(u8, suite, ".openDialed(") != null) {
            try appendViolation(gpa, violations, "test/driver/core_host/: forbidden `.openDialed(` — use openDialedLocator / parts-in-hand dial", .{});
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
            .path = "bindings/python/glowcap/_session/",
            .banned = &.{
                "establish_dialed(node, tcp_locator",
                "establish_dialed(cls, tcp_locator",
                "await cls.establish_dialed(node, tcp_locator",
                "def _mint_dialed(",
                "def _open_dialed(",
                "glowcap_host_session_open_dialed(",
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
            .path = "bindings/python/smoke/runtime.py",
            .banned = &.{
                "_mint_dialed(Node(), tcp_locator",
                "._mint_dialed_locator(",
                "Connection.connect(",
            },
        },
        .{
            .path = "bindings/python/smoke/conversation.py",
            .banned = &.{
                "_mint_dialed(Node(), tcp_locator",
                "._mint_dialed_locator(",
                "Connection.connect(",
            },
        },
        .{
            .path = "bindings/python/smoke/lifecycle/__init__.py",
            .banned = &.{
                "_mint_dialed(Node(), tcp_locator",
                "._mint_dialed_locator(",
                "Connection.connect(",
            },
        },
        .{
            .path = "bindings/python/smoke/lifecycle/close.py",
            .banned = &.{
                "_mint_dialed(Node(), tcp_locator",
                "._mint_dialed_locator(",
                "Connection.connect(",
            },
        },
        .{
            .path = "bindings/python/smoke/verbs/__init__.py",
            .banned = &.{
                "_mint_dialed(Node(), tcp_locator",
                "._mint_dialed_locator(",
                "Connection.connect(",
            },
        },
        .{
            .path = "bindings/python/smoke/verbs/authority.py",
            .banned = &.{
                "_mint_dialed(Node(), tcp_locator",
                "._mint_dialed_locator(",
                "Connection.connect(",
            },
        },
        .{
            .path = "bindings/python/smoke/transports.py",
            .banned = &.{
                "_mint_dialed(Node(), tcp_locator",
                "._mint_dialed_locator(",
                "Connection.connect(",
            },
        },
        .{
            .path = "bindings/python/smoke/failures.py",
            .banned = &.{
                "_mint_dialed(Node(), tcp_locator",
                "._mint_dialed_locator(",
                "Connection.connect(",
            },
        },
        .{
            .path = "bindings/python/glowcap/_session/",
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
            .path = "bindings/rust/src/session/establish.rs",
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
            .path = "bindings/ts/runtime/session/",
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
                "glowcap_host_session_open_dialed ",
                "(define (dial-tcp ",
                "(define (connect-tcp ",
            },
        },
        .{
            .path = "bindings/racket/private/ffi-host.rkt",
            .banned = &.{"(define-driver glowcap_host_session_open_dialed\n"},
        },
        .{
            .path = "src/c_abi/host/mod.zig",
            .banned = &.{"pub export fn glowcap_host_session_open_dialed("},
        },
    };
    for (dial_uri_mint) |entry| {
        const contents = (try readSourceSubject(io, gpa, root, entry.path)) orelse {
            try appendViolation(gpa, violations, "{s}: failed to read for dial URI-mint ban", .{entry.path});
            continue;
        };
        defer gpa.free(contents);
        for (entry.banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — host:port dials use establish_dialed_locator / open_dialed_locator, not tcp_locator→open_dialed", .{ entry.path, needle });
            }
        }
    }

    // `checkIrohLoopConvergence` holds the structural guard against a
    // resident-local serve loop in the iroh provider.
}

fn allZig(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".zig");
}
