//! The per-verb binding spines — promise, Rust connection, GC, dial, and
//! listen — one shared shape per verb across the four bindings.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const fileContains = util.fileContains;
const containsAsSymbol = util.containsAsSymbol;
const extractBraceBlock = util.extractBraceBlock;
const readSourceSubject = util.readSourceSubject;

/// Binding spine Pass 3a: each binding keeps a named `promise` module for the
/// RemotePromise / session-vow handle and pipelined projection. Grep-level —
/// catches silent deletes, not wrong semantics.
pub fn checkBindingPromiseSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const mods = [_]struct {
        path: []const u8,
        markers: []const []const u8,
    }{
        .{
            .path = "bindings/ts/runtime/promise.ts",
            // `failed` is the third state arm: a send that could not be issued
            // at all. It has to exist in every binding that has the other two,
            // because `send` returns its handle synchronously — so without it
            // the only way to report a closed session is to throw, which is a
            // synchronous failure channel on a promise and escapes the caller's
            // own `.catch`. Rust carried this arm alone for a while, and the
            // two that lacked it both shipped that trap.
            .markers = &.{ "class RemotePromise", "index(", "untag(", "get(", "awaitMinted", "fetchLike", "promiseFor", "sendFar", "listenFar", "static failed", "\"failed\"", "pancake_host_vow_index", "pancake_host_vow_untag", "pancake_host_vow_get" },
        },
        .{
            .path = "bindings/python/pancake/_promise.py",
            .markers = &.{ "class RemotePromise", "def index", "def untag", "def get", "_await_minted", "_fetch_like", "def _promise_for", "def _send_far", "def _listen_far", "def failed", "class Failed", "pancake_host_vow_get" },
        },
        .{
            .path = "bindings/rust/src/promise.rs",
            .markers = &.{ "struct RemotePromise", "fn index", "fn untag", "fn get", "pancake_host_vow_index", "pancake_host_vow_get", "await_minted", "fetch_like", "fn send_promise", "fn listen_far", "Failed(" },
        },
        .{
            .path = "bindings/racket/private/promise.rkt",
            .markers = &.{ "session-vow", "settle-vow!", "session-index", "session-untag", "session-get", "pancake_host_vow_index", "pancake_host_vow_get", "await-vow", "blocking-fetch", "session-far-send", "listen-far", "pancake_host_session_send", "pancake_host_session_tell", "pancake_host_vow_send" },
        },
    };
    for (mods) |mod| {
        root.access(io, mod.path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — promise veneer module (binding spine Pass 3a)", .{mod.path});
            continue;
        };
        const contents = root.readFileAlloc(io, mod.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for promise-spine check with {s}", .{ mod.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (mod.markers) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: promise module missing `{s}`", .{ mod.path, needle });
            }
        }
    }

    // Fetch/enliven mint→await bodies and far-send promise factories live in
    // promise (Pass 4b / 4d), not session.
    const banned = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/ts/runtime/session/", .needle = "async #fetchLike" },
        .{ .path = "bindings/ts/runtime/session/", .needle = "#promiseFor(" },
        .{ .path = "bindings/python/pancake/_session/", .needle = "async def _fetch_like" },
        .{ .path = "bindings/python/pancake/_session/", .needle = "async def _await_minted" },
        .{ .path = "bindings/python/pancake/_session/", .needle = "def _promise_for" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "async fn await_minted" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "async fn fetch_like" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "fn send_promise" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (await-vow" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (blocking-fetch" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (session-far-send" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "pancake_host_session_send" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "pancake_host_session_tell" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "pancake_host_vow_send" },
    };
    for (banned) |b| {
        const contents = (try readSourceSubject(io, gpa, root, b.path)) orelse {
            try appendViolation(gpa, violations, "{s}: failed to read for promise-fetch ban", .{b.path});
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, b.needle) != null) {
            try appendViolation(gpa, violations, "{s}: `{s}` belongs in promise, not session (Pass 4b/4d)", .{ b.path, b.needle });
        }
    }
}

