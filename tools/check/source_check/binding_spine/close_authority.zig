//! Close and failure projection authority: the driver core owns retirement
//! and failure meaning, and every binding projects rather than re-decides.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const fileContains = util.fileContains;
const containsAsSymbol = util.containsAsSymbol;
const extractBraceBlock = util.extractBraceBlock;

/// Driver events carry a core-owned result category. Error names remain
/// diagnostics and must never become a second classification table in a
/// language binding.
pub fn checkDriverEventFailureProjection(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const paths = [_][]const u8{
        "bindings/rust/src/driver_loop.rs",
        "bindings/python/pancake/_loop.py",
        "bindings/ts/runtime/driver_loop.ts",
        "bindings/racket/private/loop.rkt",
    };
    const error_names = [_][]const u8{
        "HandshakeTimedOut",
        "WaitTimedOut",
        "ListenerSetupTimedOut",
        "ListenerTimedOut",
    };

    for (paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for driver-event failure projection with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (error_names) |name| {
            if (std.mem.indexOf(u8, contents, name) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden driver error-name classification `{s}` — project PancakeDriverEvent.primary_result instead", .{ path, name });
            }
        }
    }
}

/// Bindings request native retirement and drive its completion; they do not
/// count wrappers or inspect a Host registry to decide when close may begin.
pub fn checkDriverRetirementAuthority(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const forbidden = [_]struct { path: []const u8, needles: []const []const u8 }{
        .{ .path = "bindings/ts/runtime/driver_loop.ts", .needles = &.{"#openSessions"} },
        .{ .path = "bindings/python/pancake/_loop.py", .needles = &.{ "_open_sessions", "_close_requested" } },
        .{ .path = "bindings/racket/private/loop.rkt", .needles = &.{ "driver-loop-retire-when-idle!", "retirement-scheduled" } },
    };
    for (forbidden) |entry| {
        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for retirement authority with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (entry.needles) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden binding retirement policy `{s}` — request and drive pancake_driver_retire instead", .{ entry.path, needle });
            }
        }
    }
}

/// Native close owns semantic completion and failure. Bindings may release
/// their promise/task/projection storage after that barrier, but must not turn
/// a local table assertion into a second public close result.
pub fn checkBindingCloseProjectionAuthority(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const paths = [_][]const u8{
        "bindings/ts/runtime/driver_loop.ts",
        "bindings/ts/runtime/host.ts",
        "bindings/python/pancake/_host.py",
        "bindings/python/pancake/_loop.py",
        "bindings/racket/private/host.rkt",
        "bindings/racket/private/loop.rkt",
    };
    for (paths) |path| {
        if (try fileContains(io, gpa, root, path, "close left")) {
            try appendViolation(gpa, violations, "{s}: forbidden binding-invented close failure — native lifecycle outcomes are authoritative; bindings only retire their projections", .{path});
        }
    }
    const duplicate_runtime_admission = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/ts/runtime/runtime.ts", .needle = "#closed" },
        .{ .path = "bindings/rust/src/runtime.rs", .needle = "closed: Cell" },
        .{ .path = "bindings/racket/private/dial.rkt", .needle = "runtime-closed?" },
    };
    for (duplicate_runtime_admission) |entry| {
        if (try fileContains(io, gpa, root, entry.path, entry.needle)) {
            try appendViolation(gpa, violations, "{s}: forbidden Runtime admission mirror `{s}` — Host/driver lifecycle is authoritative; retain only binding resource-ownership guards", .{ entry.path, entry.needle });
        }
    }

    const operation_guards = [_]struct {
        path: []const u8,
        anchor: []const u8,
        forbidden: []const u8,
    }{
        .{ .path = "bindings/ts/runtime/host.ts", .anchor = "assertHandle(): void {", .forbidden = "#releaseStarted" },
        .{ .path = "bindings/rust/src/host.rs", .anchor = "pub(crate) fn guard_handle", .forbidden = "closing()" },
        .{ .path = "bindings/rust/src/session_shared.rs", .anchor = "pub(crate) fn guard_open", .forbidden = "closing()" },
    };
    for (operation_guards) |guard| {
        const contents = root.readFileAlloc(io, guard.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for binding operation admission with {s}", .{ guard.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        const start = std.mem.indexOf(u8, contents, guard.anchor) orelse {
            try appendViolation(gpa, violations, "{s}: missing operation-handle guard `{s}`", .{ guard.path, guard.anchor });
            continue;
        };
        const rest = contents[start..];
        const end = std.mem.indexOf(u8, rest, "\n\t}") orelse @min(rest.len, 512);
        if (std.mem.indexOf(u8, rest[0..end], guard.forbidden) != null) {
            try appendViolation(gpa, violations, "{s}: operation handle guard consults close-barrier state `{s}` — native admission is authoritative; bindings guard only invalid handles", .{ guard.path, guard.forbidden });
        }
    }

    const retained_policy = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/racket/private/host.rkt", .needle = "release-request" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(cons options pending)" },
        .{ .path = "bindings/racket/private/action.rkt", .needle = "(define (drive-host-close! m options" },
        .{ .path = "bindings/racket/private/loop.rkt", .needle = "(define (drive-loop-close! lp options" },
        .{ .path = "bindings/ts/runtime/host.ts", .needle = "#doClose(options:" },
        .{ .path = "bindings/ts/runtime/session.ts", .needle = "#driveClose(options:" },
        .{ .path = "bindings/ts/runtime/driver_loop.ts", .needle = "#doClose(options:" },
        .{ .path = "bindings/python/pancake/_host.py", .needle = "_drive_release(self, options)" },
    };
    for (retained_policy) |entry| {
        if (try fileContains(io, gpa, root, entry.path, entry.needle)) {
            try appendViolation(gpa, violations, "{s}: close driver retains native policy `{s}` — forward policy immediately and defer only waiting/release effects", .{ entry.path, entry.needle });
        }
    }
}

