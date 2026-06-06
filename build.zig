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
