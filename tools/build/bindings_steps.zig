//! The binding verification siblings: each language's test suite over the
//! installed C ABI archives, the `bindings` and `bindings-onion` aggregates, the
//! glowcap-only deno gifter handoff, and the formatting/type/lint half,
//! `fmt`/`fmt-check` in-tree, `bindings-fmt`/`bindings-fmt-check` over every
//! language scope, with the TypeScript stack suites beside them.

const std = @import("std");
const builtin = @import("builtin");
const cargo = @import("cargo.zig");
const commands = @import("commands.zig");
const execution = @import("execution.zig");
const site_build = @import("site.zig");

const addRootedSystemCommand = commands.addRootedSystemCommand;
const addInstalledSystemRun = commands.addInstalledSystemRun;

pub const suites = [_]struct {
    step_name: []const u8,
    description: []const u8,
    argv: []const []const u8,
    needs_iroh_abi: bool,
    posture: execution.Posture,
}{
    .{
        .step_name = "rust-test",
        .description = "Run the Rust binding's tests against the installed C ABI archives (needs cargo)",
        .argv = &.{ "cargo", "test", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async" },
        .needs_iroh_abi = false,
        .posture = .{ .deterministic = 5 },
    },
    .{
        .step_name = "deno-test",
        .description = "Run the TypeScript binding's test suite on Deno against the installed C ABI archives (needs deno)",
        // `--v8-flags=--expose-gc` gives the suite a deterministic `gc()` so
        // the ADR-0025 finalizer-GC scenario can force collection and prove a
        // dropped import releases its export.
        .argv = &.{ "deno", "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-env", "--v8-flags=--expose-gc", "bindings/ts/test/main.ts" },
        .needs_iroh_abi = true,
        .posture = .{ .deterministic = 15 },
    },
    .{
        .step_name = "bun-test",
        .description = "Run the TypeScript binding's test suite on Bun, the same binding as Deno (needs bun)",
        .argv = &.{ "bun", "run", "bindings/ts/test/main.ts" },
        .needs_iroh_abi = true,
        .posture = .{ .deterministic = 15 },
    },
    .{
        .step_name = "python-test",
        .description = "Run the Python binding's test suite and unit tests against the installed C ABI archives (needs python3)",
        .argv = &.{ "python3", "bindings/python/test/main.py" },
        .needs_iroh_abi = true,
        .posture = .{ .deterministic = 10 },
    },
    .{
        .step_name = "racket-test",
        .description = "Run the Racket binding's test suite and every Racket module's unit tests (needs racket + goblins)",
        .argv = &.{ "racket", "-y", "bindings/racket/test/main.rkt" },
        .needs_iroh_abi = true,
        .posture = .{ .deterministic = 15 },
    },
};

fn suiteIndex(comptime step_name: []const u8) comptime_int {
    inline for (suites, 0..) |suite, index| {
        if (std.mem.eql(u8, suite.step_name, step_name)) return index;
    }
    @compileError("unknown binding suite step: " ++ step_name);
}

pub const Registered = struct {
    bindings_step: *std.Build.Step,
    bindings_onion_step: *std.Build.Step,
    rust_binding_lint_step: *std.Build.Step,
    suite_runs: [suites.len]*std.Build.Step.Run,
};

/// The suites and their aggregates. The iroh-dependent wiring stays with
/// the root, which holds the iroh ABI steps the rows depend on.
pub fn register(
    b: *std.Build,
    site_reg: site_build.Registered,
) Registered {
    // ── Binding suites (siblings of `check`) ─────────────────────────────────
    // Each binding's test suite over the Zig C ABI archives. Each consumer loads the
    // installed archives and drives an OCapN round-trip through its idiomatic
    // API over the whole C ABI, allocation context, owned-frame feed, and
    // typed events included (see bindings/README.md). The Rust consumer also
    // exercises the opt-in tokio async layer alongside the sync surface. Each
    // needs its runtime on PATH (cargo / deno / python3 / racket), provided by
    // this repo's devcontainer.
    var suite_runs: [suites.len]*std.Build.Step.Run = undefined;
    for (suites, 0..) |suite, i| {
        suite_runs[i] = addRootedSystemCommand(b, suite.posture, suite.argv);
        suite_runs[i].step.dependOn(b.getInstallStep());
        b.step(suite.step_name, suite.description).dependOn(&suite_runs[i].step);
    }
    // The crate declares its Clippy floor so editors and direct Cargo use see
    // the same contract. This leg supplies only the whole-target feature shape
    // and promotes otherwise-unclassified rustc warnings to failures.
    const rust_binding_lint = addRootedSystemCommand(b, .build_tool, &.{
        "cargo", "clippy", "--manifest-path", "bindings/rust/Cargo.toml", "--all-targets", "--all-features", "--", "-D", "warnings",
    });
    rust_binding_lint.step.dependOn(b.getInstallStep());
    const rust_binding_lint_step = b.step("rust-binding-lint", "Lint the Rust binding library, tests, and examples with Clippy (needs cargo)");
    rust_binding_lint_step.dependOn(&rust_binding_lint.step);
    const rust_suite = suite_runs[suiteIndex("rust-test")];
    rust_suite.step.dependOn(&rust_binding_lint.step);
    const python_wheel_check = addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{
        "python3", "bindings/python/test/artifact.py",
    });
    python_wheel_check.step.dependOn(b.getInstallStep());
    const python_suite = suite_runs[suiteIndex("python-test")];
    python_suite.step.dependOn(&python_wheel_check.step);
    // `test/main.py` imports the package from the checkout, not an installed wheel.
    python_suite.setEnvironmentVariable("PYTHONPATH", commands.rootPath(b, "bindings/python"));
    // The macOS Rust test executable resolves glowcap's installed dylibs at
    // load time. Bind both Cargo's resolver and the test process to the archives
    // this step installed. The suite's compile prep shares its environment.
    const lib_dir = commands.rootPath(b, "zig-out/lib");
    // Pin every runtime to these installed archives. Otherwise a language's
    // ordinary cold-cache resolver may select an older versioned package first.
    for (suite_runs) |run| commands.setLibDir(run, .host);
    commands.setLibDir(rust_binding_lint, .host);
    switch (builtin.os.tag) {
        .macos => {
            rust_suite.setEnvironmentVariable("DYLD_LIBRARY_PATH", lib_dir);
            rust_binding_lint.setEnvironmentVariable("DYLD_LIBRARY_PATH", lib_dir);
        },
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => {
            rust_suite.setEnvironmentVariable("LD_LIBRARY_PATH", lib_dir);
            rust_binding_lint.setEnvironmentVariable("LD_LIBRARY_PATH", lib_dir);
        },
        else => {},
    }
    const python_unit_tests = [_][]const u8{
        "bindings/python/test/lib_resolve_test.py",
        "bindings/python/test/session_writer_test.py",
        "bindings/python/test/bounded_channel_test.py",
        "bindings/python/test/relay_provider_test.py",
        "bindings/python/test/relay_test.py",
        "bindings/python/test/webrtc_provider_test.py",
    };
    for (python_unit_tests) |test_file| {
        const run = addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{
            "uv", "run", "--project", "bindings/python", "--extra", "rendezvous", "--locked", "python3", test_file,
        });
        run.step.dependOn(b.getInstallStep());
        run.setEnvironmentVariable("PYTHONPATH", commands.rootPath(b, "bindings/python"));
        commands.setLibDir(run, .host);
        switch (builtin.os.tag) {
            .macos => run.setEnvironmentVariable("DYLD_LIBRARY_PATH", lib_dir),
            .linux, .freebsd, .netbsd, .openbsd, .dragonfly => run.setEnvironmentVariable("LD_LIBRARY_PATH", lib_dir),
            else => {},
        }
        python_suite.step.dependOn(&run.step);
    }
    // The Rust crate's README claims the core stands alone with no feature on;
    // this compile-only leg keeps that claim a gate instead of a sentence (the
    // cfg-gated surface plus the dead-code deny make it the likeliest shape to
    // rot silently).
    const rust_core_only = addRootedSystemCommand(b, .build_tool, &.{
        "cargo", "check", "--manifest-path", "bindings/rust/Cargo.toml", "--no-default-features",
    });
    rust_core_only.step.dependOn(b.getInstallStep());
    rust_suite.step.dependOn(&rust_core_only.step);
    // The async driver is independently selectable even when a consumer has
    // not enabled a listener provider. Event retirement is intrinsic to that
    // generic loop, not to the public constructors optional features expose.
    const rust_async_only = addRootedSystemCommand(b, .build_tool, &.{
        "cargo", "check", "--manifest-path", "bindings/rust/Cargo.toml", "--no-default-features", "--features", "async",
    });
    rust_async_only.step.dependOn(b.getInstallStep());
    rust_suite.step.dependOn(&rust_async_only.step);
    // Each transport feature alone, on top of nothing: a module one feature
    // reaches into (the driver listener, a locator formatter) must be gated on
    // every feature that reaches it, and the default set always carries `tcp`,
    // so only a feature-alone leg can see that gate missing. The iroh leg
    // checks its tests too, because they call surface the other legs gate.
    for ([_][]const u8{ "relay", "iroh", "onion", "webrtc" }) |feature| {
        const leg = addRootedSystemCommand(b, .build_tool, &.{
            "cargo", "check", "--manifest-path", "bindings/rust/Cargo.toml", "--no-default-features", "--features", feature,
        });
        leg.step.dependOn(b.getInstallStep());
        rust_suite.step.dependOn(&leg.step);
    }
    const rust_iroh_tests_only = addRootedSystemCommand(b, .build_tool, &.{
        "cargo", "check", "--tests", "--manifest-path", "bindings/rust/Cargo.toml", "--no-default-features", "--features", "iroh",
    });
    rust_iroh_tests_only.step.dependOn(b.getInstallStep());
    rust_suite.step.dependOn(&rust_iroh_tests_only.step);
    // The application crates are consumers of the public Rust surface, not
    // fixtures inside it. Compile them separately so a binding API or feature
    // edge cannot leave the demos stale while the binding's own tests stay
    // green.
    const rust_app_manifests = [_][]const u8{
        "apps/tasks/rust/Cargo.toml",
        "apps/tools/rust/Cargo.toml",
        "apps/rooms/clients/rust/Cargo.toml",
    };
    for (rust_app_manifests) |manifest| {
        const check = addRootedSystemCommand(b, .build_tool, &.{
            "cargo", "check", "--manifest-path", manifest,
        });
        check.step.dependOn(b.getInstallStep());
        rust_suite.step.dependOn(&check.step);
    }
    // `raco test` makes a failed rackunit check process-fatal and runs each
    // library's `(module+ test ...)` submodule; compiler-lib in the pinned
    // devcontainer owns that standard command.
    const racket_tests = [_][]const u8{
        "bench/goblins/metrics-test.rkt",
        "bench/goblins/apps-test.rkt",
        "conformance/goblins-peer/racket/captp-message-procs.rkt",
        "conformance/goblins-peer/racket/captp-interop-wire.rkt",
        "conformance/goblins-peer/racket/ocapn-names.rkt",
        "conformance/goblins-peer/racket/session-trace.rkt",
        "conformance/goblins-peer/racket/trace-publish.rkt",
        "conformance/goblins-peer/racket/iroh-netlayer.rkt",
        "conformance/goblins-peer/racket/rooms-client.rkt",
        "conformance/goblins-peer/racket/rooms-dm.rkt",
        "bindings/racket/private/callback.rkt",
        "bindings/racket/private/gc.rkt",
        "bindings/racket/private/webrtc/runtime-test.rkt",
        "bindings/racket/private/webrtc/surface.rkt",
        "bindings/racket/private/iroh/surface.rkt",
        "bindings/racket/private/driver-failure.rkt",
        "bindings/racket/private/errors.rkt",
        "bindings/racket/private/host.rkt",
        "bindings/racket/private/lib-resolve.rkt",
        "bindings/racket/private/listen-loop.rkt",
        "bindings/racket/private/promise.rkt",
        "bindings/racket/private/relay-provider.rkt",
        "bindings/racket/private/session/outbound.rkt",
        "bindings/racket/private/ws-transport.rkt",
    };
    const racket_suite = suite_runs[suiteIndex("racket-test")];
    const racket_make = execution.addSystemCommand(b, .build_tool, &.{ "raco", "make" });
    for (racket_tests) |file| racket_make.addArg(file);
    racket_make.step.dependOn(b.getInstallStep());
    racket_make.has_side_effects = true;
    for (racket_tests) |file| {
        const run = execution.addSystemCommand(b, .{ .deterministic = 10 }, &.{ "raco", "test", file });
        run.step.dependOn(&racket_make.step);
        run.has_side_effects = true;
        racket_suite.step.dependOn(&run.step);
    }

    const bindings_step = b.step("bindings", "Run every binding's test suite and verify the published examples (rust, deno, bun, python, racket)");
    for (suite_runs) |run| bindings_step.dependOn(&run.step);
    bindings_step.dependOn(site_reg.python_examples_check);
    bindings_step.dependOn(site_reg.rust_examples_check);
    bindings_step.dependOn(site_reg.racket_examples_check);
    const bindings_onion_step = b.step("bindings-onion", "Run the onion provider proof in every language binding (needs cargo + deno + python3 + racket)");

    // Glowcap-only three-party handoff: glowcap is exporter, gifter, and
    // recipient over loopback TCP. A broker introduces a recipient to an
    // exporter's Host publication; the recipient transparently redeems the
    // give and messages the exporter *directly*, the broker never relays. Proves
    // the gifter half (ADR-0039) and the engine's swiss re-resolution end to end
    // through the binding, with no Goblins or manual export bookkeeping.
    const run_gifter_handoff = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{
        "deno",                               "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-env",
        "bindings/ts/test/gifter_handoff.ts",
    });
    run_gifter_handoff.step.dependOn(b.getInstallStep());
    b.step("deno-gifter-handoff", "Glowcap-only 3-node three-party handoff: a broker introduces a recipient to an exporter, who is then messaged directly (needs deno)")
        .dependOn(&run_gifter_handoff.step);
    return .{
        .bindings_step = bindings_step,
        .bindings_onion_step = bindings_onion_step,
        .rust_binding_lint_step = rust_binding_lint_step,
        .suite_runs = suite_runs,
    };
}

