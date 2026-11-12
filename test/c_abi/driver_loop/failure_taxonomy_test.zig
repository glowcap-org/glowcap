//! One error reads as one C code through the Host and driver archives. The
//! Host's failure table owns every name it lists, and the driver classifier
//! consults it before its own rows, so each row of
//! `driver_core.HostFailure.named_rows` must project to the same
//! `GLOWCAP_ERR_*` through `libglowcap_host` and `libglowcap_driver`.
//!
//! Dropping the Host lookup from `driver.OperationFailure.classify` makes this
//! name every Host error the driver would report as `GLOWCAP_ERR_IO`, such as
//! `SessionPairExists`.

const std = @import("std");

const cd = @import("c_abi_host");
const cdrv = @import("c_abi_driver");
const glowcap = @import("glowcap");

const HostFailure = glowcap.driver.core.HostFailure;

test "every error the Host names projects to one C code through the Host and driver archives" {
    var disagreements: usize = 0;
    var checked: usize = 0;
    inline for (HostFailure.named_rows) |row| {
        inline for (row.causes) |cause| {
            checked += 1;
            const through_host = cd.testing.error_projection.fromError(cause);
            const through_driver = cdrv.white_box.error_projection.fromError(cause);
            if (through_host != through_driver) {
                std.debug.print("{s}: host {d}, driver {d}\n", .{ @errorName(cause), through_host, through_driver });
                disagreements += 1;
            }
        }
    }
    try std.testing.expect(checked > 0);
    try std.testing.expectEqual(@as(usize, 0), disagreements);
}

test "the Host table owns a session-pair collision on the driver front" {
    try std.testing.expectEqual(
        glowcap.driver.OperationFailure.Kind.invalid_argument,
        glowcap.driver.OperationFailure.classify(error.SessionPairExists),
    );
}
