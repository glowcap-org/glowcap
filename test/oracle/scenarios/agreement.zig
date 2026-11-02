//! Two paired sessions agree about every row one grants and the other holds.
//!
//! Each session's tables are correct on their own terms, and
//! `session.audit` holds each to its own counters. This check holds the pair
//! to each other once no frame is in flight and neither peer has work left:
//! an import one side holds is an export the other has mentioned exactly that
//! many times, an export mentioned on the wire is held by the partner to the
//! same count, and a question one side keeps open is an answer the other
//! still owes. A row with no counterpart is authority with no owner: an
//! import the partner can never release, a question nobody can answer, a
//! mention nobody holds. That is a leak of the protocol rather than of
//! memory, and no single-session check can see it.
//!
//! At rest each side has also finished what it accepted. A settled answer
//! keeps no queued call, listener, or projection, because settling drains
//! them, and no local promise still owes its settlement carrier, because the
//! step retries one until it leaves.
//!
//! Every two-peer driver runs this where it reaches rest: the oracle
//! scenarios, the engine fuzz programs, and the Host pair pump the driver
//! tests share.
const std = @import("std");
const model = @import("model");
const session = @import("session");
const engine = @import("engine");

pub const Disagreement = error{
    /// A held import the granter has not mentioned that many times.
    ImportWithoutExport,
    /// A wire-mentioned export the holder does not hold to that count.
    ExportWithoutImport,
    /// An open question the answerer does not carry.
    QuestionWithoutAnswer,
    /// An owed answer the asker does not hold.
    AnswerWithoutQuestion,
    /// A settled answer still keeps work its settlement should have drained.
    SettledAnswerKeepsWork,
    /// A local promise still owes its settlement carrier at rest.
    SettlementOwedAtRest,
};

/// A pair outside the check's boundary, a disagreement between its peers,
/// or a session whose own counters disagree with its rows.
pub const Error = error{ PairNotOpen, PairNotAtRest } || Disagreement || session.audit.Violation;

/// One row the two sessions disagree about: which relation, the position, and
/// what each side counts. `holder_is_p1` says which peer of `check` holds the
/// import or asks the question. For the at-rest relations, the holder is the
/// session that kept the work, and the counts are what it kept and zero.
pub const Finding = struct {
    kind: Disagreement,
    position: u64,
    holder_count: u64,
    granter_count: u64,
    holder_is_p1: bool,
};

/// Whether `peer` has nothing in flight: no received frame waiting for a
/// step, no send waiting to be encoded, and no encoded frame waiting to be
/// taken. The relations hold only between two peers at rest, because a send
/// applies to its sender's tables before its frame exists.
pub fn atRest(peer: *const engine.Peer) bool {
    return peer.inbound.isEmpty() and peer.pending_send.isEmpty() and peer.outbound.isEmpty();
}

/// Both sessions' own counters, then both directions of every relation, for
/// an open pair at rest (`atRest`).
pub fn check(a: *const engine.Peer, b: *const engine.Peer) Error!void {
    if (!a.sessionIsOpen() or !b.sessionIsOpen()) return error.PairNotOpen;
    if (!atRest(a) or !atRest(b)) return error.PairNotAtRest;
    try session.audit.check(&a.session_state);
    try session.audit.check(&b.session_state);
    if (find(a, b)) |finding| return finding.kind;
}

/// The first disagreement between the pair, or null when every row agrees.
pub fn find(a: *const engine.Peer, b: *const engine.Peer) ?Finding {
    if (findDirected(&a.session_state, &b.session_state, true)) |finding| return finding;
    return findDirected(&b.session_state, &a.session_state, false);
}

/// `holder` imports what `granter` exports, and asks what `granter` answers.
/// The at-rest relations read `holder` alone, so each side is read once.
fn findDirected(holder: *const session.Session, granter: *const session.Session, holder_is_p1: bool) ?Finding {
    var imports: Imports = .{ .granter = granter };
    session.inspect.forEachImport(holder, &imports, Imports.take);
    var exports: Exports = .{ .holder = holder };
    session.inspect.forEachExport(granter, &exports, Exports.take);
    var questions: Questions = .{ .asker = holder, .answerer = granter };
    session.inspect.forEachOutboundAnswer(holder, &questions, Questions.take);
    var answers: Answers = .{ .asker = holder };
    session.inspect.forEachInboundAnswer(granter, &answers, Answers.take);
    var finding = imports.finding orelse exports.finding orelse questions.finding orelse
        answers.finding orelse findUnfinished(holder) orelse return null;
    finding.holder_is_p1 = holder_is_p1;
    return finding;
}

/// Work `owner` accepted and has not finished although it is at rest.
fn findUnfinished(owner: *const session.Session) ?Finding {
    var settled: Settled = .{};
    session.inspect.forEachInboundAnswer(owner, &settled, Settled.take);
    if (settled.finding) |finding| return finding;
    if (owner.detached_inbound_answers) |store| {
        var rows = store.rows.valueIterator();
        while (rows.next()) |row| {
            if (keptWork(row.payload)) |kept| return .{
                .kind = error.SettledAnswerKeepsWork,
                .position = namePosition(row.target.name),
                .holder_count = kept,
                .granter_count = 0,
                .holder_is_p1 = undefined,
            };
        }
    }
    const registry = owner.local_promises orelse return null;
    if (registry.deferred == 0) return null;
    return .{
        .kind = error.SettlementOwedAtRest,
        .position = 0,
        .holder_count = registry.deferred,
        .granter_count = 0,
        .holder_is_p1 = undefined,
    };
}

/// How many queued calls, listeners, and projections a settled payload still
/// keeps, or null for a pending payload or a settled one that kept none.
fn keptWork(payload: *const session.AnswerPayload) ?u64 {
    if (payload.resolution == null) return null;
    const kept = payload.queue.items.len + payload.listeners.len() + payload.projections.items.len;
    return if (kept == 0) null else kept;
}

/// The position an answer name carries, in either namespace, for a report.
fn namePosition(name: model.AnswerName) u64 {
    return name.identityWords()[1];
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
        // own hold. The rest are wire mentions (`ExportTable.wireHeld`).
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
    asker: *const session.Session,
    answerer: *const session.Session,
    finding: ?Finding = null,
    fn take(self: *Questions, view: session.AnswerRowView) void {
        const wire = switch (view.position) {
            .wire => |wire| wire,
            .virtual => return,
        };
        if (self.finding != null or !self.asker.outbound_answers.isQuestion(wire)) return;
        if (self.answerer.inbound_answers.contains(.fromWire(wire))) return;
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
        if (self.finding != null or self.asker.outbound_answers.isQuestion(wire)) return;
        self.finding = .{
            .kind = error.AnswerWithoutQuestion,
            .position = wire.int(),
            .holder_count = 0,
            .granter_count = 1,
            .holder_is_p1 = undefined,
        };
    }
};

const Settled = struct {
    finding: ?Finding = null,
    fn take(self: *Settled, view: session.AnswerRowView) void {
        if (self.finding != null or !view.view.resolved) return;
        const kept = view.view.queued_calls + view.view.listeners + view.view.projections;
        if (kept != 0) self.finding = .{
            .kind = error.SettledAnswerKeepsWork,
            .position = namePosition(view.position),
            .holder_count = kept,
            .granter_count = 0,
            .holder_is_p1 = undefined,
        };
    }
};
