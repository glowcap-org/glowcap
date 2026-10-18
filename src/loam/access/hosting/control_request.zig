//! Fresh control commands decode only after exact mutation receipt lookup.
const std = @import("std");
const core = @import("loam_access_core");
const storage = @import("loam_access_storage");
const driver = @import("driver_core");
const Service = @import("service.zig").Service;

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

    pub fn prepare(self: *Request, operation: *storage.Operation, service: *Service, arena: std.mem.Allocator, verb: []const u8, args: []const driver.Value) !bool {
        if (self.* == .revoke) return operation.prepareControlRevocation();
        const powers = try operation.controlPowers();
        return switch (self.*) {
            .edit => result: {
                if (service.decode_control_revision) |decode| try operation.expectRevision(try decode(verb, args));
                self.edit = try service.decode_control(service.context, arena, powers, verb, args);
                break :result operation.prepareEditCopying(self.edit.?);
            },
            .attenuate => result: {
                self.attenuate.powers = try service.decode_attenuation.?(service.context, arena, powers, args);
                try operation.prepareAttenuationCopying(self.attenuate.powers.?);
                if (self.attenuate.entropy == null) self.attenuate.entropy = try (self.attenuate.entropy_source orelse return error.EntropyRequired).draw();
                break :result true;
            },
            .revoke => unreachable,
        };
    }

    pub fn deinit(self: *Request) void {
        if (self.* == .attenuate) if (self.attenuate.reservation) |*reservation| reservation.cancel();
    }
};
