//! Hosted request kinds name their independent preparation and reply owners.
const storage = @import("loam_access_storage");
const std = @import("std");
const sharing = @import("sharing.zig");
const Mutation = @import("mutation.zig").Mutation;
const ObservationRegistration = @import("observation_registration.zig").Registration;
const Inventory = @import("inventory.zig").Page;
const Inspection = @import("inspection.zig").Inspection;

pub const Request = union(enum) {
    content,
    forward,
    control: @import("control_request.zig").Request,
    derive: *@import("sharing.zig").Sharing,
    observe: *@import("observation_registration.zig").Registration,
    sequence,
    mutation_sequence,
    durable_name,
    describe: *storage.Operation.Description,
    describe_control: *storage.Operation.ControlDescription,
    inspect_access: *@import("inspection.zig").Inspection,
    inspect_fixed: *storage.Operation.Description,
    inventory: *@import("inventory.zig").Page,

    pub fn prepare(value: anytype) !void {
        const call = value.call;
        const config = value.config;
        const verb = value.verb;
        const args = value.args;
        if (std.mem.eql(u8, verb, "mutate")) {
            if (args.len < 2 or args[0] != .integer or args[0].integer < 1 or args[1] != .string) return error.InvalidArguments;
            value.verb = args[1].string;
            value.args = args[2..];
            if (std.mem.eql(u8, value.verb, "mutate") or std.mem.eql(u8, value.verb, "derive") or std.mem.eql(u8, value.verb, "derive-managed") or std.mem.eql(u8, value.verb, "describe-control") or std.mem.eql(u8, value.verb, "mutation-sequence") or std.mem.eql(u8, value.verb, "derivation-sequence") or std.mem.eql(u8, value.verb, "describe-access") or std.mem.eql(u8, value.verb, "durable-name")) return error.InvalidMutation;
            const mutation = try call.arena().create(Mutation);
            mutation.* = try Mutation.init(call, &value.endpoint, @intCast(args[0].integer), value.verb, value.args, value.dependent_object);
            value.mutation = mutation;
        } else if (std.mem.eql(u8, verb, "mutation-sequence")) {
            if (args.len != 0) return error.InvalidArguments;
            value.request = .mutation_sequence;
        }
        if (std.mem.eql(u8, value.verb, "observe") or std.mem.eql(u8, value.verb, "observe-live")) {
            const live = std.mem.eql(u8, value.verb, "observe-live");
            if (value.mutation == null) return error.RetryRequired;
            if (live) {
                if (value.args.len != 1 or value.args[0] != .bytes or value.args[0].bytes.len != 16) return error.InvalidArguments;
            } else if (value.args.len != 0) return error.InvalidArguments;
            if (value.dependent_object != null) return error.NoSuchMethod;
            const registration = try call.arena().create(ObservationRegistration);
            registration.* = .{ .call = call, .config = config, .endpoint = &value.endpoint, .mutation = value.mutation.?, .live = live };
            value.request = .{ .observe = registration };
        }
        if (value.endpoint.content == null and value.request == .content) {
            if (std.mem.eql(u8, value.verb, "inventory")) {
                if (value.mutation != null) return error.InvalidMutation;
                const page = try call.arena().create(Inventory);
                page.* = try Inventory.init(call, args);
                value.request = .{ .inventory = page };
            } else if (std.mem.eql(u8, value.verb, "issue-access")) {
                if (value.mutation != null) return error.InvalidMutation;
                const share = try call.arena().create(sharing.Sharing);
                share.* = try sharing.Sharing.initIssue(call, config, &value.endpoint, args);
                value.request = .{ .derive = share };
            } else if (std.mem.eql(u8, value.verb, "derivation-sequence")) {
                if (args.len != 0) return error.InvalidArguments;
                value.request = .sequence;
            } else if (std.mem.eql(u8, value.verb, "durable-name")) {
                if (value.args.len != 0) return error.InvalidArguments;
                value.request = .durable_name;
            } else if (std.mem.eql(u8, value.verb, "describe-control")) {
                if (value.args.len != 0) return error.InvalidArguments;
                value.request = .{ .describe_control = try call.arena().create(storage.Operation.ControlDescription) };
            } else if (std.mem.eql(u8, value.verb, "inspect-access")) {
                if (value.mutation != null) return error.InvalidMutation;
                if (value.args.len != 0) return error.InvalidArguments;
                value.request = .{ .inspect_access = try call.arena().create(Inspection) };
            } else if (std.mem.eql(u8, value.verb, "inspect-fixed-access")) {
                if (value.mutation != null) return error.InvalidMutation;
                if (value.args.len != 0) return error.InvalidArguments;
                value.request = .{ .inspect_fixed = try call.arena().create(storage.Operation.Description) };
            } else if (std.mem.eql(u8, value.verb, "attenuate-control")) {
                if (config.decode_attenuation == null) return error.NoSuchMethod;
                value.request = .{ .control = .{ .attenuate = .{ .entropy_source = config.entropy } } };
                value.retry = .receipt;
            } else if (std.mem.eql(u8, value.verb, "revoke-control")) {
                if (value.args.len != 0) return error.InvalidArguments;
                value.request = .{ .control = .revoke };
            } else value.request = .{ .control = .{ .edit = null } };
        }
        if (value.endpoint.content != null and value.dependent_object == null and value.mutation == null and value.request == .content) {
            if (std.mem.eql(u8, verb, "derive") or std.mem.eql(u8, verb, "derive-managed")) {
                const share = try call.arena().create(sharing.Sharing);
                share.* = try (if (std.mem.eql(u8, verb, "derive-managed")) sharing.Sharing.initManaged(call, config, &value.endpoint, args) else sharing.Sharing.init(call, config, &value.endpoint, args));
                value.request = .{ .derive = share };
            } else if (std.mem.eql(u8, verb, "describe-access")) {
                if (args.len != 0) return error.InvalidArguments;
                value.request = .{ .describe = try call.arena().create(storage.Operation.Description) };
            } else if (std.mem.eql(u8, verb, "derivation-sequence") or std.mem.eql(u8, verb, "durable-name")) {
                if (args.len != 0) return error.InvalidArguments;
                value.request = if (std.mem.eql(u8, verb, "durable-name")) .durable_name else .sequence;
            }
        }
        value.action_prepared = true;
    }

    pub fn invokes(self: Request) bool {
        return self == .content or self == .control;
    }
};
