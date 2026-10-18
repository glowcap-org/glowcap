//! A prepared hosted call's invocation and the one batch it stages: content,
//! participants, a structural effect or created child, control changes, and
//! the receipt, all through the call's one staging operation.
const std = @import("std");
const core = @import("loam_access_core");
const storage = @import("loam_access_storage");
const loam = @import("loam_core");
const hosting = @import("loam_hosting");
const driver = @import("driver_core");
const service = @import("service.zig");
const working = @import("working.zig");
const ContentDelta = @import("content_delta.zig").ContentDelta;
const descriptions = @import("description.zig");
const inventory = @import("inventory.zig");
const State = working.State;
const state = working.state;

pub fn invoke(call: *hosting.Call, _: loam.RecordView, _: []const u8, _: []const driver.Value) !driver.Value {
    const value = state(call.preparation.?.context);
    if (!value.ready) return error.RecordUnloaded;
    switch (value.request) {
        .forward => {
            const bound = value.content.?;
            const intent = call.dispatch orelse hosting.Call.Intent{ .verb = value.verb, .args = value.args };
            if (bound.behavior.admit_forward) |admit| {
                const view = try value.store().currentView(bound.lease);
                var admission_call = service.ContentCallState.init(call, view, .{ .verb = value.verb, .args = value.args }, false, value.retry);
                admission_call.operation = value.operation;
                admission_call.graph = value.content_graph;
                try admit(bound.behavior.context, admission_call.handle(), try service.ForwardWork.measure(value.verb, intent));
                if (admission_call.replacement != null or admission_call.edits.items.len != 0 or admission_call.appended.items.len != 0 or admission_call.graph_replaced) return error.InvalidMutation;
            }
            call.forward = .{ .target = call.dependent_target.?, .verb = intent.verb, .args = intent.args };
            return .{ .void = {} };
        },
        .derive => |share| return share.invoke(),
        .observe => |registration| return registration.invoke(),
        .mutation_sequence => return .{ .integer = @intCast(value.endpoint.mutations.next) },
        .sequence => return .{ .integer = std.math.cast(i64, value.endpoint.derivations.next) orelse return error.SequenceExhausted },
        .durable_name => return .{ .string = value.swiss.slice() },
        .describe_control => |description| return descriptions.control(call.arena(), description.*),
        .inspect_access => |inspection| return inventory.encode(call.arena(), &inspection.policy, inspection.item),
        .describe, .inspect_fixed => |description| return descriptions.encode(call.arena(), description.*),
        .inventory => |page| return page.result.?,
        .content, .control => {},
    }
    if (value.mutation) |mutation| if (mutation.lease != null) return mutation.replay();
    if (value.content) |bound| {
        const view = try value.store().currentView(bound.lease);
        const behavior = bound.behavior;
        var content_call = service.ContentCallState.init(call, view, .{ .verb = value.verb, .args = value.args }, value.mutation != null, value.retry);
        content_call.graph = value.content_graph;
        content_call.operation = value.operation;
        content_call.creates = value.creation != null;
        if (value.participants) |*participants| content_call.participants = try participants.calls(value.arena, &content_call);
        const reply = try behavior.invoke(behavior.context, content_call.handle(), try value.invocation());
        if (value.participants) |*participants| try participants.retain(value.arena, content_call.participants);
        const participant_writes = if (value.participants) |*participants| participants.changed() else false;
        if (value.retry == .read_only and (content_call.writes() or participant_writes or value.resource_effect != null or value.creation != null)) return error.InvalidMutation;
        if (value.content_graph != null and content_call.replacement != null) return error.InvalidMutation;
        if (value.creation) |*creation| {
            // Hosting owns a creating call's reply: the child it made.
            try creation.retain(reply, &content_call);
            call.result = createdReply;
        } else if (content_call.child_payload != null) return error.NoDeclaredChild;
        // A creating call's receipt holds the child's facet, retained when
        // staging mints it.
        if (value.mutation) |mutation| if (value.creation == null) try mutation.retainResult(reply);
        value.content_delta = try ContentDelta.prepare(value.arena, view, content_call.replacement, content_call.edits.items, content_call.appended.items);
        value.graph_delta = content_call.graph_delta;
        // A receipt stages even when nothing else changed.
        if (value.mutation != null or value.content_delta != null or value.graph_delta != null or value.changed or participant_writes) {
            call.transaction = .{ .context = value, .stage = stage };
        }
        return reply;
    }
    if (value.request == .control and value.request.control == .attenuate) {
        call.transaction = .{ .context = value, .stage = stage };
        call.result = controlReply;
        call.confirmation = .{ .context = value, .apply = confirmControl, .requires_commit = true };
        return .{ .void = {} };
    }
    const result: driver.Value = .{ .boolean = value.changed };
    if (value.mutation) |mutation| try mutation.retainResult(result);
    if (value.changed or value.mutation != null) call.transaction = .{ .context = value, .stage = stage };
    return result;
}

