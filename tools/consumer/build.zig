//! Downstream fixture for `consumer-check`. Its driver fetches a source archive
//! into this manifest before building core-only and all-public-module variants.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const optional = b.option(bool, "optional", "Link every optional public module") orelse false;
    const iroh = b.option(bool, "iroh", "Link the iroh module") orelse optional;
    const webrtc = b.option(bool, "webrtc", "Link the WebRTC module") orelse optional;

    const glowcap = b.dependency("glowcap", .{ .target = target, .optimize = optimize, .iroh = iroh, .webrtc = webrtc });

    const exe = b.addExecutable(.{
        .name = "glowcap-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("glowcap", glowcap.module("glowcap"));
    const options = b.addOptions();
    options.addOption(bool, "optional", optional);
    options.addOption(bool, "iroh", iroh);
    options.addOption(bool, "webrtc", webrtc);
    exe.root_module.addOptions("options", options);
    if (optional) {
        inline for (.{ "relay_tls", "loam_lmdb", "loam_sqlite" }) |name| {
            exe.root_module.addImport(name, glowcap.module("glowcap_" ++ name));
        }
    }
    if (iroh) exe.root_module.addImport("iroh", glowcap.module("glowcap_iroh"));
    if (webrtc) exe.root_module.addImport("webrtc", glowcap.module("glowcap_webrtc"));
    if (iroh or webrtc) {
        const transport = glowcap.module(if (iroh) "glowcap_iroh" else "glowcap_webrtc");
        const archive = for (transport.link_objects.items) |object| {
            if (object == .static_path) break object.static_path;
        } else @panic("transport has no sidecar archive");
        b.getInstallStep().dependOn(&b.addInstallFile(archive, "sidecars.a").step);
    }
    b.installArtifact(exe);
    b.getInstallStep().dependOn(&exe.step);
}
