//! Rust application contracts share their test body between host
//! and browser Wasm. Browser execution remains opt-in like the Rooms page tests.
const std = @import("std");
const builtin = @import("builtin");
const common = @import("../common.zig");
const execution = @import("../execution.zig");

pub fn register(b: *std.Build, check_step: *std.Build.Step, runtime_gate: *execution.RuntimeGate, wasm_archives: *std.Build.Step, wasm_driver: *std.Build.Step, peers: *std.Build.Step, zig_archives: []const *std.Build.Step) *std.Build.Step {
    const layouts = execution.addSystemCommand(b, .build_tool, &.{
        "deno", "run", "--allow-read", "--allow-write", "tools/wasm/rust_layouts.ts",
    });
    layouts.setCwd(b.path("."));
    layouts.step.dependOn(wasm_driver);
    // The target descriptor and archive-owned field inventory are two inputs
    // of this projection. Regenerate names before reading them so a combined
    // generation command cannot race new Wasm layouts against an old inventory.
    layouts.step.dependOn(&b.top_level_steps.get("gen-binding-ffi-layouts").?.step);
    b.step("gen-rust-wasm-layouts", "Generate Rust layout constants and fingerprints from the compiled wasm32 C ABI").dependOn(&layouts.step);
    const layout_check = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{
        "deno", "run", "--allow-read", "tools/wasm/rust_layouts.ts", "--check",
    });
    layout_check.setCwd(b.path("."));
    layout_check.step.dependOn(wasm_driver);
    layout_check.step.dependOn(&b.top_level_steps.get("gen-binding-ffi-layouts-check").?.step);
    b.step("gen-rust-wasm-layouts-check", "Verify Rust layout constants and fingerprints match the compiled wasm32 C ABI").dependOn(&layout_check.step);
    check_step.dependOn(&layout_check.step);
    const application = @import("browser.zig").register(b, wasm_archives, &layout_check.step);
    const projection_cost = execution.addSystemCommand(b, .benchmark, &.{ "deno", "run", "--allow-all", "bench/rooms/projection_bench.ts" });
    projection_cost.setCwd(b.path("."));
    projection_cost.step.dependOn(application.production);
    b.step("bench-rooms-projection", "Count conversation and line-custody visits in the production Rooms projection").dependOn(&projection_cost.step);
    application.startup.step.dependOn(peers);
    const compile = execution.addSystemCommand(b, .build_tool, &.{
        "cargo", "test", "--quiet", "--locked", "--no-run", "--manifest-path", "apps/rooms/rust/Cargo.toml",
    });
    compile.setCwd(b.path("."));
    // Native proofs do not consume shared core libraries, headers or the CLI.
    // Keep archive freshness without rebuilding the full default installation.
    for (zig_archives) |archive| compile.step.dependOn(archive);
    const maximum_foreign_prefix = "session_foreign::maximum_session_foreign_";
    const maximum_step = b.step("rooms-session-foreign-test", "Run maximum foreign session admission, capacity refusal and cold-source replacement traces (needs cargo)");
    // Each independent scenario owns a 30-second process budget. Chain them
    // so these maximum-population traces do not contend with one another.
    var previous: *std.Build.Step = &compile.step;
    inline for (.{
        "admission_preserves_every_exact_identity",
        "capacity_refusal_preserves_the_cold_graph",
        "replacement_and_cold_copy_preserve_receipt_replay",
    }) |scenario| {
        inline for (.{ "sqlite", "lmdb" }) |engine| {
            const maximum = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{
                "cargo", "test", "--quiet", "--locked", "--manifest-path", "apps/rooms/rust/Cargo.toml", "--lib", "--", "--exact", maximum_foreign_prefix ++ scenario ++ "_on_" ++ engine,
            });
            // An exact selector must execute its witness, including after a rename.
            execution.expectStdOutMatch(maximum, "test result: ok. 1 passed;");
            maximum.setCwd(b.path("."));
            maximum.step.dependOn(previous);
            setLibraryEnvironment(maximum, b);
            previous = &maximum.step;
        }
    }
    maximum_step.dependOn(previous);
    const workspace_tests = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{
        "cargo", "test", "--locked", "--manifest-path", "apps/rooms/rust/Cargo.toml", "--", "--skip", maximum_foreign_prefix, "--skip", "session_executor::",
    });
    workspace_tests.setCwd(b.path("."));
    workspace_tests.step.dependOn(maximum_step);
    // Executor scenarios own their process window separately from the other
    // workspace and documentation tests. Both commands select the same Cargo
    // workspace, preserving feature unification and the complete test set.
    const executor_tests = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{
        "cargo", "test", "--locked", "--manifest-path", "apps/rooms/rust/Cargo.toml", "--lib", "--", "session_executor::",
    });
    executor_tests.setCwd(b.path("."));
    executor_tests.step.dependOn(&workspace_tests.step);
    // Where the test executables find glowcap's installed shared libraries at
    // load time, the way `rust-dogfood` already binds its own.
    //
    // Both proof runs select this workspace, so Cargo unifies features across
    // its members and the crates that link a transport hand that link to every
    // test binary built beside them. `-p rooms-glowcap --lib` on its own enables
    // no transport and needs nothing; the same tests under the workspace run
    // need `libglowcap_net_transport_iroh`, and without this resolved they fail
    // to start rather than to assert, a loader error with no test name in it.
    const rooms_lib_dir = common.rootPath(b, "zig-out/lib");
    for ([_]*std.Build.Step.Run{ compile, workspace_tests, executor_tests }) |run| setLibraryEnvironment(run, b);
    const rust_test_step = b.step("rooms-rust-test", "Run portable Rooms application and Rust/Zig static linking contracts on the host (needs cargo)");
    rust_test_step.dependOn(&executor_tests.step);
    rust_test_step.dependOn(&common.rustFmtCheck(b, "apps/rooms/rust/Cargo.toml").step);
    const admission_cost = execution.addSystemCommand(b, .benchmark, &.{
        "cargo", "run",                   "--quiet",   "--locked",       "--release", "--manifest-path", "apps/rooms/rust/Cargo.toml",
        "-p",    "rooms-contract-proofs", "--example", "admission_cost",
    });
    admission_cost.setCwd(b.path("."));
    setLibraryEnvironment(admission_cost, b);
    admission_cost.step.dependOn(&compile.step);
    b.step("bench-rooms-admission", "Measure admission cost and enforce zero steady policy allocations").dependOn(&admission_cost.step);
    rust_test_step.dependOn(&admission_cost.step);
    runtime_gate.add(rust_test_step);

    // Clippy over every crate and target, so the Rust that ships the host
    // peers holds the same floor the Zig does.
    //
    // The clippy half of that floor is declared in `[workspace.lints]` rather
    // than here, so rust-analyzer and a hand-run `cargo clippy` reach the same
    // verdict this does; before that it lived on this command line alone and a
    // contributor found out at push time. `-D warnings` stays for the rustc
    // lints the table does not name, and for the `--all-targets` compile.
    const lint = execution.addSystemCommand(b, .build_tool, &.{
        "cargo",       "clippy",        "--quiet",    "--locked",                 "--manifest-path", "apps/rooms/rust/Cargo.toml",
        "--workspace", "--all-targets", "--features", "rooms-services/processes", "--",              "-D",
        "warnings",
    });
    lint.setCwd(b.path("."));
    // Metadata checking does not link the C archives. An explicit path avoids
    // download discovery without installing unrelated transport artifacts.
    lint.setEnvironmentVariable("GLOWCAP_LIB_DIR", rooms_lib_dir);
    const lint_step = b.step("rooms-rust-lint", "Lint the Rooms Rust workspace with clippy, warnings denied (needs cargo)");
    lint_step.dependOn(&lint.step);
    runtime_gate.add(lint_step);

    const wasm = execution.addSystemCommand(b, .build_tool, &.{"env"});
    wasm.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "wasm/lib" } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    wasm.addArgs(&.{
        "cargo",        "rustc",                  "--quiet",   "--locked",      "--manifest-path", "apps/rooms/rust/Cargo.toml",
        "--target",     "wasm32-unknown-unknown", "--profile", "browser-proof", "-p",              "rooms-contract-proofs",
        "--crate-type", "cdylib",
    });
    wasm.setCwd(b.path("."));
    wasm.step.dependOn(wasm_archives);
    wasm.step.dependOn(&layout_check.step);
    const browser = execution.addSystemCommand(b, .{ .browser_proof = 60 }, &.{ "deno", "run", "--allow-all", "check.mjs" });
    browser.setCwd(b.path("apps/rooms/rust/proofs/browser"));
    browser.step.dependOn(&wasm.step);
    const browser_cache = execution.addSystemCommand(b, .build_tool, &.{ "deno", "cache", "apps/rooms/rust/proofs/browser/check.mjs" });
    browser.step.dependOn(&browser_cache.step);
    const contracts_step = b.step("rooms-rust-contract-browser-test", "Run portable Rooms Rust declarations and linked Host contracts in Deno and Chromium");
    contracts_step.dependOn(&browser.step);
    const browser_step = b.step("rooms-rust-browser-test", "Run the shared Rooms Rust contracts in Deno and Chromium (needs the Wasm Rust target)");
    browser_step.dependOn(contracts_step);

    // Separate output keeps the import-free contract distinct from the async
    // embedding, whose generated imports execute browser entropy and timers.
    const host_wasm = execution.addSystemCommand(b, .build_tool, &.{"env"});
    host_wasm.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "wasm/lib" } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    host_wasm.addArgs(&.{
        "cargo",      "rustc",                  "--quiet",      "--locked",                            "--manifest-path", "apps/rooms/rust/Cargo.toml",
        "--target",   "wasm32-unknown-unknown", "--profile",    "browser-proof",                       "-p",              "rooms-contract-proofs",
        "--features", "async-host",             "--target-dir", "apps/rooms/rust/target/browser-host", "--crate-type",    "cdylib",
    });
    host_wasm.setCwd(b.path("."));
    host_wasm.step.dependOn(wasm_archives);
    host_wasm.step.dependOn(&layout_check.step);
    const glue = execution.addSystemCommand(b, .build_tool, &.{
        "wasm-bindgen", "apps/rooms/rust/target/browser-host/wasm32-unknown-unknown/browser-proof/rooms_contract_proofs.wasm",
        "--target",     "web",
        "--out-dir",    "apps/rooms/rust/target/browser-host/pkg",
    });
    glue.setCwd(b.path("."));
    glue.step.dependOn(&host_wasm.step);
    // Executor scenarios run in their own bounded processes before this Host
    // journey. Deno, Chromium and web-server teardown retain this budget.
    const host_browser = execution.addSystemCommand(b, .{ .browser_proof = 90 }, &.{"env"});
    host_browser.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-web-proof" } }, .{ .prefix = "GLOWCAP_ROOMS_WEB_TEST_BIN=", .make_absolute = true });
    host_browser.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-server-proof" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_TEST_BIN=", .make_absolute = true });
    host_browser.addArgs(&.{ "deno", "run", "--allow-all", "check_host.mjs" });
    host_browser.setCwd(b.path("apps/rooms/rust/proofs/browser"));
    host_browser.step.dependOn(&glue.step);
    host_browser.step.dependOn(peers);
    const host_browser_cache = execution.addSystemCommand(b, .build_tool, &.{ "deno", "cache", "apps/rooms/rust/proofs/browser/check_host.mjs" });
    host_browser.step.dependOn(&host_browser_cache.step);
    const sharing_browser = execution.addSystemCommand(b, .{ .browser_proof = 45 }, &.{ "deno", "run", "--allow-all", "check_host.mjs", "--managed-sharing" });
    sharing_browser.setCwd(b.path("apps/rooms/rust/proofs/browser"));
    sharing_browser.step.dependOn(application.proof);
    sharing_browser.step.dependOn(&host_browser_cache.step);
    sharing_browser.step.dependOn(peers);
    b.step("rooms-managed-sharing-browser-test", "Share exact managed use and control through the production Noise relay").dependOn(&sharing_browser.step);
    const rooms_browser = execution.addSystemCommand(b, .{ .browser_proof = 45 }, &.{ "deno", "run", "--allow-all", "check_host.mjs", "--managed-rooms" });
    rooms_browser.setCwd(b.path("apps/rooms/rust/proofs/browser"));
    rooms_browser.step.dependOn(application.proof);
    rooms_browser.step.dependOn(&host_browser_cache.step);
    rooms_browser.step.dependOn(peers);
    for ([_]*std.Build.Step.Run{ application.startup, sharing_browser, rooms_browser }) |run| {
        run.setEnvironmentVariable("GLOWCAP_ROOMS_WEB_TEST_BIN", common.rootPath(b, "zig-out/libexec/rooms-web-proof"));
        run.setEnvironmentVariable("GLOWCAP_ROOMS_SERVER_TEST_BIN", common.rootPath(b, "zig-out/libexec/rooms-server-proof"));
    }
    b.step("rooms-managed-rooms-browser-test", "Register, subscribe, chat and stream exact-source files through the production Rooms server").dependOn(&rooms_browser.step);
    const graph_browser = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "deno", "run", "--allow-all", "check_host.mjs", "--session-graph" });
    graph_browser.setCwd(b.path("apps/rooms/rust/proofs/browser"));
    graph_browser.step.dependOn(&glue.step);
    graph_browser.step.dependOn(&host_browser_cache.step);
    b.step("rooms-session-graph-browser-test", "Run session graph commit, rollback, recovery and cold reload in Chromium").dependOn(&graph_browser.step);
    const executor_group = b.option(u8, "rooms-session-executor-group", "Run one managed executor proof group (0-3); default runs every group");
    if (executor_group) |group| if (group > 3) @panic("rooms-session-executor-group must be 0-3");
    const executor_step = b.step("rooms-session-executor-browser-test", "Run managed session receipt execution, interruption and cold recovery in Chromium");
    var executor_previous: ?*std.Build.Step = null;
    if (executor_group == null) {
        const storage = execution.addSystemCommand(b, .{ .browser_proof = 90 }, &.{ "deno", "run", "--allow-all", "check_host.mjs", "--session-executor-storage" });
        storage.setCwd(b.path("apps/rooms/rust/proofs/browser"));
        storage.step.dependOn(&glue.step);
        storage.step.dependOn(&host_browser_cache.step);
        executor_previous = &storage.step;
    }
    for (0..4) |group| {
        if (executor_group) |selected| if (selected != group) continue;
        // The largest group has 17 complete scenarios, each with its own
        // 30-second browser deadline. A fresh process contains each group.
        const executor = execution.addSystemCommand(b, .{ .browser_proof = 600 }, &.{ "deno", "run", "--allow-all", "check_host.mjs" });
        executor.addArg(b.fmt("--session-executor-group={d}", .{group}));
        executor.setCwd(b.path("apps/rooms/rust/proofs/browser"));
        executor.step.dependOn(&glue.step);
        executor.step.dependOn(&host_browser_cache.step);
        if (executor_previous) |earlier| executor.step.dependOn(earlier);
        executor_previous = &executor.step;
    }
    executor_step.dependOn(executor_previous.?);
    host_browser.step.dependOn(executor_step);
    const foreign_browser = execution.addSystemCommand(b, .{ .browser_proof = 120 }, &.{ "deno", "run", "--allow-all", "check_host.mjs", "--session-foreign" });
    foreign_browser.setCwd(b.path("apps/rooms/rust/proofs/browser"));
    foreign_browser.step.dependOn(&glue.step);
    foreign_browser.step.dependOn(&host_browser_cache.step);
    // This four-phase maximum-population proof owns its process deadline,
    // like the executor groups, and remains mandatory for the Host gate.
    host_browser.step.dependOn(&foreign_browser.step);
    b.step("rooms-session-foreign-browser-test", "Run maximum foreign session fields and disconnected preservation in Chromium").dependOn(&foreign_browser.step);
    // Two independently bounded source phases share one surviving exporter.
    const foreign_reload = execution.addSystemCommand(b, .{ .browser_proof = 60 }, &.{ "deno", "run", "--allow-all", "check_host.mjs", "--session-foreign-reload" });
    foreign_reload.setCwd(b.path("apps/rooms/rust/proofs/browser"));
    foreign_reload.step.dependOn(&glue.step);
    foreign_reload.step.dependOn(&host_browser_cache.step);
    const foreign_reload_step = b.step("rooms-session-foreign-browser-reload-test", "Restore maximum foreign session fields after full page reload against a surviving exporter");
    foreign_reload_step.dependOn(&foreign_reload.step);
    const host_step = b.step("rooms-rust-browser-host-test", "Run the async Rust Host and Rooms client in Deno and Chromium (needs wasm-bindgen matching the Cargo lock)");
    host_step.dependOn(&host_browser.step);
    browser_step.dependOn(host_step);
    browser_step.dependOn(foreign_reload_step);
    return application.production;
}

fn setLibraryEnvironment(run: *std.Build.Step.Run, b: *std.Build) void {
    const directory = common.rootPath(b, "zig-out/lib");
    run.setEnvironmentVariable("GLOWCAP_LIB_DIR", directory);
    switch (builtin.os.tag) {
        .macos => run.setEnvironmentVariable("DYLD_LIBRARY_PATH", directory),
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => run.setEnvironmentVariable("LD_LIBRARY_PATH", directory),
        else => {},
    }
}
