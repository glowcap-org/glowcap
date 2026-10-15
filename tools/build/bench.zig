//! The benchmark table and the ReleaseFast wall-clock tripwire. Each row is a
//! public step forwarding `-- <args>`, plus a dedicated check run that never
//! sees user arguments. `perf-check` holds the ReleaseFast ceilings under
//! `check`.

const std = @import("std");
const root = @import("../../build.zig");
const common = @import("common.zig");
const execution = @import("execution.zig");
const profile_build = @import("profile.zig");

const glowcapExecutable = common.glowcapExecutable;
const layerIndex = root.layerIndex;

pub fn register(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
    fast_lib_mod: *std.Build.Module,
    host_mods: []*std.Build.Module,
    check_step: *std.Build.Step,
    runtime_gate: *execution.RuntimeGate,
    profiles: profile_build.Profiles,
) void {
    // ── Benchmarks ───────────────────────────────────────────────────────────
    // Table-driven like the examples: each row builds one executable over
    // `glowcap` and registers its public step, whose run forwards
    // `zig build <step> -- <args>`. Each row also gets a dedicated gate run that
    // takes no passthrough args; `smoke_on_check` passes `--smoke` there so the
    // heavier benches prove they still run cheaply, without report artifacts
    // under zig-out. `live_smoke_on_runtime` adds the smallest real two-process
    // socket barrier to `runtime-check` so child orchestration cannot silently
    // rot or overlap another process family.
    //
    // Optimize mode is per-module: an executable whose root module is
    // ReleaseFast still runs Debug *library* code when it imports the
    // `-Doptimize` graph. Every consumer that claims optimized glowcap figures
    // (the `--gate` tripwire runs below and the bench-langs Zig rows) must
    // therefore import this dedicated ReleaseFast graph, never `lib_mod`.

    // The ReleaseFast wall-clock tripwire. Each ceiling is a constant at the
    // top of its bench file. `gate_on_check` replaces a bench's Debug `--smoke` gate run
    // with a ReleaseFast `--gate` run: it proves "still runs" strictly
    // stronger and holds the wall-clock ceiling while it is at it. The
    // ceilings sit roughly an order of magnitude over the measured figures,
    // so only a structural regression, never machine noise, crosses one.
    const perf_check_step = b.step("perf-check", "Gate ReleaseFast wall-clock cost: warm inbound dispatch and the outbound answered-send path against the ceilings in the bench files, plus the gc-storm linearity ratio (runs under check)");
    check_step.dependOn(perf_check_step);
    const benches = [_]struct {
        step_name: []const u8,
        description: []const u8,
        name: []const u8,
        path: []const u8,
        smoke_on_check: bool = false,
        live_smoke_on_runtime: bool = false,
        gate_on_check: bool = false,
        /// A `profile-*` step for the bench's marked phases under callgrind.
        profile_step: ?[]const u8 = null,
        /// The snapshot bench measures the persistent-actor divergence path, so
        /// it imports the dependency-free Loam collections leaf directly,
        /// matching the map's tests without linking storage or OS backends.
        needs_persistent: bool = false,
    }{
        .{ .step_name = "bench-floors", .description = "Measure each primitive alone: Ed25519, the Noise XK handshake and records, a frame copy, and a loopback round trip", .name = "floors-bench", .path = "bench/floors_bench.zig", .smoke_on_check = true },
        .{ .step_name = "bench-frame-view", .description = "Run frame/view benchmark", .name = "frame-view-bench", .path = "bench/frame_view_bench.zig" },
        .{ .step_name = "bench-host-locator", .description = "Measure warmed Host advertised-route allocation traffic", .name = "host-locator-bench", .path = "bench/host_locator_bench.zig" },
        .{ .step_name = "bench-uri", .description = "Measure locator and sturdyref URI rendering time and allocation traffic", .name = "uri-bench", .path = "bench/uri_bench.zig" },
        .{ .step_name = "bench-set-uniqueness", .description = "Measure borrowed set validation and collision scratch on both codecs", .name = "set-uniqueness-bench", .path = "bench/set_uniqueness_bench.zig" },
        .{ .step_name = "bench-codec", .description = "Run codec/dispatch throughput benchmark", .name = "codec-bench", .path = "bench/codec_bench.zig" },
        .{ .step_name = "bench-dispatch-scaling", .description = "Measure inbound dispatch ns/turn across N peers (cold-cache regime) with p50/p99", .name = "dispatch-scaling-bench", .path = "bench/dispatch_scaling_bench.zig", .gate_on_check = true, .profile_step = "profile-dispatch-scaling" },
        .{ .step_name = "bench-outbound", .description = "Measure the outbound engine path (send/step/takeOutbound) and the op:gc-answers release storm", .name = "outbound-bench", .path = "bench/outbound_bench.zig", .gate_on_check = true, .profile_step = "profile-outbound" },
        .{ .step_name = "bench-peer-scaling", .description = "Measure per-session memory and live authenticated socket scale", .name = "peer-scaling-bench", .path = "bench/peer_scaling_bench.zig", .smoke_on_check = true, .live_smoke_on_runtime = true },
        .{ .step_name = "bench-snapshot", .description = "Measure vat snapshot/restore: O(objects), flat in object size, off by default", .name = "snapshot-bench", .path = "bench/snapshot_bench.zig", .smoke_on_check = true, .needs_persistent = true },
    };
    // Cap'n Proto RPC echo benches (Rust capnp-rpc and the C++ reference
    // library) for the comparison table on the benchmarks page; the script
    // builds and runs both outside the Zig graph.
    const run_bench_capnp = common.addInstalledSystemRun(b, .benchmark, &.{ "sh", "bench/capnp/run.sh" });
    run_bench_capnp.addPassthruArgs();
    b.step("bench-capnp", "Cap'n Proto RPC echo round trip in Rust and C++ for the comparison table on the benchmarks page (needs capnp, cargo, g++)")
        .dependOn(&run_bench_capnp.step);

    for (benches) |bench| {
        const exe = glowcapExecutable(b, lib_mod, target, optimize, bench.name, bench.path);
        if (bench.needs_persistent) {
            exe.root_module.addImport("loam_collections", host_mods[layerIndex("loam_collections")]);
        }
        const run = execution.addArtifact(b, .benchmark, exe);
        run.addPassthruArgs();
        b.step(bench.step_name, bench.description).dependOn(&run.step);

        if (bench.profile_step) |step_name| {
            const module = b.createModule(profiles.moduleOptions(b, bench.path));
            module.addImport("glowcap", profiles.module("glowcap"));
            const profiled = b.addExecutable(.{ .name = b.fmt("{s}-profile", .{bench.name}), .root_module = module });
            b.step(step_name, b.fmt("Profile {s} under callgrind: self cost per file and function for each marked phase", .{bench.step_name})).dependOn(profile_build.addRun(b, profiles, profiled));
        }

        if (bench.gate_on_check) {
            const gate_exe = glowcapExecutable(b, fast_lib_mod, target, .ReleaseFast, b.fmt("{s}-gate", .{bench.name}), bench.path);
            const gate = execution.addArtifact(b, .{ .deterministic = 30 }, gate_exe);
            gate.addArg("--gate");
            perf_check_step.dependOn(&gate.step);
        } else {
            const gate = execution.addArtifact(b, .{ .deterministic = 30 }, exe);
            if (bench.smoke_on_check) gate.addArg("--smoke");
            check_step.dependOn(&gate.step);
            if (bench.live_smoke_on_runtime) {
                const live_gate = execution.addArtifact(b, .{ .deterministic = 30 }, exe);
                live_gate.addArgs(&.{ "--smoke", "--live", "--live-max=8" });
                runtime_gate.add(&live_gate.step);
            }
        }
    }
}
