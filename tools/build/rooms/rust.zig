//! Rust application migration contracts share their test body between native
//! and browser Wasm. Browser execution remains opt-in like the Rooms page tests.
const std = @import("std");
const execution = @import("../execution.zig");

pub fn register(b: *std.Build, check_step: *std.Build.Step, wasm_archives: *std.Build.Step, wasm_driver: *std.Build.Step, peers: *std.Build.Step) *std.Build.Step {
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
        "cargo", "test", "--locked", "--no-run", "--manifest-path", "apps/rooms/rust/Cargo.toml",
    });
    compile.setCwd(b.path("."));
    compile.step.dependOn(b.getInstallStep());
    const native = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{
        "cargo", "test", "--locked", "--manifest-path", "apps/rooms/rust/Cargo.toml",
    });
    native.setCwd(b.path("."));
    native.step.dependOn(&compile.step);
    const native_step = b.step("rooms-rust-test", "Run portable Rooms application and Rust/Zig static linking contracts natively (needs cargo)");
    native_step.dependOn(&native.step);
    check_step.dependOn(native_step);

    // Clippy over every crate and target, warnings denied, so the Rust that
    // ships the native peers holds the same floor the Zig does.
    const lint = execution.addSystemCommand(b, .build_tool, &.{
        "cargo",       "clippy",        "--locked",   "--manifest-path",      "apps/rooms/rust/Cargo.toml",
        "--workspace", "--all-targets", "--features", "rooms-native/service", "--",
        "-D",          "warnings",
    });
    lint.setCwd(b.path("."));
    lint.step.dependOn(b.getInstallStep());
    const lint_step = b.step("rooms-rust-lint", "Lint the Rooms Rust workspace with clippy, warnings denied (needs cargo)");
    lint_step.dependOn(&lint.step);
    check_step.dependOn(lint_step);

    const wasm = execution.addSystemCommand(b, .build_tool, &.{"env"});
    wasm.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "wasm/lib" } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    wasm.addArgs(&.{
        "cargo",    "build",                  "--locked",  "--manifest-path", "apps/rooms/rust/Cargo.toml",
        "--target", "wasm32-unknown-unknown", "--release", "-p",              "rooms-migration-proofs",
    });
    wasm.setCwd(b.path("."));
    wasm.step.dependOn(wasm_archives);
    wasm.step.dependOn(&layout_check.step);
    const browser = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "node", "check.mjs" });
    browser.setCwd(b.path("apps/rooms/rust/proofs/browser"));
    browser.step.dependOn(&wasm.step);
    const browser_step = b.step("rooms-rust-browser-test", "Run the shared Rooms Rust contracts in Node and Chromium (needs Wasm Rust target and npm ci in proofs/browser)");
    browser_step.dependOn(&browser.step);

    // Separate output keeps the import-free contract distinct from the async
    // embedding, whose generated imports execute browser entropy and timers.
    const host_wasm = execution.addSystemCommand(b, .build_tool, &.{"env"});
    host_wasm.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "wasm/lib" } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    host_wasm.addArgs(&.{
        "cargo",      "build",                  "--locked",     "--manifest-path",                     "apps/rooms/rust/Cargo.toml",
        "--target",   "wasm32-unknown-unknown", "--release",    "-p",                                  "rooms-migration-proofs",
        "--features", "async-host",             "--target-dir", "apps/rooms/rust/target/browser-host",
    });
    host_wasm.setCwd(b.path("."));
    host_wasm.step.dependOn(wasm_archives);
    host_wasm.step.dependOn(&layout_check.step);
    const glue = execution.addSystemCommand(b, .build_tool, &.{
        "wasm-bindgen", "apps/rooms/rust/target/browser-host/wasm32-unknown-unknown/release/rooms_migration_proofs.wasm",
        "--target",     "web",
        "--out-dir",    "apps/rooms/rust/target/browser-host/pkg",
    });
    glue.setCwd(b.path("."));
    glue.step.dependOn(&host_wasm.step);
    // Node and Chromium each own a 30-second contract; native-front shutdown
    // owns another ten. Leave containment headroom above those scenario timers.
    const host_browser = execution.addSystemCommand(b, .{ .browser_proof = 90 }, &.{"env"});
    host_browser.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-web" } }, .{ .prefix = "GLOWCAP_ROOMS_WEB_TEST_BIN=", .make_absolute = true });
    host_browser.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_TEST_BIN=", .make_absolute = true });
    host_browser.addArgs(&.{ "node", "check_host.mjs" });
    host_browser.setCwd(b.path("apps/rooms/rust/proofs/browser"));
    host_browser.step.dependOn(&glue.step);
    host_browser.step.dependOn(peers);
    const host_step = b.step("rooms-rust-browser-host-test", "Run the async Rust Host and Rooms client in Node and Chromium (needs wasm-bindgen matching the Cargo lock)");
    host_step.dependOn(&host_browser.step);
    browser_step.dependOn(host_step);
    return @import("browser.zig").register(b, wasm_archives, &layout_check.step);
}
