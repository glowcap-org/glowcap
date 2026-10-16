//! The subscription carried by a deliver. Baseline retains its callback link.
//! Next prepares an ordinary answer listener before publishing the new answer.
const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");
const answers = @import("answers/store.zig");
const baseline = @import("v1_0.zig");
const Session = session.Session;

pub const Prepared = union(enum) {
    baseline: baseline.PreparedInboundResolver,
    next: struct {
        answer: model.AnswerName,
        virtual_answer: ?model.VirtualAnswer,
        resolver_import: model.ImportPosition,
        payload: ?*answers.AnswerPayload,
    },

    pub fn virtualAnswer(self: *const Prepared) ?model.VirtualAnswer {
        return switch (self.*) {
            .baseline => |value| value.virtual_answer,
            .next => |value| value.virtual_answer,
        };
    }

    pub fn abandon(self: *Prepared, owner: *Session) void {
        switch (self.*) {
            .baseline => {},
            .next => |*value| if (value.payload) |payload| {
                // No authority was retained during preparation.
                _ = answers.releaseAnswerPayload(owner.allocator, payload);
                value.payload = null;
            },
        }
    }

    pub fn commit(self: *Prepared, owner: *Session) void {
        switch (self.*) {
            .baseline => |value| value.commit(owner),
            .next => |*value| {
                if (value.virtual_answer) |virtual| {
                    commitVirtualInboundAnswer(owner, virtual);
                    owner.commitFreshInboundAnswerNamed(value.answer);
                }
                const cell = owner.inbound_answers.getPtr(value.answer) orelse unreachable;
                std.debug.assert(cell.payload == null);
                cell.payload = value.payload.?;
                value.payload = null;
                owner.adoptImportRetain(value.resolver_import);
            },
        }
    }
};

/// Named cost: one answer payload and one listener-list backing for a next
/// result subscription. The receive transaction must own these before answer
/// publication: allocating later could accept a call without its mandatory
/// callback on OOM. The prepared token frees both on refusal, or transfers them
/// to the answer store until listener drain/GC/teardown. Bounded by inbound
/// answer and per-target listener limits; deliver-only allocates neither.
pub fn prepare(owner: *Session, deliver: model.view.Deliver) !?Prepared {
    const resolver = deliver.resolve_me_desc orelse return null;
    const position = resolver.position() orelse return error.UnexpectedMessage;
    const virtual = if (deliver.answer == null) try nextVirtualInboundAnswer(owner) else null;
    const answer: model.AnswerName = if (deliver.answer) |wire| .fromWire(wire) else .fromVirtual(virtual.?);
    const imported = model.ImportPosition.from(position);
    if (owner.captp_version == .v1_0) return .{ .baseline = try owner.prepareInboundResolver(answer, imported, virtual) };
    if (deliver.listen_mode == .settling_only) return error.UnexpectedMessage;
    if (owner.limits.max_listeners_per_target == 0) return error.ListenerCapExceeded;
    try owner.prepareFreshInboundAnswerNamed(answer);
    // A private pending cell gives the wider receive transaction the same lazy
    // payload and listener allocation as a later op:listen. On refusal it owns
    // both allocations. Commit attaches it to the fresh answer without failure.
    var cell = answers.AnswerCell.initPending(0);
    const payload = try answers.ensureAnswerPayload(owner.allocator, &cell);
    errdefer _ = answers.releaseAnswerPayload(owner.allocator, payload);
    try payload.listeners.append(owner.allocator, .{
        .listener = .{ .import_position = imported },
        .mode = deliver.listen_mode,
    });
    return .{ .next = .{ .answer = answer, .virtual_answer = virtual, .resolver_import = imported, .payload = payload } };
}

/// A resolver-only call has no peer-visible pipelining slot. Its private name
/// belongs to a disjoint namespace and retires after the local result drains.
pub fn allocateInboundAnswer(owner: *Session) session.Error!model.VirtualAnswer {
    const answer = try nextVirtualInboundAnswer(owner);
    commitVirtualInboundAnswer(owner, answer);
    return answer;
}

pub fn nextVirtualInboundAnswer(owner: *const Session) session.Error!model.VirtualAnswer {
    const id = owner.next_virtual_inbound_answer;
    if (id == 0) return error.VirtualAnswerSpaceExhausted;
    return .from(id);
}

pub fn commitVirtualInboundAnswer(owner: *Session, answer: model.VirtualAnswer) void {
    std.debug.assert(owner.next_virtual_inbound_answer == answer.int());
    owner.next_virtual_inbound_answer = if (answer.int() == std.math.maxInt(u64)) 0 else answer.int() + 1;
}
