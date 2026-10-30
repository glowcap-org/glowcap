//! Public package composition. Dependency builds never register repository gates.
const std = @import("std");
const root = @import("../../build.zig");

pub fn register(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, mods: []*std.Build.Module) void {
    const iroh = b.option(bool, "iroh", "Expose glowcap_iroh and build its Rust backend") orelse false;
    const webrtc = b.option(bool, "webrtc", "Expose glowcap_webrtc and build its Rust backend") orelse false;
    if (iroh or webrtc) {
        // One Rust link unit resolves shared crate features and owns libstd.
        const sidecar = @import("common.zig").rustSidecar(b, "transports/Cargo.toml", "glowcap_sidecars");
        const features = if (iroh and webrtc) "iroh,webrtc" else if (iroh) "iroh" else "webrtc";
        sidecar.build.addArgs(&.{ "--features", features });
        if (iroh) @import("iroh.zig").addModule(b, target, optimize, mods, sidecar.archive);
        if (webrtc) @import("webrtc.zig").addModule(b, target, optimize, mods[root.layerIndex("foundation")], mods[root.layerIndex("model")], mods[root.layerIndex("engine")], mods[root.layerIndex("net")], sidecar.archive);
    }
    _ = @import("mbedtls.zig").addModule(b, target, optimize, mods[root.layerIndex("foundation")], mods[root.layerIndex("net")]);
    const custody = @import("loam/custody.zig").create(b, target, optimize);
    const core = mods[root.layerIndex("loam_core")];
    _ = @import("loam/lmdb.zig").create(b, target, optimize, core, custody, true);
    _ = @import("loam/sqlite.zig").create(b, target, optimize, core, custody, true);
}
