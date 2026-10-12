//! Binding behavioral posture bans: the pump's borrowed feed, RemotePromise
//! as a sum, the retired DialPlan decoder, FAIL as a core-issued result,
//! gift argv designators through the TCP package, and rooms iroh dials that
//! parse before they route.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    {
        // Binding pump feed posture: one borrowed call per chunk, the core
        // owns framing and the unconsumed stream tail, so a binding-side
        // inbox must not come back.
        const pump_borrow = [_]struct { path: []const u8, required: []const []const u8, banned: []const []const u8 }{
            .{
                .path = "bindings/ts/runtime/pump.ts",
                .required = &.{"ab(chunk)"},
                .banned = &.{ "appendInbox", "h.inbox" },
            },
            .{
                .path = "bindings/rust/src/pump.rs",
                .required = &.{"chunk.as_ptr()"},
                .banned = &.{"shared.inbox"},
            },
            .{
                .path = "bindings/python/glowcap/_pump.py",
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
                .path = "bindings/ts/runtime/promise.ts",
                .required = &.{ "export type PromiseState", "static far(", "static local(" },
                .banned = &.{"readonly vow: bigint | null"},
            },
            .{
                .path = "bindings/python/glowcap/_promise.py",
                .required = &.{ "class PromiseState", "class Far", "class Local", "def far(", "def local(", "self._kind" },
                .banned = &.{ "vow: Optional[int]", "vow: Optional[int] = None", "self._state =" },
            },
            .{
                .path = "bindings/rust/src/promise.rs",
                .required = &.{ "enum PromiseState", "Call(", "Observer(", "Failed(" },
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
        // The retired binding-side DialPlan decoder must not reappear. Transport
        // packages consume complete locators through providers/connectors.
        const dial_alias = [_]struct { path: []const u8, required: []const []const u8, banned: []const []const u8 }{
            .{
                .path = "bindings/ts/runtime/dial.ts",
                .required = &.{},
                .banned = &.{ "DIAL_SHAPE_IROH", "readBytes(ptr, len)" },
            },
            .{
                .path = "bindings/python/glowcap/_dial.py",
                .required = &.{},
                .banned = &.{ "DIAL_SHAPE_IROH", "bytes(buf)[", "return ctypes.string_at" },
            },
            .{
                .path = "bindings/rust/src/dial.rs",
                .required = &.{},
                .banned = &.{ "DIAL_SHAPE_IROH", "view_string(ptr, len)" },
            },
            .{
                .path = "bindings/racket/private/dial.rkt",
                .required = &.{},
                .banned = &.{ "DIAL-SHAPE-IROH", "(bytes<-c ptr len)" },
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
        // FAIL classification is a driver_core fact carried by the action's
        // result code. Bindings may project that code into native error types;
        // they must not infer it from wrapper lifecycle state.
        const binding_failure_inference = [_]struct { path: []const u8, banned: []const u8 }{
            .{ .path = "bindings/rust/src/host.rs", .banned = "vow_session_closing" },
            .{ .path = "bindings/rust/src/host/lifecycle.rs", .banned = "vow_session_closing" },
            .{ .path = "bindings/rust/src/host/progress.rs", .banned = "vow_session_closing" },
            .{ .path = "bindings/rust/src/host/public.rs", .banned = "vow_session_closing" },
            .{ .path = "bindings/rust/src/host/vows.rs", .banned = "vow_session_closing" },
            .{ .path = "bindings/ts/runtime/host.ts", .banned = "vowSessionClosing" },
            .{ .path = "bindings/ts/runtime/host/state.ts", .banned = "vowSessionClosing" },
            .{ .path = "bindings/ts/runtime/host/lifecycle.ts", .banned = "vowSessionClosing" },
            .{ .path = "bindings/ts/runtime/host/application.ts", .banned = "vowSessionClosing" },
            .{ .path = "bindings/ts/runtime/host/drive.ts", .banned = "vowSessionClosing" },
            .{ .path = "bindings/python/glowcap/_host/__init__.py", .banned = "vow_session_closing" },
            .{ .path = "bindings/python/glowcap/_host/finalizer.py", .banned = "vow_session_closing" },
            .{ .path = "bindings/python/glowcap/_host/lifecycle.py", .banned = "vow_session_closing" },
            .{ .path = "bindings/python/glowcap/_host/progress.py", .banned = "vow_session_closing" },
            .{ .path = "bindings/python/glowcap/_host/publication.py", .banned = "vow_session_closing" },
            .{ .path = "bindings/racket/private/session.rkt", .banned = "current-breaking" },
        };
        for (binding_failure_inference) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for core-owned FAIL classification with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, entry.banned) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — bindings must project the core-issued FAIL result", .{ entry.path, entry.banned });
            }
        }
        // Gift interop argv must mint host:port designators through the TCP package.
        const gift_addr_designator = [_]struct {
            path: []const u8,
            required: []const u8,
            banned: []const []const u8,
        }{
            .{
                .path = "interop/goblins_interop/deno_gift_client.ts",
                .required = "tcp.addressDesignator",
                .banned = &.{"`${HOST}:${gifterPort}`,"},
            },
            .{
                .path = "interop/goblins_interop/python_gift_client.py",
                .required = "tcp.address_designator",
                .banned = &.{"f\"{HOST}:{gifter_port}\""},
            },
            .{
                .path = "interop/goblins_interop/racket_gift_client.rkt",
                .required = "tcp-address-designator",
                .banned = &.{"(format \"~a:~a\" HOST gifter-port)"},
            },
            .{
                .path = "interop/goblins_interop/rust_gift_client.rs",
                .required = "tcp::address_designator",
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
                try appendViolation(gpa, violations, "{s}: missing `{s}` — gift interop argv must use its TCP package", .{ entry.path, entry.required });
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use the TCP package for gift argv", .{ entry.path, needle });
                }
            }
        }
        // Rooms iroh dials parse first; hint→Direct, else discovery, never
        // blanket Direct on `://`. Reachability belongs to the iroh provider;
        // Runtime.connect receives the unchanged parsed locator.
        const rooms_iroh_dial = [_]struct {
            path: []const u8,
            required: []const u8,
            banned: []const []const u8,
        }{
            .{
                .path = "apps/rooms/lib/locator.ts",
                .required = "runtime.connect(loc",
                .banned = &.{ "connectIroh(", "import { connectIroh" },
            },
            .{
                .path = "apps/rooms/clients/python/room_client.py",
                .required = "await runtime.connect(loc)",
                .banned = &.{"connect_iroh("},
            },
            .{
                .path = "apps/rooms/clients/racket/room-client.rkt",
                .required = "(runtime-connect runtime loc)",
                .banned = &.{"(connect-iroh "},
            },
            .{
                .path = "apps/rooms/clients/rust/room.rs",
                .required = ".connect(&loc, ConnectOptions::default())",
                .banned = &.{"connect_iroh("},
            },
            .{
                .path = "apps/rooms/clients/zig/client.zig",
                .required = "parsePeer",
                .banned = &.{"init(io, null, .direct)"},
            },
            .{
                .path = "apps/rooms/test/support/rooms_server.ts",
                .required = "dialWithRuntime(locator, runtime)",
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
                try appendViolation(gpa, violations, "{s}: missing `{s}` — rooms must pass the parsed locator through a Runtime whose iroh provider owns reachability", .{ entry.path, entry.required });
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — rooms iroh posture follows hints, not blanket Direct", .{ entry.path, needle });
                }
            }
        }
        // Dogfood / unit tests mint host:port designators through the TCP package.
        const dogfood_addr_designator = [_]struct {
            path: []const u8,
            required: []const u8,
            banned: []const []const u8,
        }{
            .{
                .path = "bindings/racket/test/zig-smoke/transports.rkt",
                .required = "tcp-address-designator",
                .banned = &.{ "\"127.0.0.1:9\"", "\"127.0.0.1:1\"", "\"127.0.0.1:2\"", "format-peer-uri \"tcp\"" },
            },
            .{
                .path = "bindings/python/smoke/conversation.py",
                .required = "tcp.address_designator",
                .banned = &.{"\"127.0.0.1:1\""},
            },
            .{
                .path = "bindings/rust/src/session_tests/verbs.rs",
                .required = "crate::tcp::address_designator(&peer.ip().to_string(), peer.port())",
                .banned = &.{ "peer.to_string()", "\"127.0.0.1:0\".to_string()" },
            },
            .{
                .path = "bindings/rust/src/session_tests/wire_ownership.rs",
                .required = "crate::tcp::address_designator(&peer.ip().to_string(), peer.port())",
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
                try appendViolation(gpa, violations, "{s}: missing `{s}` — dogfood designators must use the TCP package", .{ entry.path, entry.required });
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use the TCP package", .{ entry.path, needle });
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
            .{ .path = "bindings/python/glowcap/iroh.py", .banned = &.{ "\"connect_iroh\"", "async def connect_iroh(", "async def connect_iroh_with_node(" } },
            .{ .path = "bindings/rust/src/iroh.rs", .banned = &.{ "pub async fn connect_iroh(", "pub async fn connect_iroh_with_node(" } },
            .{ .path = "bindings/ts/iroh/mod.ts", .banned = &.{ "connectIroh", "_connectIroh" } },
            .{ .path = "bindings/racket/glowcap-iroh.rkt", .banned = &.{"(provide connect-iroh/node\n         listen-iroh"} },
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
        // The public iroh package owns provider/connector construction; generic
        // Runtime and Session modules must not import it.
        iroh_public_surface: {
            const mod_contents = root.readFileAlloc(io, "bindings/ts/iroh/mod.ts", gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "bindings/ts/iroh/mod.ts: failed to read with {s}", .{@errorName(err)});
                break :iroh_public_surface;
            };
            defer gpa.free(mod_contents);
            if (std.mem.indexOf(u8, mod_contents, "listen,") == null) {
                try appendViolation(gpa, violations, "bindings/ts/iroh/mod.ts: missing listen re-export", .{});
            }
            for ([_][]const u8{ "provider,", "connector," }) |marker| {
                if (std.mem.indexOf(u8, mod_contents, marker) == null) {
                    try appendViolation(gpa, violations, "bindings/ts/iroh/mod.ts: missing `{s}` transport composition export", .{marker});
                }
            }
            const conn_contents = root.readFileAlloc(io, "bindings/ts/runtime/session.ts", gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "bindings/ts/runtime/session.ts: failed to read with {s}", .{@errorName(err)});
                break :iroh_public_surface;
            };
            defer gpa.free(conn_contents);
            if (std.mem.indexOf(u8, conn_contents, "import(\"@glowcap/iroh\")") != null) {
                try appendViolation(gpa, violations, "bindings/ts/runtime/session.ts: forbidden public `@glowcap/iroh` dial import — use the dial module", .{});
            }
            const rkt_contents = root.readFileAlloc(io, "bindings/racket/glowcap-iroh.rkt", gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "bindings/racket/glowcap-iroh.rkt: failed to read with {s}", .{@errorName(err)});
                break :iroh_public_surface;
            };
            defer gpa.free(rkt_contents);
            // Provider installation is binding-internal, and what keeps it that
            // way is living in the private tree while the barrels re-export only
            // the intended surface. It must not become a submodule again: Racket's
            // compile manager does not manage submodule requests, so a program
            // running against compiled bytecode cannot reach one without
            // re-expanding the module it sits in.
            if (std.mem.indexOf(u8, rkt_contents, "(module* dial") != null) {
                try appendViolation(gpa, violations, "bindings/racket/glowcap-iroh.rkt: `connect-iroh/node` must stay in private/iroh.rkt, not a `dial` submodule", .{});
            }
            const rkt_impl = root.readFileAlloc(io, "bindings/racket/private/iroh/runtime.rkt", gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "bindings/racket/private/iroh/runtime.rkt: failed to read with {s}", .{@errorName(err)});
                break :iroh_public_surface;
            };
            defer gpa.free(rkt_impl);
            if (std.mem.indexOf(u8, rkt_impl, "iroh-adopt-loop!") == null) {
                try appendViolation(gpa, violations, "bindings/racket/private/iroh/runtime.rkt: must provide `iroh-adopt-loop!` for generic driver dials", .{});
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
        // Every TCP locator constructor spells host:port through one package
        // helper so plain and key-addressed IPv6 cannot drift.
        const tcp_locator_home = [_]struct {
            path: []const u8,
            required: []const u8,
            min_calls: usize,
            banned: []const []const u8,
        }{
            .{
                .path = "bindings/python/glowcap/tcp.py",
                .required = "address_designator(host, port)",
                .min_calls = 2,
                .banned = &.{"{_abi.HINT_DIRECT_ADDRESSES: f\"{host}:{port}\"}"},
            },
            .{
                .path = "bindings/ts/tcp/address.ts",
                .required = "addressDesignator(hostname, port)",
                .min_calls = 2,
                .banned = &.{"HINT_DIRECT_ADDRESSES, `${hostname}:${port}`"},
            },
            .{
                .path = "bindings/rust/src/tcp.rs",
                .required = "address_designator(host, port)",
                .min_calls = 2,
                .banned = &.{},
            },
            .{
                .path = "bindings/racket/glowcap-tcp.rkt",
                .required = "(tcp-address-designator host port)",
                .min_calls = 3,
                .banned = &.{"(hash HINT-DIRECT-ADDRESSES (format \"~a:~a\" host port))"},
            },
        };
        for (tcp_locator_home) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for TCP locator construction with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.count(u8, contents, entry.required) < entry.min_calls) {
                try appendViolation(gpa, violations, "{s}: needs at least {d} `{s}` calls — every TCP profile must use the package address formatter", .{ entry.path, entry.min_calls, entry.required });
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use the TCP package address formatter", .{ entry.path, needle });
                }
            }
        }
        // Sturdyref construction adds authority to a typed locator. Requiring
        // URI text here would reparse the value and reopen the text-shaped dial
        // boundary this pass removed.
        const sturdyref_formatters = [_]struct {
            path: []const u8,
            signature: []const u8,
            forbidden: []const u8,
        }{
            .{ .path = "bindings/python/glowcap/_locator.py", .signature = "def format_sturdyref(locator: Locator,", .forbidden = "parse_locator(locator" },
            .{ .path = "bindings/ts/runtime/locator.ts", .signature = "locator: Locator,", .forbidden = "parseLocator(locator" },
            .{ .path = "bindings/rust/src/uri/format.rs", .signature = "format_sturdyref(locator: &Locator,", .forbidden = "parse_locator(locator" },
            .{ .path = "bindings/racket/private/locator.rkt", .signature = "(define (format-sturdyref loc swissnum #:captp-version captp-version)", .forbidden = "(parse-locator loc" },
        };
        for (sturdyref_formatters) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for typed sturdyref formatter check with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, entry.signature) == null) {
                try appendViolation(gpa, violations, "{s}: sturdyref formatter must accept the typed locator", .{entry.path});
            }
            if (std.mem.indexOf(u8, contents, entry.forbidden) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — sturdyref formatting must not reparse a locator URI", .{ entry.path, entry.forbidden });
            }
        }
        // A server URI must not remint keyed metadata from the bind-host string.
        {
            const path = "bindings/ts/tcp/listen.ts";
            const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for keyed-uri bind-host ban with {s}", .{ path, @errorName(err) });
                return;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, "keyedTcpLocator(this.#designator, this.#host") != null) {
                try appendViolation(gpa, violations, "{s}: forbidden keyedTcpLocator(..., this.#host) — use listener.localAddr()", .{path});
            }
        }
        // Rust listen/accept designators go through tcp::address_designator, not
        // SocketAddr::to_string (Display is close but not the shared grammar).
        {
            const path = "bindings/rust/src/tcp_listen.rs";
            const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for rust designator grammar with {s}", .{ path, @errorName(err) });
                return;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, "tcp::address_designator(&") == null) {
                try appendViolation(gpa, violations, "{s}: missing tcp::address_designator on listen/accept paths", .{path});
            }
            if (std.mem.indexOf(u8, contents, ".map(|addr| addr.to_string())") != null or
                std.mem.indexOf(u8, contents, ".map(|a| a.to_string())") != null)
            {
                try appendViolation(gpa, violations, "{s}: forbidden SocketAddr::to_string for designators — use tcp::address_designator", .{path});
            }
        }
        // Transport and locator-hint strings are generated directly from
        // model.transport. The generator staleness gates hold values and
        // completeness; no hand-maintained presence list belongs here.
    }
}
