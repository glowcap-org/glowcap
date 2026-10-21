//! Small `poll(2)` helpers shared by blocking net residents and readiness
//! backends. Raw OS waits stay behind one net-layer seam, so residents do not
//! each decide which wait errors are transport state.

const std = @import("std");

pub fn wait(fds: []std.posix.pollfd, timeout_ms: i32) !usize {
    return std.posix.poll(fds, timeout_ms);
}
