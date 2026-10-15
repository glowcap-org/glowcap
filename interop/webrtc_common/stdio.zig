//! The stdio signaling wire a Zig WebRTC peer under `interop/` speaks with a
//! harness in another process: one JSON object per line.
//!
//!   {"type":"identity","designator":"…"}  the writer's key designator
//!   {"type":"offer","sdp":"…"}             an SDP offer
//!   {"type":"answer","sdp":"…"}            an SDP answer
//!   {"type":"candidate","candidate":{…}}   a trickled ICE candidate
//!
//! A candidate line whose candidate is `null` ends the far peer's candidates
//! and applies nothing.
//!
//! `Signaling` owns both directions. The main thread writes stdout through it
//! and drives `openChannel`. `readInbound` runs on a second thread, applies
//! each inbound line to the peer, and latches its first failure, which the
//! main thread returns at its next look. A line this peer's role does not
//! take is a failure, never a skip.

const std = @import("std");
const webrtc = @import("webrtc");

/// The longest inbound line: an escaped SDP and its framing fit with room.
pub const max_line_bytes: usize = 1 << 16;

pub const Role = enum { offerer, answerer };

const ErrorInt = @Int(.unsigned, @bitSizeOf(anyerror));

pub const Signaling = struct {
    role: Role,
    peer: *webrtc.Peer,
    out: std.Io.File.Writer,
    /// The reader's first failure as an error integer, 0 while it has none.
    failure: std.atomic.Value(ErrorInt) = .init(0),
    /// Set once the reader applied the far peer's description.
    described: std.atomic.Value(bool) = .init(false),

    /// `out_buf` buffers stdout and outlives the value.
    pub fn init(io: std.Io, role: Role, peer: *webrtc.Peer, out_buf: []u8) Signaling {
        return .{ .role = role, .peer = peer, .out = std.Io.File.stdout().writer(io, out_buf) };
    }

    /// Announce the key the far side pins, before any SDP flows.
    pub fn writeIdentity(self: *Signaling, designator: []const u8) !void {
        try self.writeLine(.{ .type = "identity", .designator = designator });
    }

    /// Return the reader's latched failure, if it has one.
    pub fn check(self: *const Signaling) !void {
        const code = self.failure.load(.acquire);
        if (code != 0) return @errorFromInt(code);
    }

    /// Bring the DataChannel up. The offerer writes its offer first, and the
    /// answerer answers once the reader applied the offer. Both trickle local
    /// candidates until the channel opens, the reader fails, or `max_polls`
    /// readiness waits of 50 ms pass.
    pub fn openChannel(self: *Signaling, resident: *webrtc.Resident, max_polls: usize) !void {
        var signal_buf: [webrtc.max_signal_bytes]u8 = undefined;
        var len: usize = 0;
        if (self.role == .offerer) try self.writeDescription("offer", try self.peer.createOffer(&signal_buf, &len));
        var answered = false;
        for (0..max_polls) |_| {
            var events: [16]webrtc.ReadyEvent = undefined;
            const count = try resident.pollReady(&events, 50);
            for (events[0..count]) |event| {
                if (event.subject != @backingInt(self.peer.id())) return error.UnexpectedReadySubject;
            }
            try self.check();
            if (self.role == .answerer and !answered and self.described.load(.acquire)) {
                try self.writeDescription("answer", try self.peer.createAnswer(&signal_buf, &len));
                answered = true;
            }
            while (try self.peer.nextLocalCandidate(&signal_buf, &len)) |candidate| {
                try self.writeCandidate(candidate);
            }
            self.peer.checkOpen() catch |err| switch (err) {
                error.WouldBlock => continue,
                error.Closed => return error.ChannelClosed,
                error.Failed => return error.ChannelFailed,
            };
            return;
        }
        return error.ChannelBringUpTimeout;
    }

    /// Read stdin until it ends or the peer cancels this reader, applying each
    /// line to the peer. Runs on its own thread and never writes stdout.
    pub fn readInbound(self: *Signaling, io: std.Io, gpa: std.mem.Allocator) void {
        self.readLines(io, gpa) catch |err| switch (err) {
            error.Canceled => {},
            else => self.failure.store(@intFromError(err), .release),
        };
    }

    fn readLines(self: *Signaling, io: std.Io, gpa: std.mem.Allocator) !void {
        var buf: [max_line_bytes]u8 = undefined;
        var reader = std.Io.File.stdin().reader(io, &buf);
        // One arena per line, reset with its capacity kept, so steady reading
        // allocates nothing.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        while (true) {
            const raw = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => {
                    if (reader.interface.bufferedLen() != 0) return error.SignalingLineUnterminated;
                    return;
                },
                error.StreamTooLong => return error.SignalingLineTooLong,
                error.ReadFailed => return reader.err orelse error.ReadFailed,
            };
            const line = std.mem.trimEnd(u8, raw, "\r\n");
            if (line.len != 0) try self.apply(arena.allocator(), line);
            _ = arena.reset(.retain_capacity);
        }
    }

    const Inbound = struct {
        type: []const u8,
        sdp: ?[]const u8 = null,
        candidate: ?std.json.Value = null,
    };

    fn apply(self: *Signaling, arena: std.mem.Allocator, line: []const u8) !void {
        const inbound = try std.json.parseFromSliceLeaky(Inbound, arena, line, .{ .ignore_unknown_fields = true });
        if (std.mem.eql(u8, inbound.type, "candidate")) {
            const candidate = inbound.candidate orelse return;
            if (candidate == .null) return;
            // The harness orders keys however its JSON library likes, so the
            // candidate is written back out as the text the sidecar takes.
            var text: std.Io.Writer.Allocating = .init(arena);
            try std.json.Stringify.value(candidate, .{}, &text.writer);
            return self.peer.addRemoteCandidate(text.written());
        }
        const expected = switch (self.role) {
            .offerer => "answer",
            .answerer => "offer",
        };
        if (!std.mem.eql(u8, inbound.type, expected)) return error.UnexpectedSignalingLine;
        const sdp = inbound.sdp orelse return error.DescriptionLineHasNoSdp;
        switch (self.role) {
            .offerer => try self.peer.setRemoteAnswer(sdp),
            .answerer => try self.peer.setRemoteOffer(sdp),
        }
        self.described.store(true, .release);
    }

    fn writeDescription(self: *Signaling, kind: []const u8, sdp: []const u8) !void {
        try self.writeLine(.{ .type = kind, .sdp = sdp });
    }

    /// The sidecar serialized the candidate, so it is embedded verbatim.
    fn writeCandidate(self: *Signaling, candidate_json: []const u8) !void {
        const w = &self.out.interface;
        w.print("{{\"type\":\"candidate\",\"candidate\":{s}}}\n", .{candidate_json}) catch return self.writeFailure();
        w.flush() catch return self.writeFailure();
    }

    fn writeLine(self: *Signaling, value: anytype) !void {
        const w = &self.out.interface;
        std.json.Stringify.value(value, .{}, w) catch return self.writeFailure();
        w.writeByte('\n') catch return self.writeFailure();
        w.flush() catch return self.writeFailure();
    }

    fn writeFailure(self: *const Signaling) anyerror {
        return self.out.err orelse error.WriteFailed;
    }
};
