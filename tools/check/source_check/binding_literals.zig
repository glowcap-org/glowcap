//! Binding transport and hint literal hygiene: those strings live only in
//! the generated projections of `model.transport`, and every production
//! module imports the generated names. Split from `captp_io_spine.zig`,
//! whose subject is the completion-loop dial spine; the two run together in
//! the source-check driver.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;
const readSourceSubject = util.readSourceSubject;

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // Binding transport and hint literals live only in generated projections
    // of model.transport; production modules import those names.
    {
        const allowed = [_][]const u8{
            "bindings/python/pancake/_constants_gen.py",
            "bindings/rust/src/abi_constants_gen.rs",
            "bindings/ts/abi/constants.ts",
            "bindings/racket/private/constants-gen.rkt",
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
            var dir = root.openDir(io, bind_root, .{ .iterate = true }) catch |err| {
                try appendViolation(gpa, violations, "{s}: cannot be opened for the binding-literal check ({s})", .{ bind_root, @errorName(err) });
                continue;
            };
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
        // Socket-address spelling lives below transport packages, never in the
        // generic OCapN locator or session modules. Hint→host:port for dial is
        // still core `planDial` / `tcpConnectHostPort` (ADR-0078).
        const locator_grammar_home = [_]struct {
            connection: []const u8,
            owner: []const u8,
            banned_in_connection: []const []const u8,
            required_in_owner: []const []const u8,
        }{
            .{
                .connection = "bindings/python/pancake/_session/",
                .owner = "bindings/python/pancake/_socket_address.py",
                .banned_in_connection = &.{
                    "def _socket_addr_designator",
                    "def _host_port_from_direct_hint",
                    "def socket_addr_designator",
                    "def host_port_from_direct_hint",
                },
                .required_in_owner = &.{
                    "def address_designator",
                },
            },
            .{
                .connection = "bindings/ts/runtime/session.ts",
                .owner = "bindings/ts/tcp/address.ts",
                .banned_in_connection = &.{
                    "function socketAddrDesignator",
                    "function hostPortFromDirectHint",
                },
                .required_in_owner = &.{
                    "export function addressDesignator",
                },
            },
            .{
                .connection = "bindings/rust/src/session.rs",
                .owner = "bindings/rust/src/tcp.rs",
                .banned_in_connection = &.{
                    "fn host_port_from_direct_hint",
                    "fn socket_addr_designator",
                },
                .required_in_owner = &.{
                    "pub fn address_designator",
                },
            },
            .{
                .connection = "bindings/racket/private/session.rkt",
                .owner = "bindings/racket/private/socket-address.rkt",
                .banned_in_connection = &.{
                    "(define (socket-addr-designator",
                    "(define (host-port-from-direct-hint",
                },
                .required_in_owner = &.{
                    "(define (tcp-address-designator",
                },
            },
        };
        for (locator_grammar_home) |entry| {
            const conn_contents = (try readSourceSubject(io, gpa, root, entry.connection)) orelse {
                try appendViolation(gpa, violations, "{s}: failed to read for locator-grammar home check", .{entry.connection});
                continue;
            };
            defer gpa.free(conn_contents);
            for (entry.banned_in_connection) |needle| {
                if (std.mem.indexOf(u8, conn_contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — define socket-address spelling in {s}", .{ entry.connection, needle, entry.owner });
                }
            }
            const owner_contents = root.readFileAlloc(io, entry.owner, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for socket-address owner check with {s}", .{ entry.owner, @errorName(err) });
                continue;
            };
            defer gpa.free(owner_contents);
            for (entry.required_in_owner) |needle| {
                if (std.mem.indexOf(u8, owner_contents, needle) == null) {
                    try appendViolation(gpa, violations, "{s}: missing `{s}` — socket-address spelling must live here", .{ entry.owner, needle });
                }
            }
        }
        // TCP dials always split the designator through the core host:port grammar;
        // connect must not bypass with a parse-time hostPort cache.
        const tcp_dial_one_path = [_]struct {
            path: []const u8,
            banned: []const []const u8,
        }{
            .{ .path = "bindings/ts/runtime/dial.ts", .banned = &.{ "opts.hostPort", "hostPort: loc.hostPort" } },
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
        // Bindings consume DialPlan; locator hints are not host:port policy.
        const binding_hint_split = [_]struct {
            path: []const u8,
            banned: []const []const u8,
        }{
            .{ .path = "bindings/python/pancake/_locator.py", .banned = &.{ "def host_port_from_direct_hint", "def _host_port_from_direct_hint" } },
            .{ .path = "bindings/ts/runtime/locator.ts", .banned = &.{ "function hostPortFromDirectHint", "export function hostPortFromDirectHint" } },
            .{ .path = "bindings/rust/src/uri.rs", .banned = &.{ "fn host_port_from_direct_hint", "pub fn host_port_from_direct_hint" } },
            .{ .path = "bindings/racket/private/locator.rkt", .banned = &.{"(define (host-port-from-direct-hint"} },
        };
        for (binding_hint_split) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for binding hint-split check with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — hint→host:port is planDial policy (ADR-0078), not a binding helper", .{ entry.path, needle });
                }
            }
        }
    }
}
