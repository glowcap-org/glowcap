//! Production Rooms application Wasm and its generated browser glue.
const std = @import("std");
const execution = @import("../execution.zig");

pub const Modules = struct { production: *std.Build.Step, proof: *std.Build.Step, startup: *std.Build.Step.Run };

pub fn register(b: *std.Build, archives: *std.Build.Step, layouts: *std.Build.Step) Modules {
    const metadata = execution.addSystemCommand(b, .build_tool, &.{
        "cargo",   "run",               "--locked",  "--manifest-path",  "apps/rooms/rust/Cargo.toml",
        "-p",      "rooms-application", "--example", "browser_metadata", "--",
        "--check",
    });
    metadata.setCwd(b.path("."));
    b.step("rooms-browser-metadata-check", "Verify browser metadata against the Rust application owners").dependOn(&metadata.step);
    const glue = module(b, archives, layouts, &metadata.step, "release", "browser-app", "zig-out/wasm/rooms");
    const proof_glue = module(b, archives, layouts, &metadata.step, "browser-proof", "browser-app-proof", "apps/rooms/rust/target/browser-app-proof/pkg");
    const step = b.step("rooms-browser-build", "Build the production Rust Rooms browser module (needs the Wasm Rust target and matching wasm-bindgen)");
    step.dependOn(glue);
    const proof = execution.addSystemCommand(b, .{ .browser_proof = 60 }, &.{ "deno", "run", "--allow-all", "check_entry.mjs" });
    proof.setCwd(b.path("apps/rooms/rust/proofs/browser"));
    proof.step.dependOn(step);
    const proof_cache = execution.addSystemCommand(b, .build_tool, &.{ "deno", "cache", "apps/rooms/rust/proofs/browser/check_entry.mjs" });
    proof.step.dependOn(&proof_cache.step);
    b.step("rooms-browser-test", "Prove production Rooms Wasm startup in Deno and Chromium").dependOn(&proof.step);
    return .{ .production = step, .proof = proof_glue, .startup = proof };
}

// Application journeys need the application's exports. Fixture exports and
// their generated code remain in the independent contract module. Separate
// outputs keep proof links from replacing deployable artifacts.
fn module(b: *std.Build, archives: *std.Build.Step, layouts: *std.Build.Step, metadata: *std.Build.Step, profile: []const u8, target_dir: []const u8, output: []const u8) *std.Build.Step {
    const compile = execution.addSystemCommand(b, .build_tool, &.{"env"});
    compile.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "wasm/lib" } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    compile.addArgs(&.{
        "cargo",         "rustc",                  "--locked",                                         "--manifest-path", "apps/rooms/rust/Cargo.toml",
        "--target",      "wasm32-unknown-unknown", "--profile",                                        profile,           "-p",
        "rooms-browser", "--target-dir",           b.fmt("apps/rooms/rust/target/{s}", .{target_dir}), "--crate-type",    "cdylib",
    });
    compile.setCwd(b.path("."));
    compile.step.dependOn(archives);
    compile.step.dependOn(layouts);
    compile.step.dependOn(metadata);
    const glue = execution.addSystemCommand(b, .build_tool, &.{
        "wasm-bindgen", b.fmt("apps/rooms/rust/target/{s}/wasm32-unknown-unknown/{s}/rooms_browser.wasm", .{ target_dir, profile }),
        "--target",     "web",
        "--out-dir",    output,
    });
    glue.setCwd(b.path("."));
    glue.step.dependOn(&compile.step);
    return &glue.step;
}