/// Bindings may reject values that cannot be represented losslessly by the C
/// record, but the shared core owns the narrower semantic grace limit. Racket's
/// public Host release likewise has no adapter-only path around native close.
pub fn checkBindingClosePolicyAuthority(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const abi_range_checks = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/ts/runtime/lifecycle.ts", .needle = "graceMs > CLOSE_MAX_GRACE_MS" },
        .{ .path = "bindings/python/pancake/_lifecycle.py", .needle = "grace > _abi.CLOSE_MAX_GRACE_MS / 1_000" },
        .{ .path = "bindings/rust/src/lifecycle.rs", .needle = "millis > u128::from(sys::CLOSE_MAX_GRACE_MS)" },
        .{ .path = "bindings/racket/private/host.rkt", .needle = "(<= grace-ms CLOSE-MAX-GRACE-MS)" },
    };
    for (abi_range_checks) |entry| {
        try expectFileContains(io, gpa, root, violations, entry.path, &.{entry.needle});
    }
    if (try fileContains(io, gpa, root, "bindings/racket/private/host.rkt", "#:close-sessions?")) {
        try appendViolation(gpa, violations, "bindings/racket/private/host.rkt: public Host release exposes an adapter-only close bypass", .{});
    }
    try expectFileContains(io, gpa, root, violations, "src/driver/core/close.zig", &.{
        "pub const PendingWorkInput = struct",
        "pub fn resolve(self: PendingWorkInput) Error!PendingWork",
    });
    try expectFileContains(io, gpa, root, violations, "src/c_abi/host/mod.zig", &.{
        "driver_core.PendingWorkInput",
        ").resolve()",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/ts/runtime/driver_loop.ts", &.{
        "new FinalizationRegistry<DriverLoopFinalizerState>",
        "const outcome = driverCall(",
        "\"driver-loop.finalizer.release\"",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/python/pancake/_loop.py", &.{
        "weakref.finalize(",
        "self, _release_driver_finalizer_state",
        "_release(_driver, handle, \"driver-loop.finalize.release\")",
    });
}
