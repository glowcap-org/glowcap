//! The browser consumer proves the shared resource lifecycle through Chromium.
const std = @import("std");
const commands = @import("commands.zig");
const Gates = @import("gates.zig").Registered;

pub fn register(b: *std.Build, gates: Gates) void {
    const layout_check = commands.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{ "deno", "run", "--allow-read", "tools/wasm/rust_layouts.ts", "--check" });
    layout_check.step.dependOn(gates.wasm_install);
    const compile = commands.addRootedSystemCommand(b, .build_tool, &.{ "cargo", "build", "--manifest-path", "bindings/proofs/loam_browser/rust/Cargo.toml", "--target", "wasm32-unknown-unknown", "--release", "--target-dir", "bindings/rust/target/loam-browser" });
    commands.setLibDir(compile, .wasm);
    compile.step.dependOn(gates.wasm_archives);
    compile.step.dependOn(&layout_check.step);
    const lint = commands.addRootedSystemCommand(b, .build_tool, &.{ "cargo", "clippy", "--manifest-path", "bindings/proofs/loam_browser/rust/Cargo.toml", "--target", "wasm32-unknown-unknown", "--release", "--target-dir", "bindings/rust/target/loam-browser", "--", "-D", "warnings" });
    commands.setLibDir(lint, .wasm);
    lint.step.dependOn(&compile.step);
    const glue = commands.addRootedSystemCommand(b, .build_tool, &.{ "wasm-bindgen", "bindings/rust/target/loam-browser/wasm32-unknown-unknown/release/loam_browser_proof.wasm", "--target", "web", "--out-dir", "zig-out/wasm/loam-browser" });
    glue.step.dependOn(&lint.step);
    b.step("loam-browser-build", "Build the Loam Rust browser consumer and check its compiled Wasm contract (needs cargo + wasm-bindgen)").dependOn(&glue.step);
    const proof = commands.addRootedSystemCommand(b, .{ .browser_proof = 45 }, &.{ "deno", "run", "--allow-all", "bindings/proofs/loam_browser/check.mjs" });
    proof.step.dependOn(&glue.step);
    b.step("loam-browser-test", "Prove Loam atomic browser storage, ownership, cancellation, sharing and cold restoration after page reload (needs deno + Playwright)").dependOn(&proof.step);
}
