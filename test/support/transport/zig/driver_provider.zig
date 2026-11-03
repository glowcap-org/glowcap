//! C ABI glue shared by the driver-provider seam proofs
//! (`test/driver/transports/iroh_driver_provider`, `interop/webrtc_driver_provider`): the
//! failure report for a driver call, and the cleanup and step helpers that turn
//! a return code into the driver's own `expectOk` verdict.
//!
//! Each proof keeps its own `expectOk`, because each prints a different
//! transport `last_error` beside the driver's, and hands it to `Glue`.
//!
//! Wired in `tools/build` as the `driver_provider` import of those two
//! executables, over the same `c_abi_shared` and `c_abi_driver` module
//! instances the archives share.

const std = @import("std");

const cs = @import("c_abi_shared");
const cdrv = @import("c_abi_driver");

/// Log the primary failure the driver recorded for a non-OK `rc`, and the
/// cleanup failure that followed it.
pub fn reportDriverFailure(label: []const u8, rc: i32, failure: cdrv.GlowcapDriverFailure) void {
    if (rc == cs.GLOWCAP_OK) return;
    const primary = if (failure.primary_name) |name| name[0..failure.primary_name_len] else "missing failure";
    std.log.err("{s}: {s} ({d})", .{ label, primary, rc });
    if (failure.secondary_name) |name| {
        std.log.err("{s}: cleanup: {s} ({d} consequences)", .{
            label,
            name[0..failure.secondary_name_len],
            failure.secondary_count,
        });
    }
}

/// The helpers that judge a return code through one proof's `expectOk`.
pub fn Glue(comptime expectOk: anytype) type {
    return struct {
        /// Log a failed teardown call and keep going, so every release runs.
        pub fn reportCleanup(label: []const u8, rc: i32) void {
            expectOk(rc) catch |err| std.log.err("{s}: {s}", .{ label, @errorName(err) });
        }

        /// Release a driver loop, reporting the driver's failure record and
        /// the cleanup verdict.
        pub fn releaseDriver(label: []const u8, loop: ?*cdrv.GlowcapDriverLoop) void {
            var failure = cdrv.GlowcapDriverFailure.init();
            const rc = cdrv.glowcap_driver_release(loop, &failure);
            reportDriverFailure(label, rc, failure);
            reportCleanup(label, rc);
        }

        /// A driver step that made progress or would block is not a failure.
        pub fn expectStep(rc: i32) !void {
            if (rc == cs.GLOWCAP_OK or rc == cs.GLOWCAP_ERR_WOULD_BLOCK) return;
            return expectOk(rc);
        }
    };
}
