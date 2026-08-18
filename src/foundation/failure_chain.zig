//! Allocation-free first-and-secondary failure retention. This is plain data:
//! no logging, recovery, I/O, or runtime policy. Boundaries may attach a
//! coarse, portable classification when an error identity alone cannot
//! preserve the originating public result family. A seam that
//! must finish cleanup after one operation fails can return the exact first
//! Zig error while retaining the first later consequence and a bounded count
//! of all later failures.

pub const Classification = enum {
    invalid_argument,
    would_block,
    timeout,
    closed,
    session,
    malformed,
    frame_too_large,
    internal,
    io,
};

pub const FailureChain = struct {
    cause: anyerror,
    /// Optional stable name supplied by a boundary that cannot preserve the
    /// originating Zig error identity. The bytes must be static or owned by
    /// the boundary for as long as any projection of this chain can survive;
    /// copying the value deliberately does not copy text.
    cause_name: ?[]const u8 = null,
    classification: ?Classification = null,
    secondary_cause: ?anyerror = null,
    secondary_cause_name: ?[]const u8 = null,
    secondary_classification: ?Classification = null,
    /// Number of failures after `cause`. The first is named above; saturation
    /// is an explicit indication that the bounded record saw still more.
    secondary_count: u16 = 0,

    pub fn init(cause: anyerror) FailureChain {
        return .{ .cause = cause };
    }

    pub fn initNamed(cause: anyerror, name: []const u8) FailureChain {
        return .{ .cause = cause, .cause_name = name };
    }

    pub fn initClassified(cause: anyerror, name: []const u8, classification: Classification) FailureChain {
        return .{ .cause = cause, .cause_name = name, .classification = classification };
    }

    pub fn primaryName(self: FailureChain) []const u8 {
        return self.cause_name orelse @errorName(self.cause);
    }

    pub fn secondaryName(self: FailureChain) ?[]const u8 {
        const cause = self.secondary_cause orelse return null;
        return self.secondary_cause_name orelse @errorName(cause);
    }

    pub fn note(self: *FailureChain, consequence: anyerror) void {
        if (self.secondary_cause == null) self.secondary_cause = consequence;
        self.secondary_count +|= 1;
    }

    pub fn noteNamed(self: *FailureChain, consequence: anyerror, name: []const u8) void {
        if (self.secondary_cause == null) {
            self.secondary_cause = consequence;
            self.secondary_cause_name = name;
        }
        self.secondary_count +|= 1;
    }

    pub fn noteClassified(
        self: *FailureChain,
        consequence: anyerror,
        name: []const u8,
        classification: Classification,
    ) void {
        if (self.secondary_cause == null) {
            self.secondary_cause = consequence;
            self.secondary_cause_name = name;
            self.secondary_classification = classification;
        }
        self.secondary_count +|= 1;
    }

    /// Append a later failure chain without replacing this chain's cause or
    /// first secondary. `later.cause` is one consequence; its own secondary
    /// count is added because those failures happened too.
    pub fn noteChain(self: *FailureChain, later: FailureChain) void {
        if (later.classification) |classification|
            self.noteClassified(later.cause, later.primaryName(), classification)
        else if (later.cause_name) |name|
            self.noteNamed(later.cause, name)
        else
            self.note(later.cause);
        self.secondary_count +|= later.secondary_count;
    }
};
