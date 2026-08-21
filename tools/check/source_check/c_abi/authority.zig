//! Authority stays above the C surface: runtime mutation admission, failure
//! projection, and semantic argument validity belong to the driver and host
//! cores, and these checks refuse the C loop or a binding re-deciding them.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const fileContains = util.fileContains;
const firstIntIn = util.firstIntIn;
const parseJsonFile = util.parseJsonFile;
const getField = util.getField;
const jsonStringEquals = util.jsonStringEquals;
const readSourceSubject = util.readSourceSubject;

/// Runtime mutation admission is a driver/core decision. The C loop may
/// validate and marshal a call, but it must not duplicate that policy before
/// invoking the owning runtime operation.
pub fn checkDriverAdmissionAuthority(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const loop_subjects = [_][]const u8{
        "src/c_abi/driver/loop.zig",
        "src/c_abi/driver/loop/",
    };
    for (loop_subjects) |subject| {
        const contents = (try readSourceSubject(io, gpa, root, subject)) orelse {
            try appendViolation(gpa, violations, "{s}: failed to read for driver admission authority", .{subject});
            continue;
        };
        defer gpa.free(contents);

        const forbidden = [_][]const u8{
            "admitRuntimeOperation",
            "mutationCode(",
            "if (terminalCode(inst))",
            "err == error.MissingAdvertisedLocator",
            "runtime.wires",
            "inst.runtime.core",
            "runtime.core.releaseDriverOwnership",
            ".core.in_callback",
            ".core.opts",
            "runtime.terminalFailure()",
            "runtime.terminalCleanupPending()",
        };
        for (forbidden) |needle| if (std.mem.indexOf(u8, contents, needle) != null)
            try appendViolation(gpa, violations, "{s}: forbidden C-side runtime authority `{s}` — invoke HostRuntime and project its result", .{ subject, needle });
    }

    const provider_subjects = [_][]const u8{
        "src/c_abi/driver/provider_registry.zig",
        "src/c_abi/driver/provider_registry/",
    };
    for (provider_subjects) |subject| {
        const contents = (try readSourceSubject(io, gpa, root, subject)) orelse continue;
        defer gpa.free(contents);
        for ([_][]const u8{
            "provider package repeats transport profile",
            "contract_failed",
            "metadataFromClaim",
        }) |needle| if (std.mem.indexOf(u8, contents, needle) != null)
            try appendViolation(gpa, violations, "{s}: forbidden provider-side runtime authority `{s}`", .{ subject, needle });
    }
}

/// Transport and I/O failures belong to the native driver. The sans-I/O core
/// must not regain a parallel classification, and C only projects the driver's
/// stable category.
pub fn checkDriverFailureAuthority(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    if (try fileContains(io, gpa, root, "src/driver/core/operation_failure.zig", "OperationFailure")) {
        try appendViolation(gpa, violations, "src/driver/core/operation_failure.zig: native operation failures belong in driver, not driver_core", .{});
    }
    try expectFileContains(io, gpa, root, violations, "src/driver/mod.zig", &.{
        "pub const OperationFailure = @import(\"operation_failure.zig\").OperationFailure;",
    });
    try expectFileContains(io, gpa, root, violations, "src/c_abi/driver/error.zig", &.{
        "const driver = @import(\"driver\");",
        "driver.OperationFailure.Kind",
    });
}

/// Host-domain failures are classified by the sans-I/O host core. The C ABI
/// may classify its own pointer and marshalling failures, but it must only
/// project core failure categories.
pub fn checkHostFailureAuthority(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const semantic_errors = [_][]const u8{
        "error.CapabilityRouteUnavailable",
        "error.SessionCondemned",
        "error.HandshakeIncomplete",
        "error.PartnerUnverified",
        "error.SendRejected",
        "error.FrameTooLarge",
        "error.DesignatorNotHostPort",
        "error.DesignatorNotPeerKey",
        "error.ReachabilityRequired",
    };
    const paths = [_][]const u8{
        "src/c_abi/host/common.zig",
        "src/c_abi/host/host.zig",
        "src/c_abi/host/session.zig",
    };
    for (paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for Host failure authority with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (semantic_errors) |name| {
            if (std.mem.indexOf(u8, contents, name) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden Host failure classification `{s}` - project driver_core.HostFailure instead", .{ path, name });
            }
        }
    }
    try expectFileContains(io, gpa, root, violations, "src/c_abi/host/session.zig", &.{
        "embedderOwnsDrive(instOf(session.host), \"session_break_far_vows\")",
    });
}

/// Hosted-object transactions are Host semantics. The C archive may allocate
/// a callback trampoline, but bootstrap/export mutation, Vat insertion, and
/// capability adoption must stay behind one driver_core operation.
pub fn checkHostSemanticAuthority(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const forbidden = [_][]const u8{
        "registerBootstrapCap(",
        "exportNextObject(",
        "restoreBootstrapMapping(",
        "releaseUnsharedExport(",
        ".vat.spawnHosted(",
        ".served.bindExport(",
        "liftLocalActor(",
        ".core.sessions",
        ".session_state.",
        ".core.in_callback",
        ".core.opts",
        "refuseLatched",
        ".liftCapabilityTracked(",
        ".rollbackCapabilityLift(",
        ".discardCapabilityObservation(",
        "fn issueCapabilityId(",
        "capability_key_state",
        "permuteCapabilityId(",
    };
    const paths = [_][]const u8{
        "src/c_abi/host/common.zig",
        "src/c_abi/host/host.zig",
        "src/c_abi/host/session.zig",
        "src/c_abi/host/turn.zig",
    };
    for (paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for Host semantic authority with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (forbidden) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden Host semantic mutation `{s}` - expose one driver_core operation and keep C at the adapter boundary", .{ path, needle });
            }
        }
    }
    try expectFileContains(io, gpa, root, violations, "src/driver/core/capability.zig", &.{
        "pub const IdIssuer = struct {",
    });
    try expectFileContains(io, gpa, root, violations, "src/c_abi/host/capability_ids.zig", &.{
        "pub fn issuer(",
        "std.atomic.Value(u64)",
    });
    try expectFileContains(io, gpa, root, violations, "src/c_abi/host/host.zig", &.{
        "capability_ids.issuer(",
    });

    const retired_enrollment = [_][]const u8{
        "src/driver/core/host.zig",
        "src/driver/core/handoff.zig",
    };
    for (retired_enrollment) |path| {
        if (try fileContains(io, gpa, root, path, "enrollCapability")) {
            try appendViolation(
                gpa,
                violations,
                "{s}: explicit Host capability enrollment is retired - lift opaque identities and lower them on the carrying session",
                .{path},
            );
        }
    }
}
