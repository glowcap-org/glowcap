const std = @import("std");
const arch_check = @import("tools/arch_check.zig");
const meta_check = @import("tools/meta_check.zig");

/// C ABI version (keep in lockstep with `PANCAKE_VERSION_*` in `include/pancake.h`
/// and `src/c_abi/mod.zig`). The dynamic library's soname tracks `major`.
const abi_version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // Position-independent so the static `libpancake.a` links cleanly into a
        // PIE consumer (the Rust C ABI dogfood links `static=pancake` into a
        // position-independent test binary; without this, the archive's
        // R_X86_64_32S relocations are rejected at link time). The shared library
        // requires PIC regardless, so both artifacts share one PIC module.
        .pic = true,
    });
    const static_lib = b.addLibrary(.{
        .name = "pancake",
        .linkage = .static,
        .root_module = lib_mod,
    });
    b.installArtifact(static_lib);

    const shared_lib = b.addLibrary(.{
        .name = "pancake",
        .linkage = .dynamic,
        .root_module = lib_mod,
        // Stamps the soname (`libpancake.so.0`) so a distro can express the ABI
        // contract; `pancake_abi_version` reports the same triple at runtime.
        .version = abi_version,
    });
    b.installArtifact(shared_lib);

    const install_header = b.addInstallHeaderFile(b.path("include/pancake.h"), "pancake.h");
    b.getInstallStep().dependOn(&install_header.step);

    // Serena's SolidLSP ZLS adapter currently hard-codes build-on-save args to
    // `zig build build`; keep that editor-only alias pointed at the normal
    // install step. The project correctness gate remains `zig build check`.
    const build_step = b.step("build", "Build and install libpancake artifacts");
    build_step.dependOn(b.getInstallStep());

    // `include/pancake.h` is generated from `src/c_abi/mod.zig` (reflected
    // layouts, constant values, and function signatures): the Zig source is the
    // single source of truth. `zig build gen-header` rewrites it; `check` gates
    // that the committed header is not stale.
    const gen_write_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_header_write.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_write_mod.addImport("pancake", lib_mod);
    const gen_write_exe = b.addExecutable(.{ .name = "gen-header-write", .root_module = gen_write_mod });
    const gen_header_write = b.addRunArtifact(gen_write_exe);
    gen_header_write.setCwd(b.path("."));
    gen_header_write.has_side_effects = true;
    const gen_header_step = b.step("gen-header", "Regenerate include/pancake.h from src/c_abi");
    gen_header_step.dependOn(&gen_header_write.step);

    const gen_check_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_header_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_check_mod.addImport("pancake", lib_mod);
    const gen_check_exe = b.addExecutable(.{ .name = "gen-header-check", .root_module = gen_check_mod });
    const header_check = b.addRunArtifact(gen_check_exe);
    header_check.setCwd(b.path("."));

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("test/all_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addImport("pancake", lib_mod);
    // The header-parity test `@cImport`s `pancake.h` to prove the hand-written C
    // header agrees with the Zig `c_abi` source (sizes, offsets, constants), so
    // the two can never silently drift.
    tests_mod.addIncludePath(b.path("include"));
    tests_mod.link_libc = true;
    const tests = b.addTest(.{
        .root_module = tests_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);

    const oracle_tests_mod = b.createModule(.{
        .root_source_file = b.path("test/oracle_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    oracle_tests_mod.addImport("pancake", lib_mod);
    const oracle_tests = b.addTest(.{
        .root_module = oracle_tests_mod,
    });
    const run_oracle_tests = b.addRunArtifact(oracle_tests);
    const oracle_check_step = b.step("oracle-check", "Run protocol and Goblins fixture oracle checks");
    oracle_check_step.dependOn(&run_oracle_tests.step);

    const examples_step = b.step("examples", "Build and run examples");

    // Zig example programs, run in array order. `frame_view` stays first (the
    // library-mechanics walkthrough); the numbered chapters are runnable CapTP
    // walkthroughs whose narrative lives in their `//!` headers, so the prose
    // and the API calls can't drift (each is built and run under `check`).
    const zig_examples = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "pancake-zig-frame-view", .path = "examples/zig/frame_view.zig" },
        .{ .name = "pancake-ex-01-call-a-remote-method", .path = "examples/zig/01_call_a_remote_method.zig" },
        .{ .name = "pancake-ex-02-look-up-by-name", .path = "examples/zig/02_look_up_by_name.zig" },
        .{ .name = "pancake-ex-03-actor-far-send", .path = "examples/zig/03_actor_far_send.zig" },
    };
    for (zig_examples) |ex| {
        const mod = b.createModule(.{
            .root_source_file = b.path(ex.path),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("pancake", lib_mod);
        const exe = b.addExecutable(.{ .name = ex.name, .root_module = mod });
        const run = b.addRunArtifact(exe);
        examples_step.dependOn(&run.step);
    }

    const c_example_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    c_example_mod.addCSourceFile(.{
        .file = b.path("examples/c/frame_view.c"),
    });
    c_example_mod.addIncludePath(b.path("include"));
    c_example_mod.linkLibrary(static_lib);
    c_example_mod.link_libc = true;
    const c_frame_view_example = b.addExecutable(.{
        .name = "pancake-c-frame-view",
        .root_module = c_example_mod,
    });
    const run_c_frame_view_example = b.addRunArtifact(c_frame_view_example);
    examples_step.dependOn(&run_c_frame_view_example.step);

    const c_context_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    c_context_mod.addCSourceFile(.{
        .file = b.path("examples/c/context_alloc.c"),
    });
    c_context_mod.addIncludePath(b.path("include"));
    c_context_mod.linkLibrary(static_lib);
    c_context_mod.link_libc = true;
    const c_context_example = b.addExecutable(.{
        .name = "pancake-c-context-alloc",
        .root_module = c_context_mod,
    });
    const run_c_context_example = b.addRunArtifact(c_context_example);
    examples_step.dependOn(&run_c_context_example.step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/frame_view_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("pancake", lib_mod);
    const frame_view_bench = b.addExecutable(.{
        .name = "frame-view-bench",
        .root_module = bench_mod,
    });

    const run_frame_view_bench = b.addRunArtifact(frame_view_bench);
    if (b.args) |args| {
        run_frame_view_bench.addArgs(args);
    }

    const bench_step = b.step("bench-frame-view", "Run frame/view benchmark");
    bench_step.dependOn(&run_frame_view_bench.step);

    const codec_bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/codec_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    codec_bench_mod.addImport("pancake", lib_mod);
    const codec_bench = b.addExecutable(.{
        .name = "codec-bench",
        .root_module = codec_bench_mod,
    });
    const run_codec_bench = b.addRunArtifact(codec_bench);
    if (b.args) |args| {
        run_codec_bench.addArgs(args);
    }
    const codec_bench_step = b.step("bench-codec", "Run codec/dispatch throughput benchmark");
    codec_bench_step.dependOn(&run_codec_bench.step);

    const rust_dogfood = b.addSystemCommand(&.{
        "cargo",
        "test",
        "--manifest-path",
        "bindings/rust/Cargo.toml",
        // Exercise the opt-in tokio async layer alongside the sync surface.
        "--features",
        "async",
    });
    rust_dogfood.step.dependOn(b.getInstallStep());
    const rust_dogfood_step = b.step("rust-dogfood", "Run Rust C ABI dogfood tests against libpancake");
    rust_dogfood_step.dependOn(&rust_dogfood.step);

    // Per-language dogfood of the Zig libpancake C ABI. Each consumer loads the
    // installed shared library and drives an OCapN round-trip through its
    // idiomatic API over the whole C ABI — allocation context, owned-frame feed,
    // and typed events included (see bindings/README.md). Requires the matching
    // runtime on PATH (deno / python3 / racket), provided by this repo's devcontainer.
    const deno_dogfood = b.addSystemCommand(&.{
        "deno", "run", "--allow-ffi", "--allow-read", "--allow-net", "bindings/deno/zig_smoke.ts",
    });
    deno_dogfood.step.dependOn(b.getInstallStep());

    const python_dogfood = b.addSystemCommand(&.{ "python3", "bindings/python/zig_smoke.py" });
    python_dogfood.step.dependOn(b.getInstallStep());

    const racket_dogfood = b.addSystemCommand(&.{ "racket", "bindings/racket/zig-smoke.rkt" });
    racket_dogfood.step.dependOn(b.getInstallStep());

    const bindings_step = b.step("bindings", "Run per-language dogfood of the C ABI (rust, deno, python, racket)");
    bindings_step.dependOn(&rust_dogfood.step);
    bindings_step.dependOn(&deno_dogfood.step);
    bindings_step.dependOn(&python_dogfood.step);
    bindings_step.dependOn(&racket_dogfood.step);

    // Live interop proof against a real Spritely Goblins vat: a pancake peer
    // dials the conformance Goblins host, completes the keyed op:start-session
    // handshake, and bootstrap-fetches its echo cap. Needs `racket` + the
    // `goblins` collection on PATH (like the binding dogfoods), so it is a
    // sibling of `check`, not part of the hermetic gate. The driver spawns and
    // tears down the Goblins vat itself.
    const goblins_interop_mod = b.createModule(.{
        .root_source_file = b.path("conformance/goblins_interop/driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    goblins_interop_mod.addImport("pancake", lib_mod);
    const goblins_interop_exe = b.addExecutable(.{
        .name = "pancake-goblins-interop",
        .root_module = goblins_interop_mod,
    });
    const run_goblins_interop = b.addRunArtifact(goblins_interop_exe);
    run_goblins_interop.setCwd(b.path("."));
    run_goblins_interop.has_side_effects = true;
    const goblins_interop_step = b.step("goblins-interop", "Live OCapN conversation against a real Goblins vat (needs racket + goblins)");
    goblins_interop_step.dependOn(&run_goblins_interop.step);

    // Live three-party handoff, pancake as recipient (needs racket + goblins).
    const goblins_handoff_mod = b.createModule(.{
        .root_source_file = b.path("conformance/goblins_interop/handoff_driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    goblins_handoff_mod.addImport("pancake", lib_mod);
    const goblins_handoff_exe = b.addExecutable(.{
        .name = "pancake-goblins-handoff",
        .root_module = goblins_handoff_mod,
    });
    const run_goblins_handoff = b.addRunArtifact(goblins_handoff_exe);
    run_goblins_handoff.setCwd(b.path("."));
    run_goblins_handoff.has_side_effects = true;
    const goblins_handoff_step = b.step("goblins-handoff", "Live three-party handoff vs Goblins, pancake as recipient (needs racket + goblins)");
    goblins_handoff_step.dependOn(&run_goblins_handoff.step);

    // Live interop proof for the Deno binding: a peer on the C ABI completes the
    // keyed op:start-session handshake with a real Goblins vat, bootstrap-fetches
    // its echo cap, and calls it — the binding↔live-Goblins keyed conversation,
    // not just the in-Zig one. Needs `deno` + `racket` + the `goblins` collection
    // on PATH, so it is a sibling of `check`. The script spawns and tears down the
    // Goblins vat itself, and links the installed `libpancake`.
    const deno_goblins_interop = b.addSystemCommand(&.{
        "deno",                                       "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run",
        "conformance/goblins_interop/deno_client.ts",
    });
    deno_goblins_interop.step.dependOn(b.getInstallStep());
    deno_goblins_interop.setCwd(b.path("."));
    deno_goblins_interop.has_side_effects = true;
    const deno_goblins_interop_step = b.step("deno-goblins-interop", "Live keyed OCapN conversation: Deno binding vs a real Goblins vat (needs deno + racket + goblins)");
    deno_goblins_interop_step.dependOn(&deno_goblins_interop.step);

    // The Python and Racket binding counterparts: same keyed conversation through
    // the same C ABI, each idiomatic to its language. Siblings of `check`.
    const python_goblins_interop = b.addSystemCommand(&.{ "python3", "conformance/goblins_interop/python_client.py" });
    python_goblins_interop.step.dependOn(b.getInstallStep());
    python_goblins_interop.setCwd(b.path("."));
    python_goblins_interop.has_side_effects = true;
    const python_goblins_interop_step = b.step("python-goblins-interop", "Live keyed OCapN conversation: Python binding vs a real Goblins vat (needs python3 + racket + goblins)");
    python_goblins_interop_step.dependOn(&python_goblins_interop.step);

    const racket_goblins_interop = b.addSystemCommand(&.{ "racket", "conformance/goblins_interop/racket_client.rkt" });
    racket_goblins_interop.step.dependOn(b.getInstallStep());
    racket_goblins_interop.setCwd(b.path("."));
    racket_goblins_interop.has_side_effects = true;
    const racket_goblins_interop_step = b.step("racket-goblins-interop", "Live keyed OCapN conversation: Racket binding vs a real Goblins vat (needs racket + goblins)");
    racket_goblins_interop_step.dependOn(&racket_goblins_interop.step);

    // The Rust binding drives the same keyed conversation from a feature-gated
    // tokio example, so it links the installed `libpancake` and needs the async
    // feature. A sibling of `check`, like the others.
    const rust_goblins_interop = b.addSystemCommand(&.{
        "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async", "--example", "goblins_interop",
    });
    rust_goblins_interop.step.dependOn(b.getInstallStep());
    rust_goblins_interop.setCwd(b.path("."));
    rust_goblins_interop.has_side_effects = true;
    const rust_goblins_interop_step = b.step("rust-goblins-interop", "Live keyed OCapN conversation: Rust binding vs a real Goblins vat (needs cargo + racket + goblins)");
    rust_goblins_interop_step.dependOn(&rust_goblins_interop.step);

    // A pancake peer the upstream OCapN test suite can dial: it serves the
    // canonical conformance swiss-nums over `tcp-testing-only`. The orchestrator
    // `run-against-pancake.sh` starts it and runs the suite against it — pointing
    // the external authority back at pancake. Not part of `check`; needs uv +
    // the suite submodule.
    const ocapn_peer_mod = b.createModule(.{
        .root_source_file = b.path("conformance/ocapn-conformance/pancake_peer.zig"),
        .target = target,
        .optimize = optimize,
    });
    ocapn_peer_mod.addImport("pancake", lib_mod);
    const ocapn_peer_exe = b.addExecutable(.{ .name = "pancake-ocapn-peer", .root_module = ocapn_peer_mod });
    b.installArtifact(ocapn_peer_exe);
    const ocapn_conformance = b.addSystemCommand(&.{ "bash", "conformance/ocapn-conformance/run-against-pancake.sh" });
    ocapn_conformance.step.dependOn(b.getInstallStep());
    ocapn_conformance.setCwd(b.path("."));
    ocapn_conformance.has_side_effects = true;
    const ocapn_conformance_step = b.step("ocapn-conformance", "Run the upstream OCapN test suite against a pancake peer (needs uv + the ocapn-conformance submodule)");
    ocapn_conformance_step.dependOn(&ocapn_conformance.step);

    // The rooms cross-language application demo: one Zig-built native client plus
    // the Deno server and the Deno/Python/Racket/Rust clients, all joining one
    // capability-secure chat room over TCP. It needs `deno` (which hosts the room
    // and runs the orchestrator) and the Zig client, always built here. Python,
    // Racket, and Rust each join only when their runtime is on PATH; the demo
    // builds the Rust client itself when `cargo` is present and reports any
    // language it skipped rather than failing. So it is a sibling step, not part of
    // the hermetic gate. The orchestrator (`examples/apps/rooms/demo.ts`) starts the
    // server, runs whichever clients are available, and asserts the all-to-all
    // broadcast among them.
    const rooms_client_mod = b.createModule(.{
        .root_source_file = b.path("examples/apps/rooms/zig/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    rooms_client_mod.addImport("pancake", lib_mod);
    const rooms_client_exe = b.addExecutable(.{
        .name = "pancake-rooms-client",
        .root_module = rooms_client_mod,
    });

    const rooms_demo = b.addSystemCommand(&.{
        "deno",                        "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run",
        "examples/apps/rooms/demo.ts",
    });
    rooms_demo.addArtifactArg(rooms_client_exe); // the Zig client's built path
    rooms_demo.step.dependOn(b.getInstallStep());
    rooms_demo.setCwd(b.path("."));
    rooms_demo.has_side_effects = true;
    const rooms_step = b.step("rooms", "Run the cross-language rooms chat demo (needs deno; joins python3/racket/cargo clients when present)");
    rooms_step.dependOn(&rooms_demo.step);

    // The tasks cross-language application demo: a capability-secure shared task
    // board with CRUD operations and live change notifications through capability
    // callbacks. One Zig-built native client plus the Deno server and
    // Deno/Python/Rust clients, all managing tasks on one board over TCP. Like
    // rooms, it needs `deno` (which hosts the board and runs the orchestrator)
    // and the Zig client, always built here. Python and Rust join when their
    // runtimes are on PATH. It is a sibling step, not part of the hermetic gate.
    const tasks_client_mod = b.createModule(.{
        .root_source_file = b.path("examples/apps/tasks/zig/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    tasks_client_mod.addImport("pancake", lib_mod);
    const tasks_client_exe = b.addExecutable(.{
        .name = "pancake-tasks-client",
        .root_module = tasks_client_mod,
    });

    const tasks_demo = b.addSystemCommand(&.{
        "deno",                        "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run",
        "examples/apps/tasks/demo.ts",
    });
    tasks_demo.addArtifactArg(tasks_client_exe);
    tasks_demo.step.dependOn(b.getInstallStep());
    tasks_demo.setCwd(b.path("."));
    tasks_demo.has_side_effects = true;
    const tasks_step = b.step("tasks", "Run the cross-language tasks board demo (needs deno; joins python3/cargo clients when present)");
    tasks_step.dependOn(&tasks_demo.step);

    // The tools capability showcase: an AI-tool-harness shaped demo. A Deno
    // coordinator hands an agent capabilities to tools — attenuated to read-only,
    // and revocable — and each agent proves delegation, attenuation, and
    // revocation over OCapN/TCP. The coordinator and agent are different languages
    // on the wire, so the capability trio is real, not in-process. It needs `deno`
    // (which hosts the coordinator and runs the orchestrator); the Python agent
    // joins when python3 is on PATH. A sibling step, not part of the hermetic gate.
    const tools_agent_mod = b.createModule(.{
        .root_source_file = b.path("examples/apps/tools/zig/agent.zig"),
        .target = target,
        .optimize = optimize,
    });
    tools_agent_mod.addImport("pancake", lib_mod);
    const tools_agent_exe = b.addExecutable(.{
        .name = "pancake-tools-agent",
        .root_module = tools_agent_mod,
    });

    const tools_demo = b.addSystemCommand(&.{
        "deno",                        "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run",
        "examples/apps/tools/demo.ts",
    });
    tools_demo.addArtifactArg(tools_agent_exe); // the Zig agent's built path
    tools_demo.step.dependOn(b.getInstallStep());
    tools_demo.setCwd(b.path("."));
    tools_demo.has_side_effects = true;
    const tools_step = b.step("tools", "Run the cross-language tools capability showcase (needs deno; joins python3/racket/cargo agents when present)");
    tools_step.dependOn(&tools_demo.step);

    // accountability-on-pancake: a real worked application that runs ON pancake's
    // own runtime. Two native pancake peers complete an OCapN handshake over a
    // real loopback TCP socket; the host publishes an Affordance capability and
    // the caller invokes it, and every invocation produces a signed,
    // transparency-logged Episode attributing the attested caller. Identity
    // (KERI), Episodes, and the transparency log all live above pancake — the app
    // imports the `pancake` module and never reaches into the core. It is a
    // sibling of `check` (it needs no extra runtime, but it is a worked example
    // homed in `conformance/`, not part of the hermetic protocol gate). The app
    // source lives in `conformance/accountability-on-pancake/`.
    const accountability_mod = b.createModule(.{
        .root_source_file = b.path("conformance/accountability-on-pancake/zig/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    accountability_mod.addImport("pancake", lib_mod);
    const accountability_exe = b.addExecutable(.{
        .name = "accountability-on-pancake",
        .root_module = accountability_mod,
    });
    const run_accountability = b.addRunArtifact(accountability_exe);
    run_accountability.setCwd(b.path("."));
    run_accountability.has_side_effects = true;
    const accountability_step = b.step("accountability", "Run the accountability application on pancake's own runtime over real TCP");
    accountability_step.dependOn(&run_accountability.step);

    // The standalone host for cross-language accountability: listens on an
    // ephemeral port and serves one connection. The Deno/Python caller scripts
    // start this, read the port, connect, and invoke.
    const host_mod = b.createModule(.{
        .root_source_file = b.path("conformance/accountability-on-pancake/zig/host.zig"),
        .target = target,
        .optimize = optimize,
    });
    host_mod.addImport("pancake", lib_mod);
    const host_exe = b.addExecutable(.{
        .name = "accountability-host",
        .root_module = host_mod,
    });
    b.installArtifact(host_exe);

    // Three-party accountability test: proves that a handoff-introduced caller's
    // Episode attributes the true caller, not the introducer. In-memory, protocol-
    // level — the same test the Zig-native and cross-seam demos make over TCP.
    const three_party_mod = b.createModule(.{
        .root_source_file = b.path("conformance/accountability-on-pancake/zig/three_party_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    three_party_mod.addImport("pancake", lib_mod);
    const three_party_test = b.addTest(.{
        .name = "accountability-three-party",
        .root_module = three_party_mod,
    });
    const run_three_party = b.addRunArtifact(three_party_test);
    const three_party_step = b.step("accountability-three-party", "Run the three-party accountability attribution test");
    three_party_step.dependOn(&run_three_party.step);

    const arch_check_step_inner = arch_check.create(b);
    const arch_check_step = b.step("arch-check", "Enforce the layer dependency DAG over src/");
    arch_check_step.dependOn(arch_check_step_inner);

    const meta_check_step_inner = meta_check.create(b);
    const meta_check_step = b.step("meta-check", "Enforce agent scaffolding and documented build-step parity");
    meta_check_step.dependOn(meta_check_step_inner);

    // The core correctness gate is hermetic to the Zig toolchain: arch gate,
    // meta gate, tests, oracle checks, the Zig + C examples, and the benchmark smokes. The
    // cross-language C ABI dogfood (`zig build rust-dogfood`, and the wider
    // `zig build bindings`) needs cargo/deno/python/racket on PATH, so it is a
    // sibling step a CI lane runs alongside `check`, not a dependency of it — a
    // contributor with only a Zig toolchain can run the gate.
    const check_step = b.step("check", "Run the Zig-hermetic correctness and meta-scaffolding gate");
    check_step.dependOn(arch_check_step_inner);
    check_step.dependOn(meta_check_step_inner);
    check_step.dependOn(&header_check.step);
    check_step.dependOn(&run_tests.step);
    check_step.dependOn(&run_oracle_tests.step);
    check_step.dependOn(examples_step);
    check_step.dependOn(&run_frame_view_bench.step);
    check_step.dependOn(&run_codec_bench.step);
}
