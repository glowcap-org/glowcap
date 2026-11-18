//! Build inputs for the Host action binding generator.
const std = @import("std");
const host_actions = @import("../../gen/binding/host_action.zig");
const execution = @import("../execution.zig");
const AbiImport = @import("../modules.zig").AbiImport;

/// Render the bindings against an action type reflected from this build's Host.
pub fn projections(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    host: *std.Build.Module,
) []const AbiImport {
    const reflection = b.createModule(.{
        .root_source_file = b.path(host_actions.source_dir ++ "/tags.zig"),
        .target = target,
        .optimize = optimize,
    });
    reflection.addImport("c_abi_host", host);
    const reflect = execution.addArtifact(b, .build_tool, b.addExecutable(.{
        .name = "host-action-tags",
        .root_module = reflection,
    }));
    const sources = b.addWriteFiles();
    _ = sources.addCopyDirectory(b.path(host_actions.source_dir), host_actions.source_dir, .{ .include_extensions = &.{".bend"} });
    _ = sources.addCopyFile(reflect.captureStdOut(.{}), host_actions.source_dir ++ "/abi.bend");

    const imports = b.allocator.alloc(AbiImport, host_actions.targets.len) catch @panic("OOM");
    for (host_actions.targets, host_actions.scripts, imports) |binding, script, *result| {
        const render = execution.addSystemCommand(b, .build_tool, &.{ "bend", script });
        render.setCwd(sources.getDirectory());
        render.addFileInput(b.path(".devcontainer/pins.sh"));
        var source = render.captureStdOut(.{});
        if (std.mem.endsWith(u8, binding.path, ".ts")) {
            const config = "bindings/ts/deno.json";
            const format = execution.addSystemCommand(b, .build_tool, &.{ "deno", "fmt", "--config", config, "--ext", "ts", "-" });
            format.setCwd(b.path("."));
            format.setStdIn(.{ .lazy_path = source });
            format.addFileInput(b.path(config));
            format.addFileInput(b.path(".editorconfig"));
            format.addFileInput(b.path(".devcontainer/pins.sh"));
            source = format.captureStdOut(.{});
        }
        result.* = .{ .name = binding.renderer, .module = b.createModule(.{
            .root_source_file = source,
        }) };
    }
    return imports;
}
