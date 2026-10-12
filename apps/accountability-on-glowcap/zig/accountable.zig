//! The accountability adapter: the send/recv interposer, above glowcap.
//!
//! This is the integration seam the repository named. A consumer wraps glowcap's
//! caller-owned `Peer`/`Vat` and interposes at its own invocation boundary:
//!
//!   * Before delegating an eventual-send to the wire, it writes a durable
//!     *Attempt* Episode (intent to invoke, attributed to the true caller).
//!   * When the matching resolution returns, it writes an *Outcome* Episode.
//!   * A host accounts symmetrically: when it serves an inbound deliver and
//!     resolves it, it writes an Outcome Episode attributing the true caller.
//!
//! glowcap is untouched. The adapter never reaches into the session, never adds a
//! CapTP semantic, and never moves Episode/KERI vocabulary below the `Peer` line.
//! It owns its own files (`.data/episodes.jsonld`, `.data/transparency.log`,
//! `.data/transparency.root`) and an in-memory transparency log.

const std = @import("std");

const identity = @import("identity.zig");
const path_io = @import("path_io.zig");
const episode = @import("episode.zig");
const log = @import("log.zig");

pub const Error = episode.Error || error{ MakePathFailed, WriteFailed, ReadFailed };

/// A local accountability store bound to one identity and one `.data/` dir.
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    signer: *identity.Identity,
    dir: []const u8,
    tlog: log.Log,
    /// Accumulated Episode lines, also persisted to `episodes.jsonld`.
    episodes: std.ArrayList([]u8) = .empty,
    seq: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, signer: *identity.Identity, dir: []const u8) Error!Store {
        // Probe before creating; `path_io` says why. It distinguishes an absent
        // directory from an `openDir` that failed for some other reason, and it
        // re-verifies when another creator wins the race between the probe and
        // the create.
        path_io.ensureDirPath(io, dir) catch return Error.MakePathFailed;
        return .{
            .allocator = allocator,
            .io = io,
            .signer = signer,
            .dir = dir,
            .tlog = log.Log.init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.episodes.items) |line| self.allocator.free(line);
        self.episodes.deinit(self.allocator);
        self.tlog.deinit();
    }

    /// Emit, persist, and transparency-log one Episode attributing `subject`.
    /// Returns the Episode's transparency-log leaf digest.
    pub fn record(
        self: *Store,
        kind: episode.Kind,
        subject: []const u8,
        affordance: []const u8,
        object: []const u8,
    ) Error!log.Digest {
        const now: i64 = @intCast(std.Io.Clock.now(.awake, self.io).nanoseconds);
        const line = try episode.emit(self.allocator, self.io, self.signer, .{
            .kind = kind,
            .subject = subject,
            .affordance = affordance,
            .object = object,
            .graph = self.signer.aidSlice(),
            .seq = self.seq,
            .valid_time = now,
            .tx_time = now,
        });
        errdefer self.allocator.free(line);
        self.seq += 1;

        try self.episodes.append(self.allocator, line);
        const leaf = log.leafHash(line);
        try self.tlog.append(leaf);

        try self.flush();
        return leaf;
    }

    /// Write the current Episode set and transparency root to `.data/`. The whole
    /// file is rewritten each time, a demo simplification. An append-only writer
    /// is the production shape.
    fn flush(self: *Store) Error!void {
        var path_buf: [512]u8 = undefined;
        const dir = std.Io.Dir.cwd();

        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.allocator);
        for (self.episodes.items) |line| {
            bytes.appendSlice(self.allocator, line) catch return Error.WriteFailed;
            bytes.append(self.allocator, '\n') catch return Error.WriteFailed;
        }
        const ep_path = std.fmt.bufPrint(&path_buf, "{s}/episodes.jsonld", .{self.dir}) catch unreachable;
        dir.writeFile(self.io, .{ .sub_path = ep_path, .data = bytes.items }) catch return Error.WriteFailed;

        const root = try self.tlog.root();
        const root_hex = log.toHex(root);
        const root_path = std.fmt.bufPrint(&path_buf, "{s}/transparency.root", .{self.dir}) catch unreachable;
        dir.writeFile(self.io, .{ .sub_path = root_path, .data = &root_hex }) catch return Error.WriteFailed;
    }

    /// Verify every Episode this store holds. Returns the count verified.
    pub fn auditAll(self: *Store) Error!usize {
        for (self.episodes.items) |line| {
            try episode.verify(self.allocator, line);
        }
        return self.episodes.items.len;
    }

    pub fn currentRoot(self: *const Store) Error!log.Digest {
        return self.tlog.root();
    }
};