/// Binding spine Pass 5 (Rust): the one application `Ref` lives with
/// `Argument` in `lib.rs`; `Caretaker` / `SessionShared` live in
/// `session_shared.rs`, not `session.rs`. Grep-level.
pub fn checkBindingRustConnSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const path = "bindings/rust/src/session_shared.rs";
    root.access(io, path, .{}) catch {
        try appendViolation(gpa, violations, "{s}: file must exist — Rust session_shared module (binding spine Pass 5)", .{path});
        return;
    };
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for rust session_shared check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);
    for ([_][]const u8{ "pub struct Caretaker", "pub(crate) struct SessionShared", "fn tell(" }) |needle| {
        if (std.mem.indexOf(u8, contents, needle) == null) {
            try appendViolation(gpa, violations, "{s}: session_shared module missing `{s}`", .{ path, needle });
        }
    }
    try expectFileContains(io, gpa, root, violations, "bindings/rust/src/value.rs", &.{"pub struct Ref"});
    try expectFileContains(io, gpa, root, violations, "bindings/rust/src/lib.rs", &.{"pub use value::{Argument, Ref};"});
    const banned = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/rust/src/session.rs", .needle = "pub struct Ref" },
        .{ .path = "bindings/rust/src/session_shared.rs", .needle = "pub struct Ref" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "pub struct Caretaker" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "pub(crate) struct SessionShared" },
    };
    for (banned) |b| {
        const session = root.readFileAlloc(io, b.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for rust session_shared ban with {s}", .{ b.path, @errorName(err) });
            continue;
        };
        defer gpa.free(session);
        if (std.mem.indexOf(u8, session, b.needle) != null) {
            try appendViolation(gpa, violations, "{s}: `{s}` is outside its Rust binding owner (Pass 5)", .{ b.path, b.needle });
        }
    }
}

