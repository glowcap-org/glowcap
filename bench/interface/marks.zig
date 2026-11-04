//! Benchmark-only C bridge to the shared callgrind phase marks. These symbols
//! are linked into the Rust benchmark, never into a shipped glowcap archive.
const profile = @import("profile");

export fn interface_bench_begin() void {
    profile.begin();
}

export fn interface_bench_end(phase: [*:0]const u8) void {
    profile.end(phase);
}
