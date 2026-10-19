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
/// à-la-carte archive split holds (ADR-0022, ADR-0033). Rust pins this at
/// compile time (`#[cfg(feature = "iroh")]`); the other three defer the import
/// by hand, so this keeps that convention a build-checked invariant rather than
/// trusting three hand-written import sites. The rooms production relay is out
/// of scope, it links the full stack.
pub fn checkReferenceRelayIrohLazy(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const why = "load the iroh binding lazily on the `?locator=` dial path so a TCP-only relay links no iroh FFI (ADR-0033)";

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

/// The native Rooms relay admits one parsed target and passes that owned target
/// to its dial job. Raw reference-relay parameters cannot bypass admission.
pub fn checkProductionRelayClassifierLockstep(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const web = "apps/rooms/rust/services/src/web/http.rs";
    const relay = "apps/rooms/rust/services/src/web/relay.rs";
    try expectFileContains(io, gpa, root, violations, relay, &.{"self.target(target)"});
    try expectFileContains(io, gpa, root, violations, relay, &.{"match target {"});
    for ([_][]const u8{ web, relay }) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read relay admission with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for ([_][]const u8{ "parameter(\"to\")", "parameter(\"locator\")" }) |bypass| {
            if (std.mem.indexOf(u8, contents, bypass) != null) {
                try appendViolation(gpa, violations, "{s}: reference-relay parameter `{s}` bypasses Rooms target admission", .{ path, bypass });
            }
        }
    }
}