/// Binding spine Pass 3b: each binding keeps a named `gc` module for ADR-0063
/// distributed GC (opt-in track + drain). Grep-level.
pub fn checkBindingGcSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const mods = [_]struct {
        path: []const u8,
        markers: []const []const u8,
    }{
        .{
            .path = "bindings/ts/runtime/gc.ts",
            .markers = &.{ "class HostGc", "interface GcHandle", "pancake_host_ref_release", "trackArgument(", "drainGc(", "bind(" },
        },
        .{
            .path = "bindings/python/pancake/_gc.py",
            .markers = &.{ "class HostGc", "class GcHandle", "def bind_host", "pancake_host_ref_release", "def track_argument", "def drain_gc", "def bind" },
        },
        .{
            .path = "bindings/rust/src/gc.rs",
            .markers = &.{ "struct CapabilityGuard", "pancake_host_ref_release", "fn drain", "fn track_argument" },
        },
        .{
            .path = "bindings/racket/private/gc.rkt",
            .markers = &.{ "session-with-gc!", "track-argument!", "drain-gc!", "pancake_host_ref_release" },
        },
    };
    for (mods) |mod| {
        root.access(io, mod.path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — GC veneer module (binding spine Pass 3b)", .{mod.path});
            continue;
        };
        const contents = root.readFileAlloc(io, mod.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for gc-spine check with {s}", .{ mod.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (mod.markers) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: gc module missing `{s}`", .{ mod.path, needle });
            }
        }
    }

    // Track/drain bodies live in gc, not session (Pass 3b).
    const banned = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/ts/runtime/session/", .needle = "\ttrackArgument(" },
        .{ .path = "bindings/ts/runtime/session/", .needle = "#drainGc(" },
        .{ .path = "bindings/ts/runtime/session/", .needle = "pancake_host_ref_release" },
        .{ .path = "bindings/python/pancake/_session/", .needle = "def track_argument" },
        .{ .path = "bindings/python/pancake/_session/", .needle = "def _drain_gc" },
        .{ .path = "bindings/python/pancake/_session/", .needle = "def _on_capability_dropped" },
        .{ .path = "bindings/python/pancake/_session/", .needle = "pancake_host_ref_release" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "fn track_argument" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "pancake_host_ref_release" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "pancake_host_ref_release" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (track-argument!" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (drain-gc!" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (session-with-gc!" },
    };
    for (banned) |b| {
        const contents = (try readSourceSubject(io, gpa, root, b.path)) orelse {
            try appendViolation(gpa, violations, "{s}: failed to read for gc-session ban", .{b.path});
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, b.needle) != null) {
            try appendViolation(gpa, violations, "{s}: `{s}` belongs in gc, not session (Pass 3b)", .{ b.path, b.needle });
        }
    }

    // Python HostGc must not poke owner privates — GcHandle owns the seam.
    const py_gc = "bindings/python/pancake/_gc.py";
    const py_gc_contents = root.readFileAlloc(io, py_gc, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for GcHandle check with {s}", .{ py_gc, @errorName(err) });
        return;
    };
    defer gpa.free(py_gc_contents);
    for ([_][]const u8{ "session._host", "session._loop", "session._released", "getattr(session", "._s._" }) |needle| {
        if (std.mem.indexOf(u8, py_gc_contents, needle) != null) {
            try appendViolation(gpa, violations, "{s}: `{s}` — HostGc must use GcHandle, not owner privates", .{ py_gc, needle });
        }
    }

    // Python owning modules must use Session/Host binding-internal seams
    // (raw/host/gc/hosted/…), not underscore reach-ins — the same class of
    // smell as the pre-fix GC getattr path.
    const py_seam = [_]struct { path: []const u8, needles: []const []const u8 }{
        .{ .path = "bindings/python/pancake/_pump.py", .needles = &.{ "session._", "host._" } },
        .{ .path = "bindings/python/pancake/_promise.py", .needles = &.{"session._"} },
        .{ .path = "bindings/python/pancake/_trampoline.py", .needles = &.{"session._"} },
        .{ .path = "bindings/python/pancake/_action.py", .needles = &.{ "host._", "conn._" } },
        .{ .path = "bindings/python/pancake/_host/__init__.py", .needles = &.{"conn._"} },
        .{ .path = "bindings/python/pancake/_host/finalizer.py", .needles = &.{"conn._"} },
        .{ .path = "bindings/python/pancake/_host/lifecycle.py", .needles = &.{"conn._"} },
        .{ .path = "bindings/python/pancake/_host/progress.py", .needles = &.{"conn._"} },
        .{ .path = "bindings/python/pancake/_host/publication.py", .needles = &.{"conn._"} },
    };
    for (py_seam) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for private-reach ban with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (row.needles) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: `{s}` — use binding-internal Session/Host seams, not privates", .{ row.path, needle });
            }
        }
    }
}

