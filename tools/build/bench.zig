//! The benchmark table and the ReleaseFast wall-clock tripwire: each row is
//! a public step forwarding `-- <args>`, with a dedicated gate run that
//! never sees user arguments; `perf-check` holds the docs/ladder.md step 2
//! ceilings under `check`.

const std = @import("std");
const root = @import("../../build.zig");
const common = @import("common.zig");

const pancakeExecutable = common.pancakeExecutable;
const layerIndex = root.layerIndex;

pub fn register(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
    fast_lib_mod: *std.Build.Module,
    host_mods: []*std.Build.Module,
    check_step: *std.Build.Step,
) void {
    // ── Benchmarks ───────────────────────────────────────────────────────────
    // Table-driven like the examples: each row builds one executable over
    // `pancake` and registers its public step, whose run forwards
    // `zig build <step> -- <args>`. Each row also gets a dedicated gate run that
    // never sees `b.args`, so `zig build check -- <args>` cannot leak user
    // arguments into the gate; `smoke_on_check` passes `--smoke` on that gate
    // run so the heavier benches prove they still run cheaply, without writing
    // report artifacts into zig-out as a side effect of the gate (the footprint
    // budget itself is gated by test/engine/footprint_budget_test.zig).
    //
    // Optimize mode is per-module: an executable whose root module is
    // ReleaseFast still runs Debug *library* code when it imports the
    // `-Doptimize` graph. Every consumer that claims optimized pancake figures
    // — the `--gate` tripwire runs below and the bench-langs Zig rows — must
    // therefore import this dedicated ReleaseFast graph, never `lib_mod`.

    // The ReleaseFast wall-clock tripwire (docs/ladder.md step 2 owns the
    // ceilings). `gate_on_check` replaces a bench's Debug `--smoke` gate run
    // with a ReleaseFast `--gate` run: it proves "still runs" strictly
    // stronger and holds the wall-clock ceiling while it is at it. The
    // ceilings sit roughly an order of magnitude over the measured figures,
    // so only a structural regression — never machine noise — crosses one.
    const perf_check_step = b.step("perf-check", "Gate ReleaseFast wall-clock cost: warm inbound dispatch and the outbound answered-send path against docs/ladder.md step 2 ceilings, plus the gc-storm linearity ratio (runs under check)");
    check_step.dependOn(perf_check_step);
    const benches = [_]struct {
        step_name: []const u8,
        description: []const u8,
        name: []const u8,
        path: []const u8,
        smoke_on_check: bool = false,
        gate_on_check: bool = false,
        /// The snapshot bench measures the persistent-actor divergence path, so
        /// it imports the persistent-collections leaf module directly, the same
        /// way the test module does; it is not on the public `pancake`
        /// namespace (ADR-0061).
        needs_persistent: bool = false,
    }{
        .{ .step_name = "bench-frame-view", .description = "Run frame/view benchmark", .name = "frame-view-bench", .path = "bench/frame_view_bench.zig" },
        .{ .step_name = "bench-codec", .description = "Run codec/dispatch throughput benchmark", .name = "codec-bench", .path = "bench/codec_bench.zig" },
        .{ .step_name = "bench-dispatch-scaling", .description = "Measure inbound dispatch ns/turn across N peers (cold-cache regime) with p50/p99", .name = "dispatch-scaling-bench", .path = "bench/dispatch_scaling_bench.zig", .gate_on_check = true },
        .{ .step_name = "bench-outbound", .description = "Measure the outbound engine path (send/step/takeOutbound) and the op:gc-answers release storm", .name = "outbound-bench", .path = "bench/outbound_bench.zig", .gate_on_check = true },
        .{ .step_name = "bench-peer-scaling", .description = "Measure per-connection memory footprint and extrapolate to 500k", .name = "peer-scaling-bench", .path = "bench/peer_scaling_bench.zig", .smoke_on_check = true },
        .{ .step_name = "bench-snapshot", .description = "Measure vat snapshot/restore: O(objects), flat in object size, off by default", .name = "snapshot-bench", .path = "bench/snapshot_bench.zig", .smoke_on_check = true, .needs_persistent = true },
    };
    for (benches) |bench| {
        const exe = pancakeExecutable(b, lib_mod, target, optimize, bench.name, bench.path);
        if (bench.needs_persistent) {
            exe.root_module.addImport("persistent", host_mods[layerIndex("persistent")]);
        }
        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        b.step(bench.step_name, bench.description).dependOn(&run.step);

        if (bench.gate_on_check) {
            const gate_exe = pancakeExecutable(b, fast_lib_mod, target, .ReleaseFast, b.fmt("{s}-gate", .{bench.name}), bench.path);
            const gate = b.addRunArtifact(gate_exe);
            gate.addArg("--gate");
            perf_check_step.dependOn(&gate.step);
        } else {
            const gate = b.addRunArtifact(exe);
            if (bench.smoke_on_check) gate.addArg("--smoke");
            check_step.dependOn(&gate.step);
        }
    }
}
