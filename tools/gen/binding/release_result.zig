//! Release-result accessors for all binding languages.
const std = @import("std");
const Buffer = std.ArrayList(u8);
const ReleaseResult = @import("c_abi").ReleaseResult;

comptime {
    std.debug.assert(ReleaseResult.consumed(-1).raw() == 1);
    std.debug.assert(ReleaseResult.retained(-1).raw() == -1);
    std.debug.assert(ReleaseResult.consumed(0).raw() == 0);
}

pub fn rust(out: *Buffer, a: std.mem.Allocator) !void {
    try out.appendSlice(a, "\npub const fn release_result_code(result: i32) -> i32 {\n" ++
        "\tif result > 0 { -result } else { result }\n}\n" ++
        "pub const fn release_result_consumed(result: i32) -> bool {\n\tresult >= 0\n}\n");
}

pub fn typescript(out: *Buffer, a: std.mem.Allocator) !void {
    try out.appendSlice(a,
        \\
        \\export function releaseResultCode(result: number): number {
        \\    return result > 0 ? -result : result;
        \\}
        \\export function releaseResultConsumed(result: number): boolean {
        \\    return result >= 0;
        \\}
        \\
    );
}

pub fn python(out: *Buffer, a: std.mem.Allocator) !void {
    try out.appendSlice(a,
        \\
        \\
        \\def release_result_code(result: int) -> int:
        \\    return -result if result > 0 else result
        \\
        \\
        \\def release_result_consumed(result: int) -> bool:
        \\    return result >= 0
        \\
    );
}

pub fn racket(out: *Buffer, a: std.mem.Allocator) !void {
    try out.appendSlice(a,
        \\
        \\(provide release-result-code release-result-consumed?)
        \\(define (release-result-code result)
        \\  (if (positive? result) (- result) result))
        \\(define (release-result-consumed? result)
        \\  (>= result 0))
        \\
    );
}
