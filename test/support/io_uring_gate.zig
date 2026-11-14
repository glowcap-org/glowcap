//! The one place a Linux test decides what a refused io_uring means.
//!
//! A host kernel or its policy may refuse io_uring, and the backend selector
//! then falls back to epoll and names the reason. A test of the io_uring
//! backend has nothing to run on such a host, so it skips. It never passes
//! silently, and an error the selector does not name as a fallback reason is
//! a failure. Where the environment promises io_uring, setting
//! `GLOWCAP_REQUIRE_IO_URING=1` turns that skip into the refusal itself, so a
//! runner that lost io_uring fails instead of skipping its io_uring tests.

const std = @import("std");
const net = @import("glowcap").net;

/// The variable that makes a refused io_uring a failure instead of a skip.
const require_variable = "GLOWCAP_REQUIRE_IO_URING";

/// The outcome of an io_uring setup failure `err`: `error.SkipZigTest` when
/// the host refused io_uring and nothing requires it, else `err` itself.
pub fn refused(err: anyerror) anyerror {
    const reason = net.linux_completion_white_box.fallbackReasonFor(err) orelse return err;
    if (required()) {
        std.debug.print("{s} is set, but io_uring is unavailable: {s}\n", .{ require_variable, reason.message() });
        return err;
    }
    return error.SkipZigTest;
}

fn required() bool {
    const value = std.testing.environ.getPosix(require_variable) orelse return false;
    return std.mem.eql(u8, value, "1");
}