/// Binding spine Pass 3c: every binding exposes one managed Runtime over
/// explicit provider/connector composition. Generic dial code owns handoff
/// redemption and terminal reporting, but never names a concrete transport.
pub fn checkBindingDialSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const mods = [_]struct {
        path: []const u8,
        markers: []const []const u8,
        banned: []const []const u8,
    }{
        .{
            .path = "bindings/ts/runtime/dial.ts",
            .markers = &.{ "dialWithConnector", "dialExporter", "runDialTicket", "import type { Connector }" },
            .banned = &.{ "pancake_host_plan_dial", "@pancake/tcp", "@pancake/iroh", "@pancake/webrtc", "net.connect(", "openWebSocketChannel" },
        },
        .{
            .path = "bindings/python/pancake/_dial.py",
            .markers = &.{ "class Runtime", "def open(", "async def connect(", "dial_parsed_locator", "dial_exporter", "run_dial_ticket" },
            .banned = &.{ "pancake_host_plan_dial", "from .tcp", "from . import iroh", "from .relay", "from ._ws" },
        },
        .{
            .path = "bindings/rust/src/dial.rs",
            .markers = &.{ "dial_with_connector", "dial_exporter", "run_dial_ticket", "TransportOperationOptions" },
            .banned = &.{ "pancake_host_plan_dial", "tokio::net::TcpStream", "crate::iroh::", "crate::relay_route::", "crate::tcp::", "crate::ws_stream::" },
        },
        .{
            .path = "bindings/racket/private/dial.rkt",
            .markers = &.{ "open-runtime", "runtime-connect", "dial-exporter", "run-dial!" },
            .banned = &.{ "pancake_host_plan_dial", "(define (connect", "tcp-provider.rkt", "iroh-companion.rkt", "relay-provider.rkt", "ws-transport.rkt", "racket/tcp" },
        },
    };
    for (mods) |mod| {
        root.access(io, mod.path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — dial module (binding spine Pass 3c)", .{mod.path});
            continue;
        };
        const contents = root.readFileAlloc(io, mod.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for dial-spine check with {s}", .{ mod.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (mod.markers) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: dial module missing `{s}`", .{ mod.path, needle });
            }
        }
        for (mod.banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: generic dial module names concrete transport dependency `{s}` — product composition owns it", .{ mod.path, needle });
            }
        }
    }

    const runtimes = [_]struct { path: []const u8, markers: []const []const u8 }{
        .{ .path = "bindings/ts/runtime/runtime.ts", .markers = &.{ "class Runtime", "static async open", "async connect", "adoptHost", "DriverProvider", "Connector" } },
        .{ .path = "bindings/python/pancake/_dial.py", .markers = &.{ "class Runtime", "def open(", "async def connect(", "adopt_host", "Provider", "Connector" } },
        .{ .path = "bindings/rust/src/runtime.rs", .markers = &.{ "pub struct Runtime", "pub struct RuntimeConfig", "pub async fn open", "pub async fn connect", "adopt_host", "Provider", "Connector" } },
        .{ .path = "bindings/racket/private/dial.rkt", .markers = &.{ "(struct runtime", "(define (open-runtime", "(define (runtime-connect", "#:adopt-host", "driver-provider?", "byte-connector?" } },
    };
    for (runtimes) |runtime| {
        try expectFileContains(io, gpa, root, violations, runtime.path, runtime.markers);
    }

    const provider_symbol_mirrors = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/ts/runtime/transport.ts", .needle = "interface DriverProvider {\n\treadonly transports" },
        .{ .path = "bindings/python/pancake/_transport.py", .needle = "class Provider:\n" ++
            "    \"\"\"One explicitly composed native provider package." ++
            "\n\n    transports:" },
        .{ .path = "bindings/rust/src/driver_loop/provider.rs", .needle = "pub struct Provider {\n\ttransports:" },
        .{ .path = "bindings/racket/private/transport.rkt", .needle = "(struct driver-provider (transports" },
    };
    for (provider_symbol_mirrors) |mirror| {
        if (try fileContains(io, gpa, root, mirror.path, mirror.needle)) {
            try appendViolation(gpa, violations, "{s}: provider transport inventory duplicates the native registry; providers install, connectors advertise", .{mirror.path});
        }
    }

    const obsolete_compositions = [_][]const u8{
        "bindings/ts/runtime/transport_composition.ts",
        "bindings/python/pancake/_transport_composition.py",
        "bindings/rust/src/transport_composition.rs",
        "bindings/racket/private/transport-composition.rkt",
    };
    for (obsolete_compositions) |path| {
        root.access(io, path, .{}) catch continue;
        try appendViolation(gpa, violations, "{s}: obsolete transport-composition dispatcher must stay deleted; Runtime composes explicit providers/connectors", .{path});
    }
}

