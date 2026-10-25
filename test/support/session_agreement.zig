//! Two paired sessions agree about every row one grants and the other holds.
//!
//! Each session's tables are correct on their own terms, and
//! `session_bounds.zig` holds each to its declared caps. This check holds the
//! pair to each other once no frame is in flight: an import one side holds is
//! an export the other has mentioned exactly that many times, an export
//! mentioned on the wire is held by the partner to the same count, and a
//! question one side keeps open is an answer the other still owes. A row with
//! no counterpart is authority with no owner: an import the partner can never
//! release, a question nobody can answer, a mention nobody holds. That is a
//! leak of the protocol rather than of memory, and no single-session check
//! can see it.
const std = @import("std");
const glowcap = @import("glowcap");
const session = glowcap.ocapn.session;
const engine = glowcap.ocapn.engine;

pub const Disagreement = error{
    /// A held import the granter has not mentioned that many times.
    ImportWithoutExport,
    /// A wire-mentioned export the holder does not hold to that count.
    ExportWithoutImport,
    /// An open question the answerer does not carry.
    QuestionWithoutAnswer,
    /// An owed answer the asker does not hold.
    AnswerWithoutQuestion,
};

/// One row the two sessions disagree about: which relation, the position, and
/// what each side counts. `holder_is_p1` says which peer of `check` holds the
/// import or asks the question.
pub const Finding = struct {
    kind: Disagreement,
    position: u64,
    holder_count: u64,
    granter_count: u64,
    holder_is_p1: bool,
};

/// Both directions of every relation, for a pair with nothing in flight.
pub fn check(a: *const engine.Peer, b: *const engine.Peer) Disagreement!void {
    if (find(a, b)) |finding| return finding.kind;
}

/// The first disagreement between the pair, or null when every row agrees.
pub fn find(a: *const engine.Peer, b: *const engine.Peer) ?Finding {
    if (findDirected(&a.session_state, &b.session_state, true)) |finding| return finding;
    return findDirected(&b.session_state, &a.session_state, false);
}

/// `holder` imports what `granter` exports, and asks what `granter` answers.
fn findDirected(holder: *const session.Session, granter: *const session.Session, holder_is_p1: bool) ?Finding {
    var imports: Imports = .{ .granter = granter };
    session.inspect.forEachImport(holder, &imports, Imports.take);
    var exports: Exports = .{ .holder = holder };
    session.inspect.forEachExport(granter, &exports, Exports.take);
    var questions: Questions = .{ .answerer = granter };
    session.inspect.forEachOutboundAnswer(holder, &questions, Questions.take);
    var answers: Answers = .{ .asker = holder };
    session.inspect.forEachInboundAnswer(granter, &answers, Answers.take);
    var finding = imports.finding orelse exports.finding orelse questions.finding orelse answers.finding orelse return null;
    finding.holder_is_p1 = holder_is_p1;
    return finding;
}

/// The bootstrap object is held by right of the session, never by a mention,
/// so its position is outside the mention relation on both sides.
fn isBootstrap(position: u64) bool {
    return position == engine.bootstrap_position;
}

const Imports = struct {
    granter: *const session.Session,
    finding: ?Finding = null,
    fn take(self: *Imports, view: session.ImportView) void {
        if (isBootstrap(view.position.int()) or self.finding != null) return;
        const mentioned = self.granter.exports.wireHeld(.from(view.position.int()));
        if (mentioned != view.refcount) self.finding = .{
            .kind = error.ImportWithoutExport,
            .position = view.position.int(),
            .holder_count = view.refcount,
            .granter_count = mentioned,
            .holder_is_p1 = undefined,
        };
    }
};

const Exports = struct {
    holder: *const session.Session,
    finding: ?Finding = null,
    fn take(self: *Exports, view: session.ExportView) void {
        if (isBootstrap(view.position.int()) or self.finding != null) return;
        // `refcount` is the row's whole count, one of which is the exporter's
        // own hold; the rest are wire mentions (`ExportTable.wireHeld`).
        const wire_held = view.refcount -| 1;
        const held = self.holder.imports.count(.from(view.position.int()));
        if (held != wire_held) self.finding = .{
            .kind = error.ExportWithoutImport,
            .position = view.position.int(),
            .holder_count = held,
            .granter_count = wire_held,
            .holder_is_p1 = undefined,
        };
    }
};

const Questions = struct {
    answerer: *const session.Session,
    finding: ?Finding = null,
    fn take(self: *Questions, view: session.AnswerRowView) void {
        const wire = switch (view.position) {
            .wire => |wire| wire,
            .virtual => return,
        };
        if (self.finding != null or self.answerer.inbound_answers.contains(.fromWire(wire))) return;
        self.finding = .{
            .kind = error.QuestionWithoutAnswer,
            .position = wire.int(),
            .holder_count = 1,
            .granter_count = 0,
            .holder_is_p1 = undefined,
        };
    }
};

const Answers = struct {
    asker: *const session.Session,
    finding: ?Finding = null,
    fn take(self: *Answers, view: session.AnswerRowView) void {
        const wire = switch (view.position) {
            .wire => |wire| wire,
            .virtual => return,
        };
        if (self.finding != null or self.asker.outbound_answers.contains(wire)) return;
        self.finding = .{
            .kind = error.AnswerWithoutQuestion,
            .position = wire.int(),
            .holder_count = 0,
            .granter_count = 1,
            .holder_is_p1 = undefined,
        };
    }
};

test "a fresh pair agrees" {
    var pair = try engine.pairing.paired(std.testing.allocator);
    defer pair.deinit();
    try check(&pair.p1, &pair.p2);
}
