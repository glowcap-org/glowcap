//! Rust owns the Rooms application, and its crate layers keep one direction.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

const retired = [_][]const u8{
    "apps/rooms/server",
    "apps/rooms/irc/bridge",
    "apps/rooms/irc/registration.ts",
    "apps/rooms/irc/socket_writer.ts",
    "apps/rooms/rust/native",
    "apps/rooms/rust/services/src/room_server.rs",
    "apps/rooms/rust/services/src/room_server",
    "apps/rooms/rust/services/src/session_service.rs",
    "apps/rooms/rust/services/src/session_service",
    "apps/rooms/rust/services/src/archive/service.rs",
    "apps/rooms/rust/services/src/archive/service",
};

const shared_manifests = [_][]const u8{
    "apps/rooms/rust/application/Cargo.toml",
    "apps/rooms/rust/glowcap/Cargo.toml",
    "apps/rooms/rust/runtime/Cargo.toml",
};

const retired_service_identifiers = [_][]const u8{
    "room_server",
    "archive_service",
    "rooms_native",
};

const runtime_domain_roots = [_][]const u8{
    "session",
    "directories",
    "rooms",
    "direct",
    "files",
    "archive",
    "grants",
    "service",
};

const runtime_support_files = [_][]const u8{
    "lib.rs",
    "cleanup.rs",
    "clock.rs",
    "documents.rs",
    "entropy.rs",
    "error.rs",
    "platform.rs",
    "wall_clock.rs",
};

fn containsName(names: []const []const u8, candidate: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn checkRuntimeLayout(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const source_root = "apps/rooms/rust/runtime/src";
    var src = root.openDir(io, source_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            try appendViolation(gpa, violations, source_root ++ ": could not inspect the runtime module layout with {s}", .{@errorName(err)});
            return;
        },
    };
    defer src.close(io);
    const lib = root.readFileAlloc(io, source_root ++ "/lib.rs", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, source_root ++ "/lib.rs: could not read the runtime module root with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(lib);

    for (runtime_domain_roots) |domain| {
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, source_root ++ "/{s}", .{domain}) catch unreachable;
        var domain_dir = root.openDir(io, path, .{}) catch |err| {
            try appendViolation(gpa, violations, "{s}: required Rooms runtime domain root is missing or unreadable ({s})", .{ path, @errorName(err) });
            continue;
        };
        domain_dir.close(io);

        var declaration_buf: [64]u8 = undefined;
        const declaration = std.fmt.bufPrint(&declaration_buf, "pub mod {s};", .{domain}) catch unreachable;
        if (std.mem.indexOf(u8, lib, declaration) == null) {
            try appendViolation(gpa, violations, source_root ++ "/lib.rs: missing grouped domain declaration `{s}`", .{declaration});
        }
    }

    var entries = src.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".rs") and
            !containsName(&runtime_support_files, entry.name))
        {
            try appendViolation(gpa, violations, source_root ++ "/{s}: domain module must live below a grouped runtime root", .{entry.name});
        }
        if (entry.kind == .directory and !std.mem.eql(u8, entry.name, "documents") and
            !containsName(&runtime_domain_roots, entry.name))
        {
            try appendViolation(gpa, violations, source_root ++ "/{s}: unexpected runtime root directory; place the module under its owning domain", .{entry.name});
        }
    }
}

fn rejectDependency(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    dependency: []const u8,
) !void {
    if (try util.fileContains(io, gpa, root, path, dependency)) {
        try appendViolation(gpa, violations, "{s}: Rooms layer must not depend on {s}", .{ path, dependency });
    }
}

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try checkRuntimeLayout(io, gpa, root, violations);
    for (retired) |path| {
        _ = root.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                try appendViolation(gpa, violations, "{s}: Rust-ownership absence check failed with {s}", .{ path, @errorName(err) });
                continue;
            },
        };
        try appendViolation(
            gpa,
            violations,
            "{s}: retired Rooms owner or crate boundary must not return",
            .{path},
        );
    }
    const services = (try util.readSourceSubject(io, gpa, root, "apps/rooms/rust/services/src/")) orelse {
        try appendViolation(gpa, violations, "apps/rooms/rust/services/src: could not inspect retired Rust identifiers", .{});
        return;
    };
    defer gpa.free(services);
    for (retired_service_identifiers) |identifier| {
        if (std.mem.indexOf(u8, services, identifier) != null) {
            try appendViolation(gpa, violations, "apps/rooms/rust/services/src: retired identifier `{s}` must not return", .{identifier});
        }
    }
    for (shared_manifests) |path| {
        try rejectDependency(io, gpa, root, violations, path, "rooms-product");
        try rejectDependency(io, gpa, root, violations, path, "rooms-platform");
        try rejectDependency(io, gpa, root, violations, path, "rooms-services");
        try rejectDependency(io, gpa, root, violations, path, "rooms-browser");
    }
    try rejectDependency(io, gpa, root, violations, "apps/rooms/rust/platform/Cargo.toml", "rooms-services");
    try rejectDependency(io, gpa, root, violations, "apps/rooms/rust/platform/Cargo.toml", "rooms-browser");
    try rejectDependency(io, gpa, root, violations, "apps/rooms/rust/browser/Cargo.toml", "rooms-platform");
    try rejectDependency(io, gpa, root, violations, "apps/rooms/rust/browser/Cargo.toml", "rooms-services");
    for ([_][]const u8{ "services", "platform", "browser" }) |layer| {
        const path = try std.fmt.allocPrint(gpa, "apps/rooms/rust/{s}/Cargo.toml", .{layer});
        defer gpa.free(path);
        try rejectDependency(io, gpa, root, violations, path, "rooms-product");
    }
    try util.expectFileContains(
        io,
        gpa,
        root,
        violations,
        "apps/rooms/rust/services/Cargo.toml",
        &.{"rooms-platform = { path = \"../platform\" }"},
    );
}

