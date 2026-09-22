//! Rust application contracts share their test body between native
//! and browser Wasm. Browser execution remains opt-in like the Rooms page tests.
const std = @import("std");
const builtin = @import("builtin");
const common = @import("../common.zig");
const execution = @import("../execution.zig");

pub fn register(b: *std.Build, check_step: *std.Build.Step, runtime_gate: *execution.RuntimeGate, wasm_archives: *std.Build.Step, wasm_driver: *std.Build.Step, peers: *std.Build.Step) *std.Build.Step {
    const layouts = execution.addSystemCommand(b, .build_tool, &.{
        "deno", "run", "--allow-read", "--allow-write", "tools/wasm/rust_layouts.ts",
    });
    layouts.setCwd(b.path("."));
    layouts.step.dependOn(wasm_driver);
    b.step("gen-rust-wasm-layouts", "Generate Rust layout constants and fingerprints from the compiled wasm32 C ABI").dependOn(&layouts.step);
    const layout_check = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{
        "deno", "run", "--allow-read", "tools/wasm/rust_layouts.ts", "--check",
    });
    layout_check.setCwd(b.path("."));
    layout_check.step.dependOn(wasm_driver);
    b.step("gen-rust-wasm-layouts-check", "Verify Rust layout constants and fingerprints match the compiled wasm32 C ABI").dependOn(&layout_check.step);
    check_step.dependOn(&layout_check.step);
    const compile = execution.addSystemCommand(b, .build_tool, &.{
        "cargo", "test", "--quiet", "--locked", "--no-run", "--manifest-path", "apps/rooms/rust/Cargo.toml",
    });
    compile.setCwd(b.path("."));
    compile.step.dependOn(b.getInstallStep());
    const native = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{
        "cargo", "test", "--locked", "--manifest-path", "apps/rooms/rust/Cargo.toml",
    });
    native.setCwd(b.path("."));
    native.step.dependOn(&compile.step);
    // Where the test executables find glowcap's installed shared libraries at
    // load time, the way `rust-dogfood` already binds its own.
    //
    // This whole workspace is one `cargo test`, so Cargo unifies features across
    // its members and the crates that link a transport hand that link to every
    // test binary built beside them. `-p rooms-glowcap --lib` on its own enables
    // no transport and needs nothing; the same tests under the workspace run
    // need `libglowcap_net_transport_iroh`, and without this resolved they fail
    // to start rather than to assert — a loader error with no test name in it.
    const rooms_lib_dir = common.rootPath(b, "zig-out/lib");
    for ([_]*std.Build.Step.Run{ compile, native }) |run| {
        run.setEnvironmentVariable("GLOWCAP_LIB_DIR", rooms_lib_dir);
        switch (builtin.os.tag) {
            .macos => run.setEnvironmentVariable("DYLD_LIBRARY_PATH", rooms_lib_dir),
            .linux, .freebsd, .netbsd, .openbsd, .dragonfly => run.setEnvironmentVariable("LD_LIBRARY_PATH", rooms_lib_dir),
            else => {},
        }
    }
    const native_step = b.step("rooms-rust-test", "Run portable Rooms application and Rust/Zig static linking contracts natively (needs cargo)");
    native_step.dependOn(&native.step);
    runtime_gate.add(native_step);

    // Clippy over every crate and target, so the Rust that ships the native
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
    lint.step.dependOn(b.getInstallStep());
    const lint_step = b.step("rooms-rust-lint", "Lint the Rooms Rust workspace with clippy, warnings denied (needs cargo)");
    lint_step.dependOn(&lint.step);
    runtime_gate.add(lint_step);

    const wasm = execution.addSystemCommand(b, .build_tool, &.{"env"});
    wasm.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "wasm/lib" } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    wasm.addArgs(&.{
        "cargo",    "build",                  "--quiet",   "--locked", "--manifest-path",       "apps/rooms/rust/Cargo.toml",
        "--target", "wasm32-unknown-unknown", "--release", "-p",       "rooms-contract-proofs",
    });
    wasm.setCwd(b.path("."));
    wasm.step.dependOn(wasm_archives);
    wasm.step.dependOn(&layout_check.step);
    const browser = execution.addSystemCommand(b, .{ .browser_proof = 60 }, &.{ "deno", "run", "--allow-all", "check.mjs" });
    browser.setCwd(b.path("apps/rooms/rust/proofs/browser"));
    browser.step.dependOn(&wasm.step);
    const browser_cache = execution.addSystemCommand(b, .build_tool, &.{ "deno", "cache", "apps/rooms/rust/proofs/browser/check.mjs" });
    browser.step.dependOn(&browser_cache.step);
    const browser_step = b.step("rooms-rust-browser-test", "Run the shared Rooms Rust contracts in Deno and Chromium (needs the Wasm Rust target)");
    browser_step.dependOn(&browser.step);

    // Separate output keeps the import-free contract distinct from the async
    // embedding, whose generated imports execute browser entropy and timers.
    const host_wasm = execution.addSystemCommand(b, .build_tool, &.{"env"});
    host_wasm.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "wasm/lib" } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    host_wasm.addArgs(&.{
        "cargo",      "build",                  "--quiet",                             "--locked", "--manifest-path",       "apps/rooms/rust/Cargo.toml",
        "--target",   "wasm32-unknown-unknown", "--release",                           "-p",       "rooms-contract-proofs", "--features",
        "async-host", "--target-dir",           "apps/rooms/rust/target/browser-host",
    });
    host_wasm.setCwd(b.path("."));
    host_wasm.step.dependOn(wasm_archives);
    host_wasm.step.dependOn(&layout_check.step);
    const glue = execution.addSystemCommand(b, .build_tool, &.{
        "wasm-bindgen", "apps/rooms/rust/target/browser-host/wasm32-unknown-unknown/release/rooms_contract_proofs.wasm",
        "--target",     "web",
        "--out-dir",    "apps/rooms/rust/target/browser-host/pkg",
    });
    glue.setCwd(b.path("."));
    glue.step.dependOn(&host_wasm.step);
    // Deno and Chromium each own a 30-second contract; native-front shutdown
    // owns another ten. Leave containment headroom above those scenario timers.
    const host_browser = execution.addSystemCommand(b, .{ .browser_proof = 90 }, &.{"env"});
    host_browser.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-web" } }, .{ .prefix = "GLOWCAP_ROOMS_WEB_TEST_BIN=", .make_absolute = true });
    host_browser.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_TEST_BIN=", .make_absolute = true });
    host_browser.addArgs(&.{ "deno", "run", "--allow-all", "check_host.mjs" });
    host_browser.setCwd(b.path("apps/rooms/rust/proofs/browser"));
    host_browser.step.dependOn(&glue.step);
    host_browser.step.dependOn(peers);
    const host_browser_cache = execution.addSystemCommand(b, .build_tool, &.{ "deno", "cache", "apps/rooms/rust/proofs/browser/check_host.mjs" });
    host_browser.step.dependOn(&host_browser_cache.step);
    const host_step = b.step("rooms-rust-browser-host-test", "Run the async Rust Host and Rooms client in Deno and Chromium (needs wasm-bindgen matching the Cargo lock)");
    host_step.dependOn(&host_browser.step);
    browser_step.dependOn(host_step);
    return @import("browser.zig").register(b, wasm_archives, &layout_check.step);
}
