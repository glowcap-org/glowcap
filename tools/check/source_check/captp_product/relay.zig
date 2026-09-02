//! The relay tier's split: reference relays classify locally and stay
//! dependency-free, and the production relay's classifier stays in lockstep
//! with the host's.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;

/// The reference relays (the Deno, Python, and Racket rows of the
/// `bindings-relay` matrix) must load the iroh binding lazily, only on the
/// `?locator=` dial path, so a `?to=`-only run links no iroh FFI and the
/// à-la-carte archive split holds (ADR-0059, ADR-0086). Rust pins this at
/// compile time (`#[cfg(feature = "iroh")]`); the other three defer the import
/// by hand, so this keeps that convention a build-checked invariant rather than
/// trusting three hand-written import sites. The rooms production relay is out
/// of scope — it links the full stack deliberately.
pub fn checkReferenceRelayIrohLazy(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const why = "load the iroh binding lazily on the `?locator=` dial path so a TCP-only relay links no iroh FFI (ADR-0086)";

    // Deno: the `@glowcap/iroh` specifier may appear only inside a dynamic
    // `import(...)`; a static `from "@glowcap/iroh"` would load iroh eagerly.
    const deno_paths = [_][]const u8{ "bindings/ts/relay/serve.ts", "bindings/ts/relay/deno_channels.ts" };
    for (deno_paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for reference-relay-iroh-lazy check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "\"@glowcap/iroh\"") != null and
                std.mem.indexOf(u8, line, "import(") == null)
            {
                try appendViolation(gpa, violations, "{s}: static import of `@glowcap/iroh` — {s}", .{ path, why });
            }
        }
    }

    // Python: the `glowcap.iroh` import must be indented (inside the dial
    // function), never at module scope (column 0).
    py: {
        const path = "bindings/python/relay.py";
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for reference-relay-iroh-lazy check with {s}", .{ path, @errorName(err) });
            break :py;
        };
        defer gpa.free(contents);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            const is_import = std.mem.startsWith(u8, trimmed, "from glowcap.iroh") or
                std.mem.startsWith(u8, trimmed, "import glowcap.iroh");
            if (is_import and trimmed.len == line.len) {
                try appendViolation(gpa, violations, "{s}: module-scope `glowcap.iroh` import — {s}", .{ path, why });
            }
        }
    }

    // Racket: the iroh companion is named by its literal only on the
    // `define-runtime-path` line; the lazy `dynamic-require` calls reach it
    // through the `iroh-companion-path` variable. Any other line naming the
    // literal is a static require that loads iroh eagerly.
    rkt: {
        const path = "bindings/racket/relay.rkt";
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for reference-relay-iroh-lazy check with {s}", .{ path, @errorName(err) });
            break :rkt;
        };
        defer gpa.free(contents);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "glowcap-iroh") != null and
                std.mem.indexOf(u8, line, "define-runtime-path") == null)
            {
                try appendViolation(gpa, violations, "{s}: static reference to the `glowcap-iroh` companion — {s}", .{ path, why });
            }
        }
    }
}

/// The rooms production relay funnels every dial through the shared
/// `classifyRelayTarget` (over `glowcap_host_plan_dial`), so its SSRF allow-list
/// sorts a target exactly as the dial that follows: one classified value gates
/// admission (`relayAllowed`) and drives the dial (`relayToTarget`). The
/// reference relays' local `?to=` / `?locator=` parameter dispatch must not leak
/// into the production path, where dialing a raw parameter would bypass the
/// classifier and the allow-list and reopen the SSRF hole (ADR-0086).
pub fn checkProductionRelayClassifierLockstep(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const web = "apps/rooms/web/serve_http.ts";
    const server = "apps/rooms/web/relay.ts";
    // The reference relays' two-parameter dispatch; forbidden in the production
    // path, which dials only a classified `?target=` and bridges `?rendezvous=`.
    const params = [_][]const u8{ ".get(\"to\")", ".get(\"locator\")" };

    web_blk: {
        const contents = root.readFileAlloc(io, web, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for production-relay-classifier check with {s}", .{ web, @errorName(err) });
            break :web_blk;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "classifyRelayTarget(") == null) {
            try appendViolation(gpa, violations, "{s}: the production relay must classify its dial target through `classifyRelayTarget` (the plan_dial SSRF chokepoint) (ADR-0086)", .{web});
        }
        for (params) |param| {
            if (std.mem.indexOf(u8, contents, param) != null) {
                try appendViolation(gpa, violations, "{s}: reads a `{s}` parameter — the reference-relay dispatch; the production relay dials only a classified `?target=` (ADR-0086 SSRF lockstep)", .{ web, param });
            }
        }
    }

    srv_blk: {
        const contents = root.readFileAlloc(io, server, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for production-relay-classifier check with {s}", .{ server, @errorName(err) });
            break :srv_blk;
        };
        defer gpa.free(contents);
        for (params) |param| {
            if (std.mem.indexOf(u8, contents, param) != null) {
                try appendViolation(gpa, violations, "{s}: reads a `{s}` parameter — the reference-relay dispatch; the production relay dials only a classified `?target=` (ADR-0086 SSRF lockstep)", .{ server, param });
            }
        }
    }
}
