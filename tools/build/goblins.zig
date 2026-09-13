//! The live external-authority steps, registered as one subject the root
//! `build.zig` composes: every conversation against a real Spritely Goblins
//! vat (echo, listen, all three handoff roles, the hinted and relayed gives,
//! GC evidence, and the onion meeting over real Tor), the live
//! transport-scale and onion proofs between glowcap peers, and the
//! cross-implementation benches. All of them need an external runtime
//! (racket + goblins, tor, or both), so every step here is a sibling of
//! `check`, never a member. What does ride `check` is each driver's hermetic
//! compile, so an engine or model API change cannot silently rot a driver
//! nothing ran.

const std = @import("std");
const common = @import("common.zig");
const execution = @import("execution.zig");

/// What the family draws from the root build graph. `interop_harness_mod`
/// stays root-minted because the iroh and WebRTC drivers import the same
/// instance, and `fast_lib_mod` is the root's ReleaseFast module graph for
/// the measured bench rows.
pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// The public `glowcap` module.
    lib_mod: *std.Build.Module,
    fast_lib_mod: *std.Build.Module,
    interop_harness_mod: *std.Build.Module,
    check_step: *std.Build.Step,
    pin_port: ?u16,
};

/// The step handles the root's `check-external` aggregate wires: the core
/// Goblins protocol baseline, every handoff role, the relayed give, and the
/// hinted-locator give.
pub const Registered = struct {
    interop_step: *std.Build.Step,
    handoff_step: *std.Build.Step,
    gift_step: *std.Build.Step,
    gift_hints_step: *std.Build.Step,
    relayed_give_step: *std.Build.Step,
    listen_recipient_step: *std.Build.Step,
    exporter_step: *std.Build.Step,
};

/// One live interop driver: a glowcap executable over the shared interop
/// harness, run from the repository root with side effects, hermetically
/// compiled under `check`, and forwarding `-Dport` where the driver takes it.
const LiveDriver = struct {
    exe_name: []const u8,
    source: []const u8,
    step_name: []const u8,
    description: []const u8,
    pin_port: bool = true,
    posture: execution.Posture,
};

const Driven = struct {
    exe: *std.Build.Step.Compile,
    step: *std.Build.Step,
};

fn liveDriver(ctx: Context, row: LiveDriver) Driven {
    const b = ctx.b;
    const exe = common.glowcapExecutable(b, ctx.lib_mod, ctx.target, ctx.optimize, row.exe_name, row.source);
    exe.root_module.addImport("interop_harness", ctx.interop_harness_mod);
    const run = execution.addArtifact(b, row.posture, exe);
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    // Running the live conversations needs the external runtime, but
    // *compiling* their drivers is hermetic: the check gate compiles them so
    // an engine or model API change cannot silently rot a driver nothing ran.
    ctx.check_step.dependOn(&exe.step);
    if (row.pin_port) {
        if (ctx.pin_port) |p| run.addArg(b.fmt("--port={d}", .{p}));
    }
    const step = b.step(row.step_name, row.description);
    step.dependOn(&run.step);
    return .{ .exe = exe, .step = step };
}

