//! The embedder pump and behavior trampoline: the byte-fed seam every
//! binding drives the same way, its spine documentation, and the magic
//! error-code contexts.

const std = @import("std");
const util = @import("../util.zig");
const constants = @import("constants.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const fileContains = util.fileContains;
const containsAsSymbol = util.containsAsSymbol;
const extractBraceBlock = util.extractBraceBlock;
const readSourceSubject = util.readSourceSubject;

/// Handwritten binding contexts that discuss, inspect, or raise an ABI error.
/// A negative integer on one of these lines restates generated ABI vocabulary.
const binding_error_context_patterns = [_][]const u8{
    "GLOWCAP_ERR_",
    "code()", // Rust Error::code()
    ".code", // Python and TypeScript error properties
    "exn:fail:glowcap-code",
    "from_code(-", // Rust: Error::from_code(sys::ERR_…)
    "GlowcapError(-", // Python / Deno: GlowcapError(_ERR_… / ERR-less mirror name)
    "(check -", // Racket: (check ERR-…)
};

/// CapTP embedder pump (ADR-0072 / Pass-1 spine gate): each binding keeps a
/// named `pump` module for the conn byte path, mid-turn conn_release parking
/// in the session close path, and the C reference example that compiles the
/// same choreography. Grep-level — catches silent deletes, not wrong order.
pub fn checkBindingEmbedderPump(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const pump_paths = [_][]const u8{
        "bindings/ts/runtime/pump.ts",
        "bindings/python/glowcap/_pump.py",
        "bindings/rust/src/pump.rs",
        "bindings/racket/private/pump.rkt",
    };
    for (pump_paths) |path| {
        root.access(io, path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — EmbedderPump module (binding spine Pass 1)", .{path});
            continue;
        };
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for embedder-pump check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        const ts_pump = std.mem.eql(u8, path, "bindings/ts/runtime/pump.ts");
        const markers = if (ts_pump) &[_][]const u8{
            "glowcap_host_session_feed_packet",
            "take_packet",
            "transport_closed",
        } else &[_][]const u8{
            "glowcap_host_session_feed_bytes",
            "take_outbound",
            "transport_closed",
        };
        for (markers) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: pump missing `{s}` — transport choreography", .{ path, needle });
            }
        }
        // Feed-refusal / last_abort: the FFI reader lives in pump (Pass 1b).
        if (std.mem.indexOf(u8, contents, "glowcap_host_session_last_abort") == null and
            std.mem.indexOf(u8, contents, "last_abort") == null and
            std.mem.indexOf(u8, contents, "last-abort") == null)
        {
            try appendViolation(gpa, violations, "{s}: pump missing last_abort/last-abort — feed-refusal path", .{path});
        }
        // Post-feed action kick / drain (one-loop rule after feed_bytes).
        const kick_ok = std.mem.indexOf(u8, contents, "kickActions") != null or
            std.mem.indexOf(u8, contents, "kick_actions") != null or
            std.mem.indexOf(u8, contents, "drain-host-actions!") != null;
        if (!kick_ok) {
            try appendViolation(gpa, violations, "{s}: pump missing post-feed action kick/drain (kickActions / kick_actions / drain-host-actions!)", .{path});
        }
        // Feed refusal must use the shared drain, not a private take_outbound
        // flush — the same spine as a steady FLUSH (bindings/README checklist).
        const private_refusal_flush = [_][]const u8{
            "await flushOutbound(h)",
            "flush_outbound(shared).await",
            "await flush_outbound(session)",
        };
        for (private_refusal_flush) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: feed-refusal must not private-flush via `{s}` — use kick_actions / kickActions / drain-effects", .{ path, needle });
            }
        }
        // EOF / transport_closed must drain FAIL completions (shared spine). Match
        // the FFI *call* (`…transport_closed(`) so module-doc mentions do not fire.
        // Kick may appear just before (Racket `with-session-drain`) or after.
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, contents, search_from, "glowcap_host_session_transport_closed(")) |closed_at| {
            const lo = if (closed_at > 400) closed_at - 400 else 0;
            const hi = @min(contents.len, closed_at + 800);
            const window = contents[lo..hi];
            const kick_near = std.mem.indexOf(u8, window, "kickActions") != null or
                std.mem.indexOf(u8, window, "settleActions") != null or
                std.mem.indexOf(u8, window, "kick_actions") != null or
                std.mem.indexOf(u8, window, "drain-host-actions!") != null or
                std.mem.indexOf(u8, window, "with-session-drain") != null;
            if (!kick_near) {
                try appendViolation(gpa, violations, "{s}: glowcap_host_session_transport_closed without nearby action kick/drain — EOF must settle FAIL completions", .{path});
            }
            search_from = closed_at + 1;
        }
        // Transport loss is a physical fact, not a consequence a binding may
        // infer from its local close-intent flag. In particular, EOF during an
        // unbounded finish must still reach the core and terminate that wait.
        const intent_gates = [_][]const u8{
            "if (!h.closing) {\n\t\t\th.closingFlag",
            "if not session.is_closing:\n            session.closing_flag",
            "if !shared.closing() {\n\t\tshared.closing.set",
        };
        for (intent_gates) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: transport_closed is gated by binding close intent - report every observed transport loss and let driver_core decide whether it changes lifecycle", .{path});
            }
        }
        // Keyed handshake loop lives in pump (Pass 4a), not session.
        const hs_ok = std.mem.indexOf(u8, contents, "runHandshake") != null or
            std.mem.indexOf(u8, contents, "_run_handshake") != null or
            std.mem.indexOf(u8, contents, "run_handshake") != null or
            std.mem.indexOf(u8, contents, "run-handshake!") != null;
        if (!hs_ok) {
            try appendViolation(gpa, violations, "{s}: pump missing handshake runner (runHandshake / _run_handshake / run_handshake / run-handshake!)", .{path});
        }
        // The handshake closed-message is one cross-language string: a pump
        // that respells it ships a divergent consumer-facing error.
        if (std.mem.indexOf(u8, contents, "connection closed during the OCapN handshake") == null) {
            try appendViolation(gpa, violations, "{s}: pump missing the canonical handshake closed-message (`connection closed during the OCapN handshake`)", .{path});
        }
        // The EOF transport-closed message is one cross-language string too:
        // it settles the app's pending far vows broken, so a pump that respells
        // it (Rust once said `session closed`) ships a divergent consumer-facing
        // broken reason. The trailing quote distinguishes it from the handshake
        // message above, whose next word is `during`.
        if (std.mem.indexOf(u8, contents, "connection closed\"") == null) {
            try appendViolation(gpa, violations, "{s}: pump missing the canonical EOF transport-closed message (`connection closed`)", .{path});
        }
    }

    // Handshake error string must not live in session files — pump owns the loop.
    const handshake_msg = "connection closed during the OCapN handshake";
    const session_paths = [_][]const u8{
        "bindings/ts/runtime/session.ts",
        "bindings/python/glowcap/_session/",
        "bindings/rust/src/session.rs",
        "bindings/racket/private/session.rkt",
    };
    for (session_paths) |path| {
        const contents = (try readSourceSubject(io, gpa, root, path)) orelse {
            try appendViolation(gpa, violations, "{s}: failed to read for handshake-spine check", .{path});
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, handshake_msg) != null) {
            try appendViolation(gpa, violations, "{s}: handshake closed-message belongs in pump, not session", .{path});
        }
        // last_abort FFI reader lives in pump (Pass 1b); Session may wrap.
        if (std.mem.indexOf(u8, contents, "glowcap_host_session_last_abort") != null) {
            try appendViolation(gpa, violations, "{s}: glowcap_host_session_last_abort belongs in pump, not session", .{path});
        }
        // transport_closed FFI lives in pump; Session may wrap the drain window.
        if (std.mem.indexOf(u8, contents, "glowcap_host_session_transport_closed") != null) {
            try appendViolation(gpa, violations, "{s}: glowcap_host_session_transport_closed belongs in pump, not session", .{path});
        }
    }

    const park = [_]struct { path: []const u8, inside: []const u8, park: []const u8, release_path: []const u8, release: []const u8 }{
        .{ .path = "bindings/ts/runtime/session/lifecycle.ts", .inside = "insideTurn", .park = "parkRelease", .release_path = "bindings/ts/runtime/session/lifecycle.ts", .release = "glowcap_host_session_release" },
        .{ .path = "bindings/python/glowcap/_session/lifecycle.py", .inside = "_inside_turn", .park = "park_release", .release_path = "bindings/python/glowcap/_session/lifecycle.py", .release = "glowcap_host_session_release" },
        .{ .path = "bindings/rust/src/session_shared.rs", .inside = "inside_turn", .park = "finalizer::park_session", .release_path = "bindings/rust/src/host.rs", .release = "glowcap_host_session_release" },
        // Racket's close path releases through host/state.rkt's
        // `native-session-release!`, the one owner of the loop-vs-byte-fed
        // branch (`glowcap_driver_session_release` beside
        // `glowcap_host_session_release`, ADR-0112); host/state.rkt is held to
        // both spellings below.
        .{ .path = "bindings/racket/private/session.rkt", .inside = "inside-turn?", .park = "host-park-release!", .release_path = "bindings/racket/private/session.rkt", .release = "native-session-release!" },
    };
    for (park) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for mid-turn park check with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, row.inside) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — mid-turn park gate", .{ row.path, row.inside });
        }
        if (std.mem.indexOf(u8, contents, row.park) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — mid-turn park gate", .{ row.path, row.park });
        }
        const release_contents = root.readFileAlloc(io, row.release_path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for close release check with {s}", .{ row.release_path, @errorName(err) });
            continue;
        };
        defer gpa.free(release_contents);
        if (std.mem.indexOf(u8, release_contents, row.release) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — close path release", .{ row.release_path, row.release });
        }
    }
    // The Racket release branch's own authorities: host/state.rkt owns the branch
    // and the byte-fed spelling, loop/core.rkt owns the loop spelling, so a
    // rename cannot quietly point `native-session-release!` at nothing.
    const release_branch = [_]struct { path: []const u8, needles: []const []const u8 }{
        .{ .path = "bindings/racket/private/host/state.rkt", .needles = &.{ "native-session-release!", "glowcap_host_session_release" } },
        .{ .path = "bindings/racket/private/loop/core.rkt", .needles = &.{"glowcap_driver_session_release"} },
    };
    for (release_branch) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for release-branch check with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (row.needles) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — the session-release branch (ADR-0112)", .{ row.path, needle });
            }
        }
    }

    const cref = "examples/c/host_embedder_pump.c";
    root.access(io, cref, .{}) catch {
        try appendViolation(gpa, violations, "{s}: file must exist — C reference embedder pump", .{cref});
        return;
    };
    const cref_contents = root.readFileAlloc(io, cref, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for C reference pump check with {s}", .{ cref, @errorName(err) });
        return;
    };
    defer gpa.free(cref_contents);
    for ([_][]const u8{
        "glowcap_host_session_feed_bytes",
        "glowcap_host_next_action",
        "glowcap_host_session_take_outbound",
        "glowcap_host_session_last_abort",
        "glowcap_host_session_transport_closed",
    }) |needle| {
        if (std.mem.indexOf(u8, cref_contents, needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — normative embedder choreography", .{ cref, needle });
        }
    }

    // Zig-facing shared drain (ADR-0072 fifth amendment) — authority for the
    // one-loop switch tests rewire onto; must not silently disappear.
    const zig_pump = "src/c_abi/host/embedder_pump.zig";
    root.access(io, zig_pump, .{}) catch {
        try appendViolation(gpa, violations, "{s}: file must exist — Zig embedder_pump (ADR-0072 fifth)", .{zig_pump});
        return;
    };
    const zig_pump_contents = root.readFileAlloc(io, zig_pump, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for Zig embedder_pump check with {s}", .{ zig_pump, @errorName(err) });
        return;
    };
    defer gpa.free(zig_pump_contents);
    for ([_][]const u8{ "drainHost", "drainHosts", "glowcap_host_next_action" }) |needle| {
        if (std.mem.indexOf(u8, zig_pump_contents, needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — shared C-ABI drain helper", .{ zig_pump, needle });
        }
    }

    // The dlopen binding action modules drain via glowcap_host_pump_drain
    // (ADR-0072 sixth). Ban hand-rolled glowcap_host_next_action pop loops in
    // those modules — the C symbol may still appear in FFI loaders and
    // comments outside action/.
    const action_mods = [_][]const u8{
        "bindings/python/glowcap/_action.py",
        "bindings/rust/src/action.rs",
        "bindings/racket/private/action.rkt",
    };
    for (action_mods) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for pump_drain adoption check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "glowcap_host_pump_drain") == null) {
            try appendViolation(gpa, violations, "{s}: missing glowcap_host_pump_drain — action module must use the shared C drain", .{path});
        }
        if (std.mem.indexOf(u8, contents, "glowcap_host_next_action") != null) {
            try appendViolation(gpa, violations, "{s}: glowcap_host_next_action in action module — use glowcap_host_pump_drain (no hand-rolled pop loop)", .{path});
        }
    }

    // The TypeScript action module is the exception, by contract: it also runs
    // under the wasm adapter (ADR-0070), whose single callback seam is the
    // behavior trampoline, so a hooks-buffer drain cannot exist there. It
    // drains through the canonical glowcap_host_next_action pop instead (one
    // spine for dlopen and wasm) and must not mint a per-drain callback.
    {
        const path = "bindings/ts/runtime/action.ts";
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for next_action drain check with {s}", .{ path, @errorName(err) });
            return;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "glowcap_host_next_action") == null) {
            try appendViolation(gpa, violations, "{s}: missing glowcap_host_next_action; the TS action module drains by pop (wasm has no hooks seam)", .{path});
        }
        if (std.mem.indexOf(u8, contents, "glowcap_host_pump_drain") != null) {
            try appendViolation(gpa, violations, "{s}: glowcap_host_pump_drain in the TS action module; hooks buffers cannot run under the wasm adapter", .{path});
        }
        if (std.mem.indexOf(u8, contents, "makeCallback") != null) {
            try appendViolation(gpa, violations, "{s}: makeCallback in the TS action module; the drain must not mint per-drain native callbacks", .{path});
        }
    }
}

