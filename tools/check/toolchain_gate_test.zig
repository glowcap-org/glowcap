//! Test root for the two halves of the toolchain gate.
//!
//! Both are build-time imports, so their `test` blocks run only when something
//! compiles them as a test artifact. `zig build toolchain-check` compiles this
//! root, so neither half can lose its tests by being reached from `build.zig`
//! alone.

comptime {
    _ = @import("toolchain_check.zig");
    _ = @import("toolchain_present.zig");
}
