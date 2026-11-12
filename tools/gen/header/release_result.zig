//! C accessors for the shared release result.
const std = @import("std");
const ReleaseResult = @import("c_abi").ReleaseResult;

pub fn emit(out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    comptime {
        std.debug.assert(ReleaseResult.consumed(-1).raw() == 1);
        std.debug.assert(ReleaseResult.retained(-1).raw() == -1);
        std.debug.assert(ReleaseResult.consumed(0).raw() == 0);
    }
    try out.appendSlice(a,
        \\
        \\/* Fallible release functions return ownership and a result code in one word.
        \\ * Negative results retain ownership and are ordinary error codes.
        \\ * Nonnegative results consume ownership. Positive values negate the error.
        \\ * Check consumption before reusing or retrying any released occurrence. */
        \\static inline int32_t glowcap_release_result_code(int32_t result) {
        \\    return result > 0 ? -result : result;
        \\}
        \\static inline int glowcap_release_result_consumed(int32_t result) {
        \\    return result >= 0;
        \\}
        \\
    );
}