test "Rooms runtime keeps domain roots instead of flat owner modules" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const source_root = "apps/rooms/rust/runtime/src";
    try tmp.dir.createDirPath(std.testing.io, source_root ++ "/documents");
    var declarations: std.ArrayList(u8) = .empty;
    defer declarations.deinit(gpa);
    for (runtime_domain_roots) |domain| {
        const path = try std.fmt.allocPrint(gpa, source_root ++ "/{s}", .{domain});
        defer gpa.free(path);
        try tmp.dir.createDirPath(std.testing.io, path);
        if (!std.mem.eql(u8, domain, "service")) {
            try declarations.print(gpa, "pub mod {s};\n", .{domain});
        }
    }
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = source_root ++ "/lib.rs",
        .data = declarations.items,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = source_root ++ "/session_service.rs",
        .data = "pub struct Session;",
    });
    try tmp.dir.createDirPath(std.testing.io, source_root ++ "/direct_events");

    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |message| gpa.free(message);
        violations.deinit(gpa);
    }
    try checkRuntimeLayout(std.testing.io, gpa, tmp.dir, &violations);
    try std.testing.expectEqual(@as(usize, 3), violations.items.len);
    var missing_service = false;
    var flat_file = false;
    var flat_directory = false;
    for (violations.items) |message| {
        missing_service = missing_service or std.mem.indexOf(u8, message, "pub mod service;") != null;
        flat_file = flat_file or std.mem.indexOf(u8, message, "session_service.rs") != null;
        flat_directory = flat_directory or std.mem.indexOf(u8, message, "direct_events") != null;
    }
    try std.testing.expect(missing_service and flat_file and flat_directory);
}

test "retired Rooms owners and crate boundaries cannot return" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "apps/rooms/server");
    try tmp.dir.createDirPath(std.testing.io, "apps/rooms/rust/services/src/room_server");
    try tmp.dir.createDirPath(std.testing.io, "apps/rooms/rust/services/src/session_service");
    try tmp.dir.createDirPath(std.testing.io, "apps/rooms/rust/services/src/archive/service");
    try tmp.dir.createDirPath(std.testing.io, "apps/rooms/rust/services");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "apps/rooms/rust/services/Cargo.toml",
        .data = "rooms-platform = { path = \"../platform\" }",
    });
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |message| gpa.free(message);
        violations.deinit(gpa);
    }
    try check(std.testing.io, gpa, tmp.dir, &violations);
    try std.testing.expectEqual(@as(usize, 4), violations.items.len);
    try std.testing.expect(std.mem.startsWith(u8, violations.items[0], "apps/rooms/server:"));
    try std.testing.expect(std.mem.startsWith(u8, violations.items[1], "apps/rooms/rust/services/src/room_server:"));
    try std.testing.expect(std.mem.startsWith(u8, violations.items[2], "apps/rooms/rust/services/src/session_service:"));
    try std.testing.expect(std.mem.startsWith(u8, violations.items[3], "apps/rooms/rust/services/src/archive/service:"));
}

test "Rooms crate dependencies keep one direction" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const manifests = [_][]const u8{
        "apps/rooms/rust/application/Cargo.toml",
        "apps/rooms/rust/glowcap/Cargo.toml",
        "apps/rooms/rust/runtime/Cargo.toml",
        "apps/rooms/rust/platform/Cargo.toml",
        "apps/rooms/rust/browser/Cargo.toml",
    };
    for (manifests) |path| {
        const directory = std.fs.path.dirname(path).?;
        try tmp.dir.createDirPath(std.testing.io, directory);
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = path,
            .data =
            \\rooms-platform = { path = "../platform" }
            \\rooms-services = { path = "../services" }
            \\rooms-browser = { path = "../browser" }
            \\rooms-product = { path = "../product" }
            \\
            ,
        });
    }
    try tmp.dir.createDirPath(std.testing.io, "apps/rooms/rust/services/src");
    try tmp.dir.createDirPath(std.testing.io, "apps/rooms/rust/services");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "apps/rooms/rust/services/Cargo.toml",
        .data = "rooms-platform = { path = \"../platform\" }\nrooms-product = { path = \"../product\" }",
    });
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |message| gpa.free(message);
        violations.deinit(gpa);
    }
    try check(std.testing.io, gpa, tmp.dir, &violations);
    // Four forbidden edges in each shared crate, three in platform, and three in
    // browser, plus services depending on product. Services-to-platform is valid.
    try std.testing.expectEqual(@as(usize, 19), violations.items.len);
    for (violations.items) |message| {
        try std.testing.expect(std.mem.indexOf(u8, message, "Rooms layer must not depend on") != null);
    }
}

test "retired service identifiers cannot hide in tests or implementation" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "apps/rooms/rust/services/src/nested");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "apps/rooms/rust/services/src/nested/test.rs",
        .data = "fn room_server_regressed() {} fn archive_service_regressed() {}",
    });
    try tmp.dir.createDirPath(std.testing.io, "apps/rooms/rust/services");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "apps/rooms/rust/services/Cargo.toml",
        .data = "rooms-platform = { path = \"../platform\" }",
    });
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |message| gpa.free(message);
        violations.deinit(gpa);
    }
    try check(std.testing.io, gpa, tmp.dir, &violations);
    try std.testing.expectEqual(@as(usize, 2), violations.items.len);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "`room_server`") != null);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[1], "`archive_service`") != null);
}