pub fn register(ctx: Context) Registered {
    const b = ctx.b;
    const lib_mod = ctx.lib_mod;
    const check_step = ctx.check_step;

    // Live interop proof against a real Spritely Goblins vat: a glowcap peer
    // dials the conformance Goblins host, completes the keyed op:start-session
    // handshake, and bootstrap-fetches its echo cap. Needs `racket` + the
    // `goblins` collection on PATH (like the binding dogfoods). The driver
    // spawns and tears down the Goblins vat itself.
    const goblins_interop = liveDriver(ctx, .{ .exe_name = "glowcap-goblins-interop", .source = "interop/goblins_interop/driver.zig", .step_name = "goblins-interop", .description = "Live OCapN conversation vs a real Goblins vat, both directions (needs racket + goblins)", .posture = .{ .deterministic = 30 } });

    // Live TCP scale over the loop-fed host bridge (ADR-0076): one completion
    // loop thread serves a full byte-fed node through `driver.Bridge`,
    // many concurrent BlockingSession clients across two waves. Binds real
    // loopback sockets at scale, port-exclusive like every live step.
    _ = liveDriver(ctx, .{ .exe_name = "glowcap-tcp-loop", .source = "interop/tcp_loop/driver.zig", .step_name = "tcp-loop", .description = "Live TCP scale: many concurrent connections served from one loop thread through the Host bridge (ADR-0076)", .pin_port = false, .posture = .{ .deterministic = 30 } });

    // Live Tor (ADR-0108): two glowcap peers hold an OCapN conversation over a
    // real hidden service. The driver starts its own Tor, so this needs `tor`
    // on PATH and outbound network access.
    _ = liveDriver(ctx, .{ .exe_name = "glowcap-onion-interop", .source = "interop/onion_interop/driver.zig", .step_name = "onion-interop", .description = "Live Tor: two glowcap peers hold an OCapN conversation over a real onion service (needs tor + network)", .pin_port = false, .posture = .real_internet });

    // The same transport with a foreign partner: `onion` is the netlayer the
    // OCapN draft standardizes and the one upstream Goblins ships, so this is
    // where the two implementations meet over a transport neither wrote for the
    // other. Needs racket + goblins as well as tor and network access.
    _ = liveDriver(ctx, .{ .exe_name = "glowcap-goblins-onion", .source = "interop/goblins_interop/onion_driver.zig", .step_name = "goblins-onion", .description = "Live Goblins over Tor: a real Goblins vat and a glowcap peer hold OCapN sessions over hidden service circuits, both directions (needs tor + network + racket + goblins)", .pin_port = false, .posture = .real_internet });

    // Live three-party handoff, glowcap as recipient (needs racket + goblins).
    // It runs two Goblins listeners (alice, bob), so `-Dport=N` pins N and N+1.
    const goblins_handoff = liveDriver(ctx, .{ .exe_name = "glowcap-goblins-handoff", .source = "interop/goblins_interop/handoff_driver.zig", .step_name = "goblins-handoff", .description = "Live three-party handoff vs Goblins, glowcap as recipient (needs racket + goblins)", .posture = .{ .deterministic = 30 } });

    // Live three-party handoff, glowcap as gifter (needs racket + goblins).
    // Bob listens on N; Carol binds N+1. `-Dport=N` pins the pair.
    const goblins_gift = liveDriver(ctx, .{ .exe_name = "glowcap-goblins-gift", .source = "interop/goblins_interop/gift_driver.zig", .step_name = "goblins-gift", .description = "Live three-party handoff vs Goblins, glowcap as gifter (needs racket + goblins)", .posture = .{ .deterministic = 30 } });

    // The exporter is its own process, like every Goblins peer here: one
    // completion loop per process, and the driver's own loop is the gifter's.
    const native_pair_exporter_exe = common.glowcapExecutable(b, lib_mod, ctx.target, ctx.optimize, "glowcap-native-pair-exporter", "interop/goblins_interop/native_pair_exporter.zig");
    native_pair_exporter_exe.root_module.addImport("interop_harness", ctx.interop_harness_mod);
    b.installArtifact(native_pair_exporter_exe);
    check_step.dependOn(&native_pair_exporter_exe.step);
    const goblins_native_pair_gift_exe = common.glowcapExecutable(b, lib_mod, ctx.target, ctx.optimize, "glowcap-goblins-native-pair-gift", "interop/goblins_interop/native_pair_gift_driver.zig");
    goblins_native_pair_gift_exe.root_module.addImport("interop_harness", ctx.interop_harness_mod);
    check_step.dependOn(&goblins_native_pair_gift_exe.step);
    const run_goblins_native_pair_gift = execution.addArtifact(b, .{ .deterministic = 30 }, goblins_native_pair_gift_exe);
    run_goblins_native_pair_gift.step.dependOn(b.getInstallStep());
    run_goblins_native_pair_gift.setCwd(b.path("."));
    run_goblins_native_pair_gift.has_side_effects = true;
    const goblins_native_pair_gift_step = b.step("goblins-native-pair-gift", "Live three-party handoff with two glowcap vats and one Goblins vat: the glowcap pair holds a glowcap-next Cap'n Proto session while both Goblins sessions settle on the v1.0 Syrup baseline, and the give crosses that split (needs racket + goblins)");
    goblins_native_pair_gift_step.dependOn(&run_goblins_native_pair_gift.step);

    // The same topology with an opaque route hint. Both live Goblins peers
    // must decode and re-encode the mapping-shaped locator byte-exactly.
    const run_goblins_gift_hints = execution.addArtifact(b, .{ .deterministic = 30 }, goblins_gift.exe);
    run_goblins_gift_hints.setCwd(b.path("."));
    run_goblins_gift_hints.has_side_effects = true;
    run_goblins_gift_hints.addArg("--hinted-exporter");
    // Its own fixed default so the plain and hinted runs can share an
    // aggregate without racing one Bob port; `--port` is last-one-wins, so a
    // `-Dport` pin still overrides.
    run_goblins_gift_hints.addArg("--port=22170");
    if (ctx.pin_port) |p| run_goblins_gift_hints.addArg(b.fmt("--port={d}", .{p}));
    const goblins_gift_hints_step = b.step("goblins-gift-hints", "Live hinted-locator handoff vs Goblins: an opaque route hint survives decode, re-encode, and signature verification (needs racket + goblins)");
    goblins_gift_hints_step.dependOn(&run_goblins_gift_hints.step);

    // A relayed give read by live Goblins: glowcap introduces a third party to
    // a promise it does not own, and the give reaches that party in a listener
    // fire rather than in an answer it asked for. Bob listens on N; Carol binds
    // N+1. `-Dport=N` pins the pair.
    const goblins_relayed_give = liveDriver(ctx, .{ .exe_name = "glowcap-goblins-relayed-give", .source = "interop/goblins_interop/relayed_give_driver.zig", .step_name = "goblins-relayed-give", .description = "Live relayed give vs Goblins: a give reaches a real Goblins recipient in a listener fire (needs racket + goblins)", .posture = .{ .deterministic = 30 } });

    // The reciprocal listener proof: glowcap receives a Goblins-owned pending
    // promise, queues Session.listenTo before asking Goblins to settle it, and
    // calls the nested capability carried by the fulfillment.
    const goblins_listen_recipient = liveDriver(ctx, .{ .exe_name = "glowcap-goblins-listen-recipient", .source = "interop/goblins_interop/listen_recipient_driver.zig", .step_name = "goblins-listen-recipient", .description = "Live Goblins promise recipient: owning Session.listenTo observes a later settlement containing a callable capability (needs racket + goblins)", .posture = .{ .deterministic = 30 } });

    // The third handoff role against live Goblins: glowcap as the *exporter*,
    // answering deposit-gift from a Goblins gifter and withdraw-gift from a
    // Goblins recipient over two different sessions of one host.
    const goblins_exporter = liveDriver(ctx, .{ .exe_name = "glowcap-goblins-exporter", .source = "interop/goblins_interop/exporter_driver.zig", .step_name = "goblins-exporter", .description = "Live three-party handoff vs Goblins, glowcap as exporter (needs racket + goblins)", .posture = .{ .deterministic = 30 } });

    // Live distributed-GC evidence vs Goblins: introduce a near export into the
    // suite echo and observe inbound op:gc-exports (needs racket + goblins).
    _ = liveDriver(ctx, .{ .exe_name = "glowcap-goblins-gc", .source = "interop/goblins_interop/gc_driver.zig", .step_name = "goblins-gc", .description = "Live Goblins GC in both directions, including remote reclamation after capability and answer release with the owning Session open (needs racket + goblins)", .posture = .{ .deterministic = 30 } });

    // Per-binding Goblins clients (interop / handoff / gift) register with the
    // root's shared `binding_families` table — same emitter as the iroh and
    // keyed-tcp families.

    // Cross-implementation benchmark: one shared Racket application run on
    // glowcap's Racket binding and on Spritely Goblins, comparing latency,
    // throughput, connection setup, and server memory. It needs `racket` + the
    // `goblins` collection on PATH. The orchestrator spawns and tears down
    // both servers itself. Forward `-- <args>` (e.g. `--smoke`,
    // `--suite=echo`) to the orchestrator; `-Dport=N` pins the base port.
    const run_bench_goblins = common.addInstalledSystemRun(b, .benchmark, &.{ "racket", "-y", "bench/goblins/bench.rkt" });
    if (ctx.pin_port) |p| run_bench_goblins.addArg(b.fmt("--port={d}", .{p}));
    run_bench_goblins.addPassthruArgs();
    b.step("bench-goblins", "Cross-implementation benchmark: glowcap's Racket binding vs Spritely Goblins (needs racket + goblins)")
        .dependOn(&run_bench_goblins.step);

    // Per-language consumer-cost benchmark: one fixed native Zig taskboard host,
    // the client language swapped per row (Zig, Rust, Deno, Python, the Racket
    // binding, and Goblins as the reference CapTP peer). It answers "what does a
    // consumer in language X pay to run this app over the same glowcap host and
    // wire" — NOT a language leaderboard, and distinct from the substrate
    // comparison above. Never gated; the orchestrator spawns and tears down a
    // fresh host per client row. The host and Zig client are always built (and
    // run in whatever `-Doptimize` mode is passed, like the other benches);
    // other rows join when their runtimes are on PATH. Forward `-- <args>`
    // (e.g. `--smoke`, `--client=zig`); `-Dport=N` pins the host port. The
    // orchestrator is itself a native glowcap executable — no Racket on the
    // driving path — so the Zig-only smoke runs with nothing else installed.
    // Racket joins only as two client rows (the binding and the Goblins
    // reference), each skipped with a note when its runtime is absent.
    //
    // The host and Zig client are pinned to ReleaseFast regardless of
    // `-Doptimize`, because the Rust row always builds `--release` and the
    // interpreters always run optimized: a fair cross-language comparison needs
    // the Zig rows optimized too, so a plain `zig build bench-langs` is honest
    // without remembering `-Doptimize=ReleaseFast`. The pin only holds through
    // `fast_lib_mod`: optimize mode is per-module, so importing `lib_mod` here
    // would run Debug glowcap under a ReleaseFast main. The orchestrator is
    // glue — its own speed never enters a measured number — so it tracks
    // `-Doptimize`.
    const langs_host_exe = common.glowcapExecutable(b, ctx.fast_lib_mod, ctx.target, .ReleaseFast, "glowcap-langs-host", "bench/langs/host.zig");
    const langs_zig_client_exe = common.glowcapExecutable(b, ctx.fast_lib_mod, ctx.target, .ReleaseFast, "glowcap-langs-client-zig", "bench/langs/clients/zig_bench.zig");
    const run_bench_langs = common.addGlowcapRun(b, .benchmark, lib_mod, ctx.target, ctx.optimize, "glowcap-langs-orchestrator", "bench/langs/orchestrator.zig");
    // The Deno, Python, and Rust rows link the installed C ABI archives, so the
    // run needs the install step the way the binding dogfoods do.
    run_bench_langs.step.dependOn(b.getInstallStep());
    run_bench_langs.addArtifactArg(langs_host_exe);
    run_bench_langs.addArtifactArg(langs_zig_client_exe);
    if (ctx.pin_port) |p| run_bench_langs.addArg(b.fmt("--port={d}", .{p}));
    run_bench_langs.addPassthruArgs();
    b.step("bench-langs", "Per-language consumer-cost benchmark: fixed Zig host, swap client (Zig always; joins deno/python3/cargo/racket+goblins when present)")
        .dependOn(&run_bench_langs.step);

    // Every language client otherwise compiles only under the opt-in benchmark,
    // where a missing runtime looks like a routine skip. Compile all of them
    // under `check`; the native host/client remain compile-only, and each binding
    // client goes through its standard compiler without running the benchmark.
    check_step.dependOn(&langs_host_exe.step);
    check_step.dependOn(&langs_zig_client_exe.step);

    const rust_langs_check = execution.addSystemCommand(b, .build_tool, &.{
        "cargo",
        "check",
        "--manifest-path",
        "bench/langs/clients/rust_bench/Cargo.toml",
    });
    rust_langs_check.step.dependOn(b.getInstallStep());
    check_step.dependOn(&rust_langs_check.step);

    const deno_langs_check = execution.addSystemCommand(b, .build_tool, &.{
        "deno",
        "check",
        "bench/langs/clients/deno_bench.ts",
    });
    check_step.dependOn(&deno_langs_check.step);

    const python_langs_check = execution.addSystemCommand(b, .build_tool, &.{
        "python3",
        "-m",
        "py_compile",
        "bench/langs/clients/python_bench.py",
    });
    check_step.dependOn(&python_langs_check.step);

    const racket_langs_check = execution.addSystemCommand(b, .build_tool, &.{
        "raco",
        "make",
        "bench/langs/clients/racket_bench.rkt",
        "bench/langs/clients/goblins_bench.rkt",
    });
    racket_langs_check.step.dependOn(b.getInstallStep());
    racket_langs_check.has_side_effects = true;
    check_step.dependOn(&racket_langs_check.step);

    // Regenerate the performance page's charts and tables from live ReleaseFast
    // runs of every bench (codec, peer-scaling, frame-view) plus the Goblins
    // comparison, splicing the results into site/content/performance.smd between
    // `<!-- bench:<name> -->` markers, the gen-header pattern, applied to docs.
    // Needs `racket` + `goblins`, and bench numbers are a dated snapshot of one
    // machine, not an invariant.
    const run_site_report = common.addInstalledSystemRun(b, .benchmark, &.{ "racket", "-y", "bench/site_report.rkt" });
    b.step("bench-site-report", "Regenerate the performance page's benchmark reports from live runs (needs racket + goblins)")
        .dependOn(&run_site_report.step);

    return .{
        .interop_step = goblins_interop.step,
        .handoff_step = goblins_handoff.step,
        .gift_step = goblins_gift.step,
        .gift_hints_step = goblins_gift_hints_step,
        .relayed_give_step = goblins_relayed_give.step,
        .listen_recipient_step = goblins_listen_recipient.step,
        .exporter_step = goblins_exporter.step,
    };
}
