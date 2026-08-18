//! The binding verification siblings: the per-language C ABI dogfoods, the
//! Racket unit tests, the `bindings` and `bindings-onion` aggregates, the
//! pancake-only deno gifter handoff, and the formatting/type/lint half —
//! `fmt`/`fmt-check` in-tree, `bindings-fmt`/`bindings-fmt-check` over every
//! language scope, with the TypeScript stack suites beside them.

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const site_build = @import("site.zig");

const addRootedSystemCommand = common.addRootedSystemCommand;
const addInstalledSystemRun = common.addInstalledSystemRun;

pub const dogfoods = [_]struct {
    step_name: []const u8,
    description: []const u8,
    argv: []const []const u8,
    needs_iroh_abi: bool,
}{
    .{
        .step_name = "rust-dogfood",
        .description = "Run Rust C ABI dogfood tests against the pancake C ABI archives (needs cargo)",
        .argv = &.{ "cargo", "test", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async" },
        .needs_iroh_abi = false,
    },
    .{
        .step_name = "deno-dogfood",
        .description = "Run the Deno C ABI dogfood against the pancake C ABI archives (needs deno)",
        // `--v8-flags=--expose-gc` gives the dogfood a deterministic `gc()` so
        // the ADR-0063 finalizer-GC scenario can force collection and prove a
        // dropped import releases its export.
        .argv = &.{ "deno", "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-env", "--v8-flags=--expose-gc", "bindings/ts/dogfood/zig_smoke.ts" },
        .needs_iroh_abi = true,
    },
    .{
        .step_name = "bun-dogfood",
        .description = "Run the Bun C ABI dogfood against the pancake C ABI archives — same multi-runtime binding as Deno (needs bun)",
        .argv = &.{ "bun", "run", "bindings/ts/dogfood/zig_smoke.ts" },
        .needs_iroh_abi = true,
    },
    .{
        .step_name = "python-dogfood",
        .description = "Run the Python C ABI dogfood against the pancake C ABI archives (needs python3)",
        .argv = &.{ "python3", "bindings/python/zig_smoke.py" },
        .needs_iroh_abi = true,
    },
    .{
        .step_name = "racket-dogfood",
        .description = "Run the Racket C ABI dogfood against the pancake C ABI archives (needs racket)",
        .argv = &.{ "racket", "-y", "bindings/racket/zig-smoke.rkt" },
        .needs_iroh_abi = true,
    },
};

pub const Registered = struct {
    bindings_step: *std.Build.Step,
    bindings_onion_step: *std.Build.Step,
    dogfood_runs: [dogfoods.len]*std.Build.Step.Run,
};

/// The dogfoods and their aggregates. The iroh-dependent wiring stays with
/// the root, which holds the iroh ABI steps the rows depend on.
pub fn register(
    b: *std.Build,
    site_reg: site_build.Registered,
) Registered {
    // ── C ABI dogfoods (siblings of `check`) ─────────────────────────────────
    // Per-language dogfood of the Zig C ABI archives. Each consumer loads the
    // installed archives and drives an OCapN round-trip through its idiomatic
    // API over the whole C ABI — allocation context, owned-frame feed, and
    // typed events included (see bindings/README.md). The Rust consumer also
    // exercises the opt-in tokio async layer alongside the sync surface. Each
    // needs its runtime on PATH (cargo / deno / python3 / racket), provided by
    // this repo's devcontainer.
    var dogfood_runs: [dogfoods.len]*std.Build.Step.Run = undefined;
    for (dogfoods, 0..) |dogfood, i| {
        dogfood_runs[i] = addRootedSystemCommand(b, dogfood.argv);
        dogfood_runs[i].step.dependOn(b.getInstallStep());
        b.step(dogfood.step_name, dogfood.description).dependOn(&dogfood_runs[i].step);
    }
    // The macOS Rust test executable resolves pancake's installed dylibs at
    // load time. Bind both Cargo's resolver and the test process to the archives
    // this step installed.
    const dogfood_lib_dir = b.pathFromRoot("zig-out/lib");
    dogfood_runs[0].setEnvironmentVariable("PANCAKE_LIB_DIR", dogfood_lib_dir);
    switch (builtin.os.tag) {
        .macos => dogfood_runs[0].setEnvironmentVariable("DYLD_LIBRARY_PATH", dogfood_lib_dir),
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => dogfood_runs[0].setEnvironmentVariable("LD_LIBRARY_PATH", dogfood_lib_dir),
        else => {},
    }
    const python_relay_tests = [_][]const u8{
        "bindings/python/test/relay_provider_test.py",
        "bindings/python/test/relay_test.py",
    };
    for (python_relay_tests) |test_file| {
        const run = addRootedSystemCommand(b, &.{
            "uv", "run", "--project", "bindings/python", "--locked", "python3", test_file,
        });
        run.step.dependOn(b.getInstallStep());
        run.setEnvironmentVariable("PYTHONPATH", b.pathFromRoot("bindings/python"));
        run.setEnvironmentVariable("PANCAKE_LIB_DIR", dogfood_lib_dir);
        switch (builtin.os.tag) {
            .macos => run.setEnvironmentVariable("DYLD_LIBRARY_PATH", dogfood_lib_dir),
            .linux, .freebsd, .netbsd, .openbsd, .dragonfly => run.setEnvironmentVariable("LD_LIBRARY_PATH", dogfood_lib_dir),
            else => {},
        }
        dogfood_runs[2].step.dependOn(&run.step);
    }
    // The Rust crate's README claims the core stands alone with no feature on;
    // this compile-only leg keeps that claim a gate instead of a sentence (the
    // cfg-gated surface plus the dead-code deny make it the likeliest shape to
    // rot silently).
    const rust_core_only = addRootedSystemCommand(b, &.{
        "cargo", "check", "--manifest-path", "bindings/rust/Cargo.toml", "--no-default-features",
    });
    rust_core_only.step.dependOn(b.getInstallStep());
    dogfood_runs[0].step.dependOn(&rust_core_only.step);
    // The Racket unit tests. `raco test` is not in the devcontainer image, so
    // they run through `tools/check/racket-test.rkt`, which does the two things
    // a bare `racket <file>` does not: it makes a failed rackunit check raise,
    // so the exit code this step reads means something, and it runs a
    // `(module+ test ...)` submodule, which is where a library's own tests have
    // to live because top-level checks would run on every import. Without this
    // step the bench apps had no check at all, which is how one of them came to
    // pass `'bcom` where a procedure was expected and stay broken.
    const racket_tests = [_][]const u8{
        "bench/goblins/metrics-test.rkt",
        "bench/goblins/apps-test.rkt",
        "conformance/goblins-peer/racket/captp-message-procs.rkt",
        "conformance/goblins-peer/racket/ocapn-names.rkt",
        "conformance/goblins-peer/racket/session-trace.rkt",
        "conformance/goblins-peer/racket/trace-publish.rkt",
        "conformance/goblins-peer/racket/iroh-netlayer.rkt",
        "conformance/goblins-peer/racket/rooms-client.rkt",
        "conformance/goblins-peer/racket/rooms-dm.rkt",
        "bindings/racket/private/gc.rkt",
        "bindings/racket/private/driver-failure.rkt",
        "bindings/racket/private/lib-resolve.rkt",
        "bindings/racket/private/relay-provider.rkt",
        "bindings/racket/private/ws-transport.rkt",
    };
    const racket_test_step = b.step("racket-test", "Run the Racket unit tests (needs racket + goblins)");
    for (racket_tests) |file| {
        const run = b.addSystemCommand(&.{ "racket", "-y", "tools/check/racket-test.rkt", file });
        run.step.dependOn(b.getInstallStep());
        run.has_side_effects = true;
        racket_test_step.dependOn(&run.step);
    }

    const bindings_step = b.step("bindings", "Run language-binding dogfood and verify published examples (rust, deno, bun, python, racket)");
    for (dogfood_runs) |run| bindings_step.dependOn(&run.step);
    bindings_step.dependOn(site_reg.python_examples_check);
    bindings_step.dependOn(site_reg.rust_examples_check);
    bindings_step.dependOn(site_reg.racket_examples_check);
    const bindings_onion_step = b.step("bindings-onion", "Run the onion provider proof in every native language binding (needs cargo + deno + python3 + racket)");

    // Pancake-only three-party handoff: pancake is exporter, gifter, and
    // recipient over loopback TCP. A broker introduces a recipient to an
    // exporter's node-giftable object; the recipient transparently redeems the
    // give and messages the exporter *directly*, the broker never relays. Proves
    // the gifter half (ADR-0009) and the engine's swiss re-resolution end to end
    // through the binding, with no Goblins or manual export bookkeeping.
    const run_gifter_handoff = b.addSystemCommand(&.{
        "deno",                                  "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-env",
        "bindings/ts/dogfood/gifter_handoff.ts",
    });
    run_gifter_handoff.step.dependOn(b.getInstallStep());
    b.step("deno-gifter-handoff", "Pancake-only 3-node three-party handoff: a broker introduces a recipient to an exporter, who is then messaged directly (needs deno)")
        .dependOn(&run_gifter_handoff.step);
    return .{
        .bindings_step = bindings_step,
        .bindings_onion_step = bindings_onion_step,
        .dogfood_runs = dogfood_runs,
    };
}

/// The formatting and per-scope check half, wired after the archives and
/// dogfood runs it references exist.
pub fn registerChecks(
    b: *std.Build,
    check_step: *std.Build.Step,
    onion_dynamic_install: *std.Build.Step,
    reg: Registered,
) void {
    const bindings_fmt_deps = reg;
    const dogfood_runs = bindings_fmt_deps.dogfood_runs;
    const bindings_onion_step = bindings_fmt_deps.bindings_onion_step;
    // ── Formatting ───────────────────────────────────────────────────────────
    // The formatting gate splits the same way the correctness gate does, and on
    // the same question: what a step needs on PATH. The Zig formatter needs only
    // the Zig toolchain, so `fmt` (write) and `fmt-check` (check) are in-tree and
    // `fmt-check` rides `check`. The Rust formatter needs cargo, so `bindings-fmt`
    // and `bindings-fmt-check` are siblings of `check`, the same posture as
    // `rust-dogfood` and `bindings`. Python and Racket have no formatter in the
    // toolchain — Python's formatters forbid tabs and Racket indentation is
    // alignment-sensitive — so they are governed by `.editorconfig` alone. The
    // indentation policy itself lives in `.editorconfig`, `rustfmt.toml`, and
    // the `deno.json` `fmt` blocks; these steps only run the tools.
    //
    // `site/zig-pkg/` (Zig's fetched-package dir for the site sub-build) is
    // generated and never formatted, so the site rows name its two source files
    // directly rather than the `site` directory.
    const zig_fmt_paths = [_][]const u8{
        "build.zig",          "build.zig.zon", "src",     "test",     "tools",
        "bench",              "conformance",   "interop", "examples", "site/build.zig",
        "site/build.zig.zon", "cli",           "apps",
    };
    const fmt_write = b.addFmt(.{ .paths = &zig_fmt_paths });
    b.step("fmt", "Format Zig sources in place (zig fmt)").dependOn(&fmt_write.step);
    const fmt_check = b.addFmt(.{ .paths = &zig_fmt_paths, .check = true });
    b.step("fmt-check", "Check Zig formatting without writing (zig fmt --check)").dependOn(&fmt_check.step);
    check_step.dependOn(&fmt_check.step);

    // Every Rust crate shares the root `rustfmt.toml` (hard tabs); rustfmt finds
    // it by searching upward, so one config governs all of them.
    const rust_manifests = [_][]const u8{
        "bindings/rust/Cargo.toml",
        "bench/langs/clients/rust_bench/Cargo.toml",
        "apps/tools/rust/Cargo.toml",
        "apps/tasks/rust/Cargo.toml",
        "apps/rooms/clients/rust/Cargo.toml",
        "transports/iroh/Cargo.toml",
        "transports/webrtc/Cargo.toml",
    };
    const bindings_fmt_step = b.step("bindings-fmt", "Format the Rust crates and TypeScript bindings in place (needs cargo + deno)");
    const bindings_fmt_check_step = b.step("bindings-fmt-check", "Check Rust and TypeScript formatting, the lint and type-check for every TypeScript scope, and ruff plus mypy over the Python binding (needs cargo + deno + uv)");
    for (rust_manifests) |manifest| {
        const write = addRootedSystemCommand(b, &.{ "cargo", "fmt", "--manifest-path", manifest });
        write.has_side_effects = true;
        bindings_fmt_step.dependOn(&write.step);
        const check = addRootedSystemCommand(b, &.{ "cargo", "fmt", "--check", "--manifest-path", manifest });
        bindings_fmt_check_step.dependOn(&check.step);
    }
    // The loose TypeScript under the root `deno.json` and the `bindings/ts` deno
    // workspace are separate config scopes, so each is formatted and linted from
    // its own working directory. The second scope is not decoration: the apps had
    // no linter at all, and the first run over them turned up dead imports,
    // `async` with nothing to await, and seven copies of one pinned version.
    //
    // The root scope's two checks also ride `check`, because deno is already in
    // `check_runtimes` and the toolchain reason for the sibling step never applied
    // to them. Leaving them out let three hundred unused imports ship past a green
    // `check`. The `bindings/ts` scope stays in the sibling step, beside the cargo
    // and uv checks that ship with it.
    for ([_][]const u8{ ".", "bindings/ts" }) |dir| {
        const gated = std.mem.eql(u8, dir, ".");
        const write = b.addSystemCommand(&.{ "deno", "fmt" });
        write.setCwd(b.path(dir));
        write.has_side_effects = true;
        bindings_fmt_step.dependOn(&write.step);
        const check = b.addSystemCommand(&.{ "deno", "fmt", "--check" });
        check.setCwd(b.path(dir));
        bindings_fmt_check_step.dependOn(&check.step);
        const lint = b.addSystemCommand(&.{ "deno", "lint" });
        lint.setCwd(b.path(dir));
        bindings_fmt_check_step.dependOn(&lint.step);
        if (gated) check_step.dependOn(&check.step);
        if (gated) check_step.dependOn(&lint.step);
    }

    // Type-check the same root scope. `deno run` does not type-check, so every
    // demo, interop driver, and probe outside the binding workspace shipped
    // unchecked; the first run found a real one. The directories are named
    // rather than passing `.` because `site/zig-pkg/` is Zig's generated
    // fetched-package tree and carries third-party fixtures that are not ours
    // to compile.
    const deno_check_root = b.addSystemCommand(&.{
        "deno", "check", "apps", "bindings/proofs", "interop", "transports", "bench", "tools",
    });
    bindings_fmt_check_step.dependOn(&deno_check_root.step);

    // The Python binding gets the same two checks the TypeScript one has. It
    // had neither, and the first run found a `NameError` waiting in
    // `IrohServer.uri` plus two public annotations naming types the module
    // never imported — the kind of defect a linter catches for free and a
    // dogfood run reaches only if it happens to touch that line. `uvx` pins
    // both tools, so the gate does not drift with whatever the host has
    // installed; `uv` is already a `check-external` prerequisite.
    const ruff_check = b.addSystemCommand(&.{
        "uvx", "ruff@0.9.10", "check", "bindings/python", "tools/run-with-timeout.py",
    });
    bindings_fmt_check_step.dependOn(&ruff_check.step);
    const mypy_check = b.addSystemCommand(&.{
        "uvx", "mypy@1.15.0", "--ignore-missing-imports", "bindings/python/pancake", "tools/run-with-timeout.py",
    });
    bindings_fmt_check_step.dependOn(&mypy_check.step);

    // Type-check the TypeScript binding. `deno-dogfood` and `wasm-driver-test`
    // both run their entry without type-checking (modern `deno run` does not
    // type-check by default), so a type error would otherwise ship silently;
    // check the public entry points, the dogfood, and the wasm browser-binding
    // proof here. The graph is the Deno one: the experimental
    // Node adapter imports `node:ffi`, which Deno cannot resolve, so it stays out
    // (it is `@ts-nocheck` and only loaded under Node).
    const deno_check = b.addSystemCommand(&.{ "deno", "task", "check" });
    deno_check.setCwd(b.path("bindings/ts"));
    bindings_fmt_check_step.dependOn(&deno_check.step);
    // Pure binding-edge invariants: no FFI permissions, but still a real
    // executable test because codec/profile input refusal is behavior.
    const deno_stack_test = b.addSystemCommand(&.{
        "deno",
        "test",
        "runtime/test/errors_test.ts",
        "runtime/test/driver_failure_test.ts",
        "runtime/test/value_test.ts",
        "runtime/test/native_handle_test.ts",
        "runtime/test/websocket_stack_test.ts",
        "runtime/test/cancellation_test.ts",
        "relay/test/relay_test.ts",
    });
    deno_stack_test.setCwd(b.path("bindings/ts"));
    bindings_fmt_check_step.dependOn(&deno_stack_test.step);
    // This ownership proof takes and reads a real native pointer but opens no
    // archive; keep that capability out of the otherwise pure stack suite.
    const deno_native_frame_test = addInstalledSystemRun(b, &.{
        "deno", "test", "--allow-ffi", "--allow-read", "--allow-env=PANCAKE_LIB_DIR", "bindings/ts/runtime/test/native_frame_test.ts",
    });
    bindings_fmt_check_step.dependOn(&deno_native_frame_test.step);
    const deno_runtime_test = addInstalledSystemRun(b, &.{
        "deno", "test", "--allow-ffi", "--allow-read", "--allow-net=127.0.0.1", "--allow-env=PANCAKE_LIB_DIR", "bindings/ts/runtime/test/runtime_test.ts",
    });
    bindings_fmt_check_step.dependOn(&deno_runtime_test.step);
    const deno_driver_listener_test = addInstalledSystemRun(b, &.{
        "deno",                                         "test", "--allow-ffi", "--allow-read", "--allow-net=127.0.0.1", "--allow-env",
        "bindings/ts/tcp/test/driver_listener_test.ts",
    });
    bindings_fmt_check_step.dependOn(&deno_driver_listener_test.step);
    const deno_onion_test = b.addSystemCommand(&.{
        "deno",
        "test",
        "--allow-ffi",
        "--allow-read",
        "--allow-net=127.0.0.1",
        "onion/test/onion_test.ts",
    });
    deno_onion_test.setCwd(b.path("bindings/ts"));
    deno_onion_test.step.dependOn(onion_dynamic_install);
    bindings_fmt_check_step.dependOn(&deno_onion_test.step);

    // ADR-0108's binding-package proof. Rust, Python, and Racket exercise the
    // onion provider in their ordinary archive dogfoods; TypeScript has the
    // focused provider suite above. Bun is a second TypeScript runtime, not a
    // fifth binding, and cannot own a blocking provider lifecycle.
    bindings_onion_step.dependOn(&dogfood_runs[0].step);
    bindings_onion_step.dependOn(&deno_onion_test.step);
    bindings_onion_step.dependOn(&dogfood_runs[3].step);
    bindings_onion_step.dependOn(&dogfood_runs[4].step);
}
