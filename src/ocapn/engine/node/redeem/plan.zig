//! One owned, parsed exporter dial plan.
//!
//! A give's locator is parsed once into canonical identity plus ordered paths.
//! The scheduler borrows the active path and never reparses on retry.

const std = @import("std");

const model = @import("model");

/// Alternatives a recipient accepts from one exporter locator. The primary is
/// always one additional path.
pub const max_alt_locator_count: usize = 8;
pub const max_alt_locator_bytes: usize = 4 * 1024;

/// One parsed dial path. Every field is owned by the enclosing plan; `hints`
/// stays complete because a transport may consume more than the generic direct
/// address projection.
pub const Path = struct {
    transport: []const u8,
    designator: []const u8,
    hints: model.Hints,
};

/// Canonical peer identity plus primary-first dial paths.
pub const Owned = struct {
    identity: []u8,
    paths: []Path,

    pub fn view(self: Owned, index: usize) model.PeerLocator {
        const path = self.paths[index];
        return .{
            .transport = path.transport,
            .designator = path.designator,
            .hints = path.hints,
        };
    }

    /// Release only the paths when the exporter cache adopts `identity`.
    pub fn deinitPaths(self: *const Owned, allocator: std.mem.Allocator) void {
        for (self.paths) |path| deinitPath(allocator, path);
        allocator.free(self.paths);
    }

    pub fn deinit(self: *const Owned, allocator: std.mem.Allocator) void {
        self.deinitPaths(allocator);
        allocator.free(self.identity);
    }
};

fn deinitPath(allocator: std.mem.Allocator, path: Path) void {
    allocator.free(path.transport);
    allocator.free(path.designator);
    model.freeHints(allocator, path.hints);
}

fn hintValue(hints: model.Hints, name: []const u8) ?[]const u8 {
    for (hints.entries) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        return switch (entry.value) {
            .string, .bytes => |value| value,
            else => null,
        };
    }
    return null;
}

/// Parse one URI into an owned path. Only the primary locator's
/// `alt-locators` hint ranks paths; an alternative's own hint is retained for
/// its transport but is not recursively expanded.
fn parsePath(
    allocator: std.mem.Allocator,
    uri: []const u8,
) error{ OutOfMemory, UnparseableExporterLocator }!Path {
    const parsed = model.uri.parsePeer(allocator, uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnparseableExporterLocator,
    };
    return .{
        .transport = parsed.transport,
        .designator = parsed.designator,
        .hints = parsed.hints,
    };
}

/// Parse identity and ordered paths as one transaction. Unparseable or
/// over-budget alternatives refuse the complete plan, so partial hint policy
/// is never retained.
pub fn parse(
    allocator: std.mem.Allocator,
    exporter_locator: []const u8,
) error{ OutOfMemory, UnparseableExporterLocator }!Owned {
    const primary = model.uri.parsePeer(allocator, exporter_locator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnparseableExporterLocator,
    };
    var primary_owned = false;
    errdefer if (!primary_owned) model.freePeerLocator(allocator, primary);

    var paths: std.ArrayListUnmanaged(Path) = .empty;
    errdefer {
        for (paths.items) |path| deinitPath(allocator, path);
        paths.deinit(allocator);
    }
    try paths.append(allocator, .{
        .transport = primary.transport,
        .designator = primary.designator,
        .hints = primary.hints,
    });
    primary_owned = true;

    if (hintValue(primary.hints, model.transport.hint_alt_locators)) |alternatives| {
        if (alternatives.len == 0 or alternatives.len > max_alt_locator_bytes)
            return error.UnparseableExporterLocator;

        var count: usize = 0;
        var list = std.mem.splitScalar(u8, alternatives, ',');
        while (list.next()) |raw_uri| {
            const alt_uri = std.mem.trim(u8, raw_uri, " \t");
            if (alt_uri.len == 0) return error.UnparseableExporterLocator;
            count += 1;
            if (count > max_alt_locator_count) return error.UnparseableExporterLocator;

            const path = try parsePath(allocator, alt_uri);
            var path_owned = true;
            errdefer if (path_owned) deinitPath(allocator, path);
            try paths.append(allocator, path);
            path_owned = false;
        }
    }

    // writePeer on a just-parsed peer should only fail OOM; fold every other
    // encode refusal into the same unparseable path as parsePeer.
    const identity = model.uri.writePeer(allocator, .{
        .transport = paths.items[0].transport,
        .designator = paths.items[0].designator,
        .hints = model.Hints.emptyFalse(),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnparseableExporterLocator,
    };
    errdefer allocator.free(identity);
    return .{
        .identity = identity,
        .paths = try paths.toOwnedSlice(allocator),
    };
}