/// Behavior trampoline spine (Pass 5): each binding keeps a named trampoline
/// module, mid-turn latch, reply keep, and turn verbs; hop cap lives in the
/// constant homes (mirrored against GLOWCAP_MAX_LOCAL_FORWARD_HOPS).
pub fn checkBindingEmbedderTrampoline(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const mods = [_]struct { path: []const u8, markers: []const []const u8 }{
        .{
            .path = "bindings/ts/runtime/trampoline.ts",
            .markers = &.{ "chaseLocalForwards", "runHosted", "sendLocal", "tellLocal", "tellFar", "dispatchSend", "dispatchTell", "caretakerProxy", "attenuateProxy", "spawnHosted", "publishHosted", "function registerActor", "currentTurn", "lastReplyKeep", "glowcap_host_turn_break", "glowcap_host_turn_forward", "glowcap_host_turn_spawn", "MAX_LOCAL_FORWARD_HOPS", "FORWARD_CYCLE_MESSAGE" },
        },
        .{
            .path = "bindings/python/glowcap/_trampoline.py",
            .markers = &.{ "_chase_local_forwards", "_run_hosted", "_send_local", "_tell_local", "_tell_far", "_dispatch_send", "_dispatch_tell", "_caretaker_proxy", "_attenuate_proxy", "_spawn_hosted", "_publish_hosted", "def _register_actor", "_current_turn", "_reply_state", "threading.local()", "last_reply_keep", "glowcap_host_turn_break", "glowcap_host_turn_forward", "glowcap_host_turn_spawn", "MAX_LOCAL_FORWARD_HOPS", "FORWARD_CYCLE_MESSAGE" },
        },
        .{
            .path = "bindings/rust/src/trampoline.rs",
            .markers = &.{ "chase_local_forwards", "run_hosted", "run_local_send", "caretaker_proxy", "attenuate_proxy", "CURRENT_TURN", "LAST_REPLY_KEEP", "glowcap_host_turn_break", "glowcap_host_turn_forward", "glowcap_host_turn_spawn", "MAX_LOCAL_FORWARD_HOPS", "FORWARD_CYCLE_MESSAGE" },
        },
        .{
            .path = "bindings/racket/private/trampoline.rkt",
            .markers = &.{ "settle-turn-reply", "chase-local-actor-forwards", "session-send-local", "await-local-vow", "dispatch-send", "dispatch-send-promise", "dispatch-tell", "caretaker-behavior", "attenuate-behavior", "caretaker-proxy", "attenuate-proxy", "revoke-caretaker!", "register-hosted-actor!", "glowcap_host_session_spawn", "glowcap_host_session_publish", "current-turn", "last-reply-keep", "glowcap_host_turn_break", "glowcap_host_turn_forward", "glowcap_host_turn_spawn", "FORWARD-CYCLE-MESSAGE" },
        },
    };
    // Racket's chase lives in vat.rkt (shared by $, drive, and the trampoline).
    {
        const vat_path = "bindings/racket/private/vat.rkt";
        if (root.readFileAlloc(io, vat_path, gpa, .limited(2 << 20))) |contents| {
            defer gpa.free(contents);
            for ([_][]const u8{ "chase-local-actor-forwards", "forward-cycle", "hop-broke", "MAX-LOCAL-FORWARD-HOPS", "FORWARD-CYCLE-MESSAGE" }) |needle| {
                if (std.mem.indexOf(u8, contents, needle) == null) {
                    try appendViolation(gpa, violations, "{s}: missing `{s}` — shared local-forward chase", .{ vat_path, needle });
                }
            }
        } else |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for shared-chase check with {s}", .{ vat_path, @errorName(err) });
        }
    }
    for (mods) |mod| {
        root.access(io, mod.path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — trampoline module (binding spine Pass 5)", .{mod.path});
            continue;
        };
        const contents = root.readFileAlloc(io, mod.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for trampoline-spine check with {s}", .{ mod.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (mod.markers) |needle| {
            if (!containsAsSymbol(contents, needle)) {
                try appendViolation(gpa, violations, "{s}: trampoline missing `{s}`", .{ mod.path, needle });
            }
        }
        // Hop cap must come from the constant home, not a raw 256 literal.
        if (std.mem.indexOf(u8, contents, "= 256") != null or
            std.mem.indexOf(u8, contents, "=256") != null or
            std.mem.indexOf(u8, contents, " 256)") != null)
        {
            try appendViolation(gpa, violations, "{s}: raw hop-cap literal — use MAX_LOCAL_FORWARD_HOPS / MAX-LOCAL-FORWARD-HOPS", .{mod.path});
        }
    }

    // Local send/tell arms and ADR-0064 proxy factories live in trampoline
    // (Pass 4c / 4e), not session.
    const banned = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/ts/runtime/session/", .needle = "#sendLocal" },
        .{ .path = "bindings/ts/runtime/session/", .needle = "throw new Error(\"Revoked\")" },
        .{ .path = "bindings/ts/runtime/session/", .needle = "throw new Error(\"Attenuated\")" },
        .{ .path = "bindings/python/glowcap/_session/", .needle = "def _send_local" },
        .{ .path = "bindings/python/glowcap/_session/", .needle = "raise ValueError(\"Revoked\")" },
        .{ .path = "bindings/python/glowcap/_session/", .needle = "raise ValueError(\"Attenuated\")" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "async fn run_local_send" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "fn run_hosted(" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "Break(\"Revoked\"" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "Break(\"Attenuated\"" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (session-send-local" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (await-local-vow" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(error \"Revoked\")" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(error \"Attenuated\")" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(spawn (caretaker-behavior" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(spawn (attenuate-behavior" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(hash-set! (vat-revocables" },
        .{ .path = "bindings/ts/runtime/session/", .needle = "glowcap_host_session_send" },
        .{ .path = "bindings/ts/runtime/session/", .needle = "glowcap_host_vow_send" },
        .{ .path = "bindings/python/glowcap/_session/", .needle = "glowcap_host_session_send" },
        .{ .path = "bindings/python/glowcap/_session/", .needle = "glowcap_host_vow_send" },
        .{ .path = "bindings/ts/runtime/session/", .needle = "glowcap_host_session_spawn" },
        .{ .path = "bindings/ts/runtime/session/", .needle = "glowcap_host_session_publish" },
        .{ .path = "bindings/python/glowcap/_session/", .needle = "glowcap_host_session_spawn" },
        .{ .path = "bindings/python/glowcap/_session/", .needle = "glowcap_host_session_publish" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "glowcap_host_session_spawn" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "glowcap_host_session_publish" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (register-hosted-actor!" },
        .{ .path = "bindings/ts/runtime/session/", .needle = "#registerActor" },
        .{ .path = "bindings/python/glowcap/_session/", .needle = "def _register_actor" },
        .{ .path = "bindings/python/glowcap/_session/", .needle = "class _SessionGcHandle" },
        .{ .path = "bindings/ts/runtime/session/", .needle = "glowcap_host_session_tell" },
        .{ .path = "bindings/python/glowcap/_session/", .needle = "glowcap_host_session_tell" },
        .{ .path = "bindings/ts/runtime/session/", .needle = "glowcap_host_vow_index" },
        .{ .path = "bindings/ts/runtime/session/", .needle = "glowcap_host_vow_untag" },
        .{ .path = "bindings/ts/runtime/session/", .needle = "return sendLocal(" },
        .{ .path = "bindings/ts/runtime/session/", .needle = "await tellLocal(" },
        .{ .path = "bindings/ts/runtime/session/", .needle = "return sendFar(" },
        .{ .path = "bindings/python/glowcap/_session/", .needle = "return _send_local(" },
        .{ .path = "bindings/python/glowcap/_session/", .needle = "await _tell_local(" },
        .{ .path = "bindings/python/glowcap/_session/", .needle = "return _send_far(" },
        .{ .path = "bindings/python/glowcap/_session/", .needle = "await _tell_far(" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "tell_local(" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "tell_wire(" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(session-send-local c" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(apply <-np resolved" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(await-vow c (session-far-send" },
    };
    for (banned) |b| {
        const contents = (try readSourceSubject(io, gpa, root, b.path)) orelse {
            try appendViolation(gpa, violations, "{s}: failed to read for trampoline-factory ban", .{b.path});
            continue;
        };
        defer gpa.free(contents);
        if (containsAsSymbol(contents, b.needle)) {
            try appendViolation(gpa, violations, "{s}: `{s}` belongs in promise/trampoline, not session (Pass 4c/4e/4f)", .{ b.path, b.needle });
        }
    }

    // Constant homes must carry the hop cap. The reflected value lives in each
    // binding's generated constant module (`zig build gen-binding-constants`),
    // re-exported through the hand-kept home; the presence check names the
    // generated module that reflects it.
    const const_homes = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/python/glowcap/_constants_gen.py", .needle = "MAX_LOCAL_FORWARD_HOPS" },
        .{ .path = "bindings/rust/src/abi_constants_gen.rs", .needle = "MAX_LOCAL_FORWARD_HOPS" },
        .{ .path = "bindings/racket/private/constants-gen.rkt", .needle = "MAX-LOCAL-FORWARD-HOPS" },
        .{ .path = "bindings/ts/abi/constants.ts", .needle = "MAX_LOCAL_FORWARD_HOPS" },
    };
    for (const_homes) |home| {
        const contents = root.readFileAlloc(io, home.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for trampoline hop-cap check with {s}", .{ home.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, home.needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — trampoline hop-cap mirror", .{ home.path, home.needle });
        }
    }

    // C example must exercise the opt-in pump drain.
    const cref = "examples/c/host_embedder_pump.c";
    const cref_contents = root.readFileAlloc(io, cref, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for pump_drain check with {s}", .{ cref, @errorName(err) });
        return;
    };
    defer gpa.free(cref_contents);
    if (std.mem.indexOf(u8, cref_contents, "glowcap_host_pump_drain") == null) {
        try appendViolation(gpa, violations, "{s}: missing glowcap_host_pump_drain — C checklist must use the opt-in wrapper", .{cref});
    }
}

/// The binding maintainer guide must name every embedder-spine module, declare
/// the split complete, and name the handshake pump plus trampoline and opt-in
/// callback pump. Keep this internal inventory out of the consumer landing
/// page.
pub fn checkBindingEmbedderSpineDocs(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const docs = [_]struct { path: []const u8, needles: []const []const u8 }{
        .{
            .path = "bindings/DEVELOPING.md",
            .needles = &.{
                "**pump module**",
                "**action module**",
                "`promise`",
                "promiseFor",
                "sendFar",
                "`gc`",
                "`dial`",
                "`listen`",
                "**trampoline** module",
                "embedder-spine module split is complete",
                "trampoline",
                "caretaker/attenuate",
                "spawn/publish",
                "`session_shared`",
                "embedder_pump",
                "glowcap_host_pump_drain",
                "handshake",
            },
        },
    };
    for (docs) |doc| {
        const contents = root.readFileAlloc(io, doc.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for embedder-spine doc check with {s}", .{ doc.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (doc.needles) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — embedder-spine living-state inventory", .{ doc.path, needle });
            }
        }
    }
}

/// Reject numeric error-code literals in handwritten binding claims and raise
/// sites. Generated constant files are the sole numeric mirrors of the C ABI;
/// binding code, tests, and docs must name those constants or typed errors.
pub fn checkBindingMagicErrorCodes(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "bindings", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "bindings: failed to open for magic-error-code check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOf(u8, entry.path, "target/") != null) continue;
        if (std.mem.indexOf(u8, entry.path, "__pycache__/") != null) continue;
        const is_source = std.mem.endsWith(u8, entry.path, ".rs") or
            std.mem.endsWith(u8, entry.path, ".py") or
            std.mem.endsWith(u8, entry.path, ".ts") or
            std.mem.endsWith(u8, entry.path, ".rkt");
        if (!is_source) continue;
        if (constants.isGeneratedBindingConstantFile(entry.path)) continue;
        const path = try std.fmt.allocPrint(gpa, "bindings/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for magic-error-code check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        var line_number: usize = 0;
        while (lines.next()) |line| {
            line_number += 1;
            var has_error_context = false;
            for (binding_error_context_patterns) |pattern| {
                if (std.mem.indexOf(u8, line, pattern) != null) {
                    has_error_context = true;
                    break;
                }
            }
            if (!has_error_context) continue;

            var search: usize = 0;
            while (std.mem.indexOfPos(u8, line, search, "-")) |minus| {
                search = minus + 1;
                if (search >= line.len) break;
                const digit = line[search];
                if (digit < '0' or digit > '9') continue;
                try appendViolation(gpa, violations, "{s}:{d}: numeric ABI error code (`-{c}…`) — name the generated constant or typed error instead", .{ path, line_number, digit });
                break;
            }
        }
    }
}