/// The formatting, per-scope check, and detached-package half, wired after
/// the archives and suite runs it references exist.
pub fn registerChecks(
    b: *std.Build,
    check_step: *std.Build.Step,
    onion_dynamic_install: *std.Build.Step,
    companion_abi_steps: []const *std.Build.Step,
    rooms_rust_lint: *std.Build.Step,
    rooms_browser: *std.Build.Step,
    reg: Registered,
) void {
    const bindings_fmt_deps = reg;
    const suite_runs = bindings_fmt_deps.suite_runs;
    const bindings_onion_step = bindings_fmt_deps.bindings_onion_step;
    const downloads = addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/c-abi/download_test.py" });
    downloads.has_side_effects = true;
    reg.bindings_step.dependOn(&downloads.step);
    check_step.dependOn(&downloads.step);
    // ── Formatting ───────────────────────────────────────────────────────────
    // The formatting gate splits the same way the correctness gate does, and on
    // the same question: what a step needs on PATH. The Zig formatter needs only
    // the Zig toolchain, so `fmt` (write) and `fmt-check` (check) are in-tree and
    // `fmt-check` rides `check`. The Rust formatter needs cargo, so `bindings-fmt`
    // and `bindings-fmt-check` are siblings of `check`, the same posture as
    // `rust-test` and `bindings`. Python's Ruff formatting and lint checks belong
    // to `source-check`. Racket has no formatter in the toolchain and follows
    // `.editorconfig` because its indentation is alignment-sensitive. The
    // indentation policy itself lives in `.editorconfig`, `rustfmt.toml`, and
    // the `deno.json` `fmt` blocks; these steps only run the tools.
    //
    // Zig package caches under `site/zig-pkg/` and `tools/consumer/zig-pkg/`
    // are generated and never formatted. Name the authored files and
    // directories instead of their parents.
    const zig_fmt_paths = [_][]const u8{
        "build.zig",
        "build.zig.zon",
        "src",
        "test",
        "tools/build",
        "tools/check",
        "tools/consumer/build.zig",
        "tools/consumer/build.zig.zon",
        "tools/consumer/main.zig",
        "tools/consumer/optional.zig",
        "tools/fuzz",
        "tools/gen",
        "bench",
        "conformance",
        "interop",
        "examples",
        "site/build.zig",
        "site/build.zig.zon",
        "cli",
        "apps",
    };
    const fmt_paths = b.pathList(&zig_fmt_paths);
    const fmt_write = b.addFmt(.{ .paths = fmt_paths });
    b.step("fmt", "Format Zig sources in place (zig fmt)").dependOn(&fmt_write.step);
    const fmt_check = b.addFmt(.{ .paths = fmt_paths, .check = true });
    b.step("fmt-check", "Check Zig formatting without writing (zig fmt --check)").dependOn(&fmt_check.step);
    // Formatting is a source contract, so the focused gate a Zig edit runs
    // catches it, not only the aggregate.
    b.top_level_steps.get("source-check").?.step.dependOn(&fmt_check.step);
    check_step.dependOn(&fmt_check.step);

    // Every Rust manifest in the tree that no listed workspace covers. They
    // share the root `rustfmt.toml` (hard tabs), which rustfmt finds by
    // searching upward. `source-check` (rust_manifest_inventory.zig) refuses a
    // crate this list leaves out.
    const rust_manifests = [_][]const u8{
        "bindings/proofs/loam_browser/rust/Cargo.toml",
        "bindings/rust/Cargo.toml",
        "bindings/rust/relay/Cargo.toml",
        "bench/langs/clients/rust_bench/Cargo.toml",
        "bench/capnp/rust/Cargo.toml",
        "bench/interface/Cargo.toml",
        "apps/tools/rust/Cargo.toml",
        "apps/tasks/rust/Cargo.toml",
        "apps/rooms/rust/Cargo.toml",
        "apps/rooms/clients/rust/Cargo.toml",
        "transports/Cargo.toml",
        "test/interface/rust/Cargo.toml",
        "tools/interface/authoring/capnp/Cargo.toml",
        "tools/interface/authoring/capnp/e2e/Cargo.toml",
    };
    const bindings_fmt_step = b.step("bindings-fmt", "Format the Rust crates and TypeScript bindings in place (needs cargo + deno)");
    const bindings_fmt_check_step = b.step("bindings-fmt-check", "Check Rust and TypeScript formatting, the lint and type-check for every TypeScript scope, and mypy over the Python binding (needs cargo + deno + mypy)");
    const rust_lint_step = b.step("rust-lint", "Lint every first-party Rust crate and target with Clippy (needs cargo)");
    rust_lint_step.dependOn(reg.rust_binding_lint_step);
    bindings_fmt_check_step.dependOn(rust_lint_step);
    rust_lint_step.dependOn(rooms_rust_lint);
    rust_lint_step.dependOn(&b.top_level_steps.get("interface-bench-lint").?.step);
    rust_lint_step.dependOn(&b.top_level_steps.get("interface-authoring-lint").?.step);
    // `--all` because a virtual workspace manifest declares no bin or lib target
    // of its own: without it `cargo fmt` there reports "Failed to find targets"
    // and formats nothing, which is the quietest way for a whole workspace to
    // sit outside this check while appearing to be inside it.
    for (rust_manifests) |manifest| {
        const write = addRootedSystemCommand(b, .build_tool, &.{ "cargo", "fmt", "--all", "--manifest-path", manifest });
        write.has_side_effects = true;
        bindings_fmt_step.dependOn(&write.step);
        const check = cargo.rustFmtCheck(b, manifest);
        bindings_fmt_check_step.dependOn(&check.step);
        // Rooms has its own feature-complete workspace lint step, the binding
        // has the async whole-target leg registered above, and the Loam browser
        // proof compiles only for wasm32, so `loam-browser-build` lints it for
        // that target. The interface benchmark supplies its phase archive and
        // diagnostic feature in its own lint step. Other standalone crates use
        // their default target set.
        if (!std.mem.eql(u8, manifest, "apps/rooms/rust/Cargo.toml") and
            !std.mem.eql(u8, manifest, "bindings/rust/Cargo.toml") and
            !std.mem.eql(u8, manifest, "bench/interface/Cargo.toml") and
            !std.mem.startsWith(u8, manifest, "tools/interface/authoring/capnp/") and
            !std.mem.eql(u8, manifest, "bindings/proofs/loam_browser/rust/Cargo.toml"))
        {
            const lint = addRootedSystemCommand(b, .build_tool, &.{
                "cargo", "clippy", "--all-targets", "--manifest-path", manifest,
            });
            if (std.mem.eql(u8, manifest, "transports/Cargo.toml")) lint.addArgs(&.{ "--workspace", "--all-features" });
            lint.addArgs(&.{ "--", "-D", "warnings" });
            lint.step.dependOn(b.getInstallStep());
            rust_lint_step.dependOn(&lint.step);
        }
    }
    // The loose TypeScript under the root `deno.json` and the `bindings/ts` deno
    // workspace are separate config scopes, so each is formatted and linted from
    // its own working directory. The second scope is not decoration: the apps had
    // no linter at all, and the first run over them turned up dead imports,
    // `async` with nothing to await, and seven copies of one pinned version.
    //
    // The root scope's two checks also ride `check`, because deno is already in
    // `in_tree_runtimes` and the toolchain reason for the sibling step never applied
    // to them. Leaving them out let three hundred unused imports ship past a green
    // `check`. The `bindings/ts` scope stays in the sibling step, beside the cargo
    // and uv checks that ship with it.
    for ([_][]const u8{ ".", "bindings/ts" }) |dir| {
        const gated = std.mem.eql(u8, dir, ".");
        const write = execution.addSystemCommand(b, .build_tool, &.{ "deno", "fmt" });
        write.setCwd(b.path(dir));
        write.has_side_effects = true;
        bindings_fmt_step.dependOn(&write.step);
        const check = execution.addSystemCommand(b, .build_tool, &.{ "deno", "fmt", "--check" });
        check.setCwd(b.path(dir));
        bindings_fmt_check_step.dependOn(&check.step);
        const lint = execution.addSystemCommand(b, .build_tool, &.{ "deno", "lint" });
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
    // to compile; the site's capture scripts are named on their own for that.
    const deno_check_root = execution.addSystemCommand(b, .build_tool, &.{
        "deno", "check", "apps", "bindings/proofs", "interop", "test/driver/transports", "test/support/transport", "transports", "bench", "tools", "site/scripts",
    });
    // The Rooms page and its proofs import the generated browser module's
    // declarations from zig-out, so the type check needs that build first.
    deno_check_root.step.dependOn(rooms_browser);
    bindings_fmt_check_step.dependOn(&deno_check_root.step);

    // The Python binding's type check. `python-check` under `source-check`
    // formats and lints it with the rest of the tree; the image pins mypy
    // beside ruff, so neither drifts with whatever the host has installed.
    const mypy_check = execution.addSystemCommand(b, .build_tool, &(commands.mypy ++ .{ "bindings/python/glowcap", "tools/run-with-timeout.py" }));
    bindings_fmt_check_step.dependOn(&mypy_check.step);

    // Type-check the TypeScript binding. `deno-test` and `wasm-host-test`
    // both run their entry without type-checking (modern `deno run` does not
    // type-check by default), so a type error would otherwise ship silently;
    // check the public entry points, the test suite, and the wasm browser-binding
    // proof here. The graph is the Deno one: the experimental
    // Node adapter imports `node:ffi`, which Deno cannot resolve, so it stays out
    // (it is `@ts-nocheck` and only loaded under Node).
    const deno_check = execution.addSystemCommand(b, .build_tool, &.{ "deno", "task", "check" });
    deno_check.setCwd(b.path("bindings/ts"));
    bindings_fmt_check_step.dependOn(&deno_check.step);
    // Pure binding-edge invariants: no FFI permissions, but still a real
    // executable test because codec/profile input refusal is behavior.
    const deno_stack_test = commands.addSystemCommandIn(b, .{ .deterministic = 30 }, b.path("bindings/ts"), &.{
        "deno",
        "test",
        "runtime/test/errors_test.ts",
        "runtime/test/action_test.ts",
        "runtime/test/terminal_release_test.ts",
        "runtime/test/driver_failure_test.ts",
        "runtime/test/value_test.ts",
        "runtime/test/ffi_handle_test.ts",
        "runtime/test/websocket_stack_test.ts",
        "runtime/test/cancellation_test.ts",
        "runtime/test/dial_test.ts",
        "runtime/test/rendezvous_test.ts",
        "runtime/test/websocket_test.ts",
        "relay/test/relay_test.ts",
        "relay/test/ws_relay_test.ts",
        "relay/test/deno_channels_test.ts",
        "relay/test/transport_test.ts",
        "webrtc/test/channel_test.ts",
        "webrtc/test/peer_test.ts",
        "webrtc/test/listener_test.ts",
        "webrtc/test/exchange_test.ts",
    });
    bindings_fmt_check_step.dependOn(&deno_stack_test.step);
    // Release hashing owns only a staged file, with no FFI or network access.
    const deno_checksum_test = commands.addSystemCommandIn(b, .{ .deterministic = 30 }, b.path("bindings/ts"), &.{
        "deno", "test", "--allow-read", "--allow-write", "runtime/test/release_checksum_test.ts",
    });
    bindings_fmt_check_step.dependOn(&deno_checksum_test.step);
    // These tests touch FFI but open no sockets; keep that capability out
    // of the otherwise pure stack suite.
    const deno_ffi_runtime_test = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{
        "deno", "test", "--allow-ffi", "--allow-read", "--allow-env=GLOWCAP_LIB_DIR", "bindings/ts/runtime/test/abi_value_test.ts", "bindings/ts/runtime/test/ffi_frame_test.ts", "bindings/ts/runtime/test/host_vows_test.ts", "bindings/ts/runtime/test/reference_ownership_test.ts", "bindings/ts/runtime/test/session_writer_test.ts", "bindings/ts/runtime/test/session_establishment_test.ts", "bindings/ts/runtime/test/driver_loop_retire_test.ts", "bindings/ts/runtime/test/driver_loop_teardown_test.ts", "bindings/ts/runtime/test/library_resolution_test.ts",
    });
    bindings_fmt_check_step.dependOn(&deno_ffi_runtime_test.step);
    // The WebRTC driver adapter's exchange book, driven by fakes. It imports
    // the C loader but never opens the library.
    const deno_webrtc_driver_test = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{
        "deno", "test", "--allow-ffi", "--allow-read", "--allow-env=GLOWCAP_LIB_DIR", "bindings/ts/webrtc/test/driver_test.ts",
    });
    bindings_fmt_check_step.dependOn(&deno_webrtc_driver_test.step);
    const deno_runtime_test = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{
        "deno", "test", "--allow-ffi", "--allow-read", "--allow-net=127.0.0.1", "--allow-env=GLOWCAP_LIB_DIR", "bindings/ts/runtime/test/runtime_test.ts",
    });
    bindings_fmt_check_step.dependOn(&deno_runtime_test.step);
    const deno_driver_listener_test = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{
        "deno",                                         "test", "--allow-ffi", "--allow-read", "--allow-net=127.0.0.1", "--allow-env",
        "bindings/ts/tcp/test/driver_listener_test.ts",
    });
    bindings_fmt_check_step.dependOn(&deno_driver_listener_test.step);
    const deno_onion_test = commands.addSystemCommandIn(b, .{ .deterministic = 30 }, b.path("bindings/ts"), &.{
        "deno",
        "test",
        "--allow-ffi",
        "--allow-read",
        "--allow-net=127.0.0.1",
        "onion/test/onion_test.ts",
    });
    // The test loads the Host and driver archives as well as onion. Depending
    // only on the onion install lets a focused run pair a freshly generated
    // fingerprint mirror with stale core archives left in zig-out. The full
    // install is the Zig artifact set this binding process consumes.
    deno_onion_test.step.dependOn(b.getInstallStep());
    deno_onion_test.step.dependOn(onion_dynamic_install);
    bindings_fmt_check_step.dependOn(&deno_onion_test.step);

    // ADR-0042's binding-package proof. Rust, Python, and Racket exercise the
    // onion provider in their ordinary test suites; TypeScript has the
    // focused provider suite above. Bun is a second TypeScript runtime, not a
    // fifth binding, and cannot own a blocking provider lifecycle.
    bindings_onion_step.dependOn(&suite_runs[suiteIndex("rust-test")].step);
    bindings_onion_step.dependOn(&deno_onion_test.step);
    bindings_onion_step.dependOn(&suite_runs[suiteIndex("python-test")].step);
    bindings_onion_step.dependOn(&suite_runs[suiteIndex("racket-test")].step);

    // The detached Rust consumer enables every transport feature, so it links
    // the iroh and WebRTC companions that the default install leaves out.
    const package_check = addRootedSystemCommand(b, .child_bounded, &.{ "python3", "tools/check/binding_packages.py" });
    package_check.step.dependOn(b.getInstallStep());
    for (companion_abi_steps) |abi_step| package_check.step.dependOn(abi_step);
    package_check.has_side_effects = true;
    const package_step = b.step("bindings-package-check", "Build and exercise detached Rust, Python and Racket packages and dry-run JSR publication (needs cargo, uv, racket and deno)");
    package_step.dependOn(&package_check.step);
}
