//! Test root for mutation fuzzing (`zig build fuzz`).
//!
//! The fuzz entry points live in `test/<layer>/fuzz_test.zig`, one file per
//! layer, and also run under the ordinary suite, where they replay a fixed
//! corpus. Fuzzing needs them as their own build artifact so the driver can
//! run one target at a time.
//!
//! The root is here at `test/` rather than in `test/codec/` for a concrete
//! reason: a test root sets the package boundary, and the seeds are embedded
//! from `test/oracle/corpus/`. Rooted one directory deeper, every one of those
//! `@embedFile` paths reaches outside the package and the build refuses them.

comptime {
    _ = @import("foundation/fuzz_test.zig");
    _ = @import("codec/fuzz_test.zig");
    _ = @import("engine/fuzz_test.zig");
    _ = @import("driver/fuzz_test.zig");
    _ = @import("model/fuzz_test.zig");
    _ = @import("net/fuzz_test.zig");
    _ = @import("session/fuzz_test.zig");
    _ = @import("actors/fuzz_test.zig");
    _ = @import("loam/collections/fuzz_test.zig");
}