/// Binding spine Pass 3d: each binding keeps transport-specific construction
/// in its transport-owned listen module and generic listener lifecycle in its
/// server module. Grep-level.
pub fn checkBindingListenSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const mods = [_]struct {
        path: []const u8,
        markers: []const []const u8,
    }{
        .{
            .path = "bindings/ts/tcp/listen.ts",
            .markers = &.{ "class Server", "DriverListener", "function listen", "function listenKeyed", "function listenNoise", "installTcpProvider", "addressDesignator" },
        },
        .{
            .path = "bindings/python/pancake/_tcp_listen.py",
            .markers = &.{ "class Server", "async def listen", "listen_keyed", "listen_noise", "DriverServer", ".install(", "address_designator" },
        },
        .{
            .path = "bindings/rust/src/tcp_listen.rs",
            .markers = &.{ "struct Server", "crate::server::LoopListener", "pub(crate) async fn listen", "pub(crate) async fn listen_keyed", "ensure_loop_provider", "tcp::address_designator" },
        },
        .{
            .path = "bindings/racket/private/tcp-listen.rkt",
            .markers = &.{ "make-loop-server", "driver-loop-add-tcp!", "loop-listen!", "(define server?", "server-locator", "listen-keyed-tcp", "listen-noise-tcp", "(define (listen", "tcp-address-designator" },
        },
    };
    for (mods) |mod| {
        root.access(io, mod.path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — listen module (binding spine Pass 3d)", .{mod.path});
            continue;
        };
        const contents = root.readFileAlloc(io, mod.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for listen-spine check with {s}", .{ mod.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (mod.markers) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: listen module missing `{s}`", .{ mod.path, needle });
            }
        }
    }

    const rust_surface_path = "bindings/rust/src/tcp.rs";
    const rust_surface = root.readFileAlloc(io, rust_surface_path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read Rust TCP surface with {s}", .{ rust_surface_path, @errorName(err) });
        return;
    };
    defer gpa.free(rust_surface);
    const rust_markers = [_][]const u8{ "pub async fn listen", "pub mod keyed", "pub mod noise", "KeyedListenOptions", "ListenerIdentity" };
    for (rust_markers) |marker| {
        if (std.mem.indexOf(u8, rust_surface, marker) == null) {
            try appendViolation(gpa, violations, "{s}: missing consolidated listener surface `{s}`", .{ rust_surface_path, marker });
        }
    }
    const rust_banned = [_][]const u8{ "listen_with_", "listen_keyed_tcp", "listen_noise_tcp", "listen_advertised" };
    for (rust_banned) |banned| {
        if (std.mem.indexOf(u8, rust_surface, banned) != null) {
            try appendViolation(gpa, violations, "{s}: stale listener variant `{s}` — each TCP profile owns one `listen` operation plus options", .{ rust_surface_path, banned });
        }
    }

    const rust_transport_surfaces = [_]struct {
        path: []const u8,
        markers: []const []const u8,
        banned: []const []const u8,
    }{
        .{
            .path = "bindings/rust/src/iroh.rs",
            .markers = &.{ "pub struct Config", "pub struct Netlayer", "pub struct Stream", "pub struct Server", "pub struct ListenOptions", "pub async fn listen" },
            .banned = &.{ "pub struct IrohConfig", "pub struct IrohNetlayer", "pub struct IrohStream", "pub struct IrohServer", "listen_with_seed", "listen_with_host" },
        },
        .{
            .path = "bindings/rust/src/onion.rs",
            .markers = &.{ "pub struct Config", "pub struct Netlayer", "pub struct Server", "pub struct ListenOptions", "pub fn provider", "pub async fn listen" },
            .banned = &.{ "pub struct OnionServer", "pub struct ConnectOptions", "pub async fn connect", "listen_with_host", "connect_with_host" },
        },
    };
    for (rust_transport_surfaces) |surface| {
        const contents = root.readFileAlloc(io, surface.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read Rust transport surface with {s}", .{ surface.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (surface.markers) |marker| {
            if (std.mem.indexOf(u8, contents, marker) == null) {
                try appendViolation(gpa, violations, "{s}: missing module-owned role `{s}`", .{ surface.path, marker });
            }
        }
        for (surface.banned) |banned| {
            if (std.mem.indexOf(u8, contents, banned) != null) {
                try appendViolation(gpa, violations, "{s}: stale public spelling `{s}` — module context owns the transport name and options own variants", .{ surface.path, banned });
            }
        }
    }

    // The native loop is multi-listener and ACCEPTED carries the listener id.
    // Every binding must preserve that routing key through its queue and into
    // the server's accept call; flattening to one global accept queue silently
    // hands a session to the wrong server as soon as one Host listens on two
    // transports.
    const loop_accept_routing = [_]struct {
        path: []const u8,
        markers: []const []const u8,
    }{
        .{
            .path = "bindings/ts/runtime/driver_loop/drive.ts",
            .markers = &.{"_accepts.get(event.listener)"},
        },
        .{
            .path = "bindings/ts/runtime/internal/driver_event.ts",
            .markers = &.{"listener: listenerId"},
        },
        .{
            .path = "bindings/ts/runtime/internal/server.ts",
            .markers = &.{"this.#listener.accept()"},
        },
        .{
            .path = "bindings/python/pancake/_loop/progress.py",
            .markers = &.{"self._accepts.get(event.listener_id)"},
        },
        .{
            .path = "bindings/python/pancake/_server.py",
            .markers = &.{"accept_session(self._listener)"},
        },
        .{
            .path = "bindings/rust/src/driver_loop/progress.rs",
            .markers = &.{ "LoopEvent::Accepted { listener, session }", "accepts.borrow_mut().push_back((listener, session))" },
        },
        .{
            .path = "bindings/rust/src/server.rs",
            .markers = &.{"self.lp.accept(self.listener)"},
        },
        .{ .path = "bindings/racket/private/loop/core.rkt", .markers = &.{"(driver-event-accepted-listener-id e) #f)"} },
        .{ .path = "bindings/racket/private/loop/listeners.rkt", .markers = &.{"(loop-server-listener s)"} },
    };
    for (loop_accept_routing) |binding| {
        const contents = root.readFileAlloc(io, binding.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for listener-id routing check with {s}", .{ binding.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (binding.markers) |marker| {
            if (std.mem.indexOf(u8, contents, marker) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — ACCEPTED must remain routed by listener id", .{ binding.path, marker });
            }
        }
    }

    // Session must not re-export dial/listen — the barrel owns that graph.
    const reexport_bans = [_]struct {
        path: []const u8,
        banned: []const []const u8,
    }{
        .{
            .path = "bindings/ts/runtime/session.ts",
            .banned = &.{ "export { connect }", "from \"./dial.ts\"", "from \"./listen.ts\"", "export { RemotePromise }" },
        },
        .{
            .path = "bindings/racket/private/session.rkt",
            .banned = &.{
                "(all-from-out \"dial.rkt\")",
                "(all-from-out \"tcp-listen.rkt\")",
                "(all-from-out \"action.rkt\")",
                "(all-from-out \"pump.rkt\")",
                "(all-from-out \"async.rkt\")",
                "(all-from-out \"host.rkt\")",
                "(all-from-out \"promise.rkt\")",
                "(all-from-out \"gc.rkt\")",
            },
        },
        .{
            .path = "bindings/rust/src/session.rs",
            .banned = &.{ "pub use crate::promise::", "pub use crate::dial::", "pub use crate::listen::" },
        },
        .{
            .path = "bindings/python/pancake/_session/",
            .banned = &.{ "from ._dial import", "from ._listen import", "async def connect", "class Server", "class KeyedTcpServer" },
        },
    };
    for (reexport_bans) |entry| {
        const contents = (try readSourceSubject(io, gpa, root, entry.path)) orelse {
            try appendViolation(gpa, violations, "{s}: failed to read for dial/listen re-export ban", .{entry.path});
            continue;
        };
        defer gpa.free(contents);
        for (entry.banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — dial/listen/promise re-exports belong on the barrel, not session", .{ entry.path, needle });
            }
        }
    }
}