fn stage(context: *anyopaque, store: *loam.Store) !void {
    const value = state(context);
    if (store != value.store()) return error.ForeignStore;
    if (value.creation) |*creation| {
        value.content_delta = try creation.stage(store, value.staging(), value.arena, value.call, value.content.?.lease, value.mutation);
    } else if (value.content_delta) |delta| try delta.put(store, value.arena, try store.currentView(value.content.?.lease));
    if (value.participants) |*participants| try participants.stageRows(store, value.arena);
    if (value.graph_delta) |delta| try delta.stage(store);
    if (value.request == .control and value.request.control == .attenuate) {
        const descriptor = try value.config.capabilities.stageAttenuatedControl(value.operation.?, .reachable);
        const endpoint = try store.allocateId();
        const publication = try hosting.publication.stageTarget(store, value.request.control.attenuate.entropy.?, endpoint);
        try storage.stage.endpointAtOperation(value.operation.?, value.arena, endpoint, .{ .descriptor = descriptor, .administration = value.endpoint.administration, .publication = publication }, .reachable);
        const mutation = value.mutation orelse return error.RetryRequired;
        value.request.control.attenuate.proposed = try mutation.call.propose(endpoint);
        try mutation.retainResult(.{ .capability = value.request.control.attenuate.proposed.? });
    } else if (value.request == .control and value.request.control == .revoke) {
        _ = try value.operation.?.stageControlRevocation();
    } else if (value.changed and !value.resource_prepared) _ = try value.config.capabilities.stage(value.operation.?, .reachable);
    if (value.content != null) try stageHistory(value);
    if (value.mutation) |mutation| try mutation.stage(store);
}

/// Journal the call's content and structure through its one staging operation.
/// The first effect opens the batch, and each further changed resource joins it.
fn stageHistory(value: *State) !void {
    const operation = value.staging();
    const bound = (value.dependent_endpoint orelse value.endpoint).content.?.resource;
    const bound_changed = value.content_delta != null or value.graph_delta != null;
    var journaled: ?core.ResourceId = null;
    if (value.resource_prepared) {
        const target = try value.effectTarget(bound);
        _ = try storage.stage.resourceWithContent(operation, if (target.eql(bound)) bound_changed else participantChanged(value, target));
        journaled = target;
        if (bound_changed and !target.eql(bound)) try storage.stage.contentAlso(operation, bound);
    } else if (value.creation != null) {
        // `Creation.stage` staged the append and the bound content's new field.
        try storage.stage.contentAlso(operation, bound);
        journaled = bound;
    } else if (bound_changed) {
        try storage.stage.content(operation, bound);
        journaled = bound;
    } else if (value.participants) |*participants| {
        const first = for (participants.entries) |entry| {
            if (entry.delta != null) break entry.binding.?.resource;
        } else return;
        try storage.stage.content(operation, first);
        journaled = first;
    }
    if (value.participants) |*participants| try participants.stageHistory(operation, journaled);
}

fn participantChanged(value: *State, target: core.ResourceId) bool {
    const participants = value.participants orelse return false;
    for (participants.entries) |entry| if (entry.binding.?.resource.eql(target)) return entry.delta != null;
    return false;
}

fn createdReply(call: *hosting.Call) !driver.Value {
    if (state(call.preparation.?.context).creation) |*creation| return creation.reply();
    return error.NoPreparedChange;
}

fn controlReply(call: *hosting.Call) !driver.Value {
    const value = state(call.preparation.?.context);
    const control = &value.request.control.attenuate;
    const capability = control.proposed orelse return error.NoPreparedChange;
    if (control.reservation == null) control.reservation = try call.attachment.host.reserveDurableCapability(control.entropy.?, capability);
    return .{ .capability = capability };
}

fn confirmControl(context: *anyopaque) void {
    state(context).request.control.attenuate.reservation.?.commit();
}
