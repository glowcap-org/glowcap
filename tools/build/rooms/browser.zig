//! Production Rooms application Wasm and its generated browser glue.
const std = @import("std");
const execution = @import("../execution.zig");

pub fn register(b: *std.Build, archives: *std.Build.Step, layouts: *std.Build.Step) *std.Build.Step {
    const metadata = execution.addSystemCommand(b, .build_tool, &.{
        "cargo",   "run",               "--locked",  "--manifest-path",  "apps/rooms/rust/Cargo.toml",
        "-p",      "rooms-application", "--example", "browser_metadata", "--",
        "--check",
    });
    metadata.setCwd(b.path("."));
    b.step("rooms-browser-metadata-check", "Verify browser metadata against the Rust application owners").dependOn(&metadata.step);
    const compile = execution.addSystemCommand(b, .build_tool, &.{"env"});
    compile.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "wasm/lib" } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    compile.addArgs(&.{
        "cargo",        "build",                              "--locked",  "--manifest-path", "apps/rooms/rust/Cargo.toml",
        "--target",     "wasm32-unknown-unknown",             "--release", "-p",              "rooms-browser",
        "--target-dir", "apps/rooms/rust/target/browser-app",
    });
    compile.setCwd(b.path("."));
    compile.step.dependOn(archives);
    compile.step.dependOn(layouts);
    compile.step.dependOn(&metadata.step);
    const glue = execution.addSystemCommand(b, .build_tool, &.{
        "wasm-bindgen", "apps/rooms/rust/target/browser-app/wasm32-unknown-unknown/release/rooms_browser.wasm",
        "--target",     "web",
        "--out-dir",    "zig-out/wasm/rooms",
    });
    glue.setCwd(b.path("."));
    glue.step.dependOn(&compile.step);
    const step = b.step("rooms-browser-build", "Build the production Rust Rooms browser module (needs the Wasm Rust target and matching wasm-bindgen)");
    step.dependOn(&glue.step);
    const proof = execution.addSystemCommand(b, .{ .browser_proof = 60 }, &.{ "node", "check_entry.mjs" });
    proof.setCwd(b.path("apps/rooms/rust/proofs/browser"));
    proof.step.dependOn(step);
    b.step("rooms-browser-test", "Prove production Rooms Wasm startup in Node and Chromium").dependOn(&proof.step);
    return step;
}
