// The onion listener's pending publish conversation, driven through the
// completion residents on HostRuntime (ADR-0018's pending resident listen):
// the listen admits at once, the loop serves while the control conversation
// runs, and the listener event arrives when the service exists. The ordinary
// test aggregate carries the same file; this step keeps the pending-listen
// evidence directly runnable in the runtime gate.
comptime {
    _ = @import("driver/host_runtime_multiplexed/onion_resident_test.zig");
}
