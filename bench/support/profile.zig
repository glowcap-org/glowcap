//! Phase marks for the `profile-*` steps. A bench brackets each measured
//! phase, so callgrind collects inside phases only and writes one part per
//! phase, named by the phase. A build without valgrind client requests
//! compiles each mark to nothing, so the ordinary bench build pays no cost.
const std = @import("std");
const callgrind = std.valgrind.callgrind;

/// Start collecting. Instrumentation stays off between phases, so setup and
/// teardown run at the uninstrumented speed.
pub fn begin() void {
    callgrind.startInstrumentation();
    callgrind.toggleCollect();
}

/// Stop collecting and write the phase's part, named `phase`.
pub fn end(phase: [*:0]const u8) void {
    callgrind.toggleCollect();
    callgrind.dumpStatsAt(phase);
    callgrind.stopInstrumentation();
}
