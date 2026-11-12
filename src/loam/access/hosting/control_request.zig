//! Fresh control commands decode only after exact mutation receipt lookup.
const std = @import("std");
const core = @import("loam_access_core");
const storage = @import("loam_access_storage");
const driver = @import("driver_core");
const Service = @import("service.zig").Service;

/// A control owner refused this intent before publishing effects. Generic
/// promise breaks carry diagnostics, never this management verdict.
pub const Conflict = enum {
    revision,
    operation,

    pub fn reply(self: Conflict) driver.Value {
        const which: []const driver.Value = switch (self) {
            .revision => &.{.{ .symbol = "revision" }},
            .operation => &.{.{ .symbol = "operation" }},
        };
        return .{ .tagged = .{ .tag = "access:control-conflict", .value = which } };
    }
};

/// What preparing a control request settled: whether applying it changes
/// anything, or that it named a revision the control has moved past.
pub const Prepared = union(enum) { changed: bool, conflict };

pub const Request = union(enum) {
    edit: ?core.Control.Edit,
    attenuate: struct {
        powers: ?core.Control.Powers = null,
        proposed: ?driver.Capability = null,
        // Capture the existing registration before waits, just as issuance does.
        entropy_source: ?Service.EntropySource = null,
        entropy: ?driver.Host.DurableSwiss.Entropy = null,
        reservation: ?driver.Host.DurableReservation = null,
    },
    revoke,

    pub fn prepare(self: *Request, operation: *storage.Operation, service: *Service, arena: std.mem.Allocator, verb: []const u8, args: []const driver.Value) !Prepared {
        if (self.* == .revoke) return .{ .changed = try operation.prepareControlRevocation() };
        const powers = try operation.controlPowers();
        return switch (self.*) {
            .edit => result: {
                if (service.decode_control_revision) |decode| {
                    const revision = try decode(verb, args);
                    operation.expectRevision(revision) catch |err| switch (err) {
                        error.RevisionConflict => return .conflict,
                        else => return err,
                    };
                }
                self.edit = try service.decode_control(service.context, arena, powers, verb, args);
                break :result .{ .changed = try operation.prepareEditCopying(self.edit.?) };
            },
            .attenuate => result: {
                self.attenuate.powers = try service.decode_attenuation.?(service.context, arena, powers, args);
                try operation.prepareAttenuationCopying(self.attenuate.powers.?);
                if (self.attenuate.entropy == null) self.attenuate.entropy = try (self.attenuate.entropy_source orelse return error.EntropyRequired).draw();
                break :result .{ .changed = true };
            },
            .revoke => unreachable,
        };
    }

    pub fn deinit(self: *Request) void {
        if (self.* == .attenuate) if (self.attenuate.reservation) |*reservation| reservation.cancel();
    }
};
