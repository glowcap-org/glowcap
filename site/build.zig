const std = @import("std");
const zine = @import("zine");

/// The glowcap documentation site is its own build so the heavyweight Zine
/// generator never enters the root `glowcap` build graph. The root build drives
/// these steps from `site/`, redirecting the install prefix so the rendered
/// pages land in the project's `zig-out/site`.
pub fn build(b: *std.Build) void {
    // `-Dport` matches the root build's port flag; the root `docs-serve`
    // step forwards it here. `-Dhost` defaults to loopback so a laptop run
    // is not a LAN service. `site/docs-serve.sh` forwards `DOCS_SERVE_HOST`
    // when the caller did not pass `-Dhost`. The devcontainer sets that
    // variable to `0.0.0.0`, because a Docker-published port reaches only a
    // wide bind inside the container.
    const port = b.option(u16, "port", "Port for the Zine development server (docs-serve)");
    const host = b.option([]const u8, "host", "Bind address for the Zine development server (docs-serve)") orelse "127.0.0.1";

    const site_step = b.step("site", "Render the documentation site under the install prefix");
    const install_prefix = b.graph.path(.install_prefix, "");
    const site_source_root = b.path(".");
    const render = zine.website(b, .{
        .output_path = "site",
        .force = true,
    });
    // Zine's force flag suppresses its confirmation prompt but does not replace
    // existing files. Own the generated directory at this boundary so a second
    // `zig build site` is as reliable as the first.
    const owner = siteOutputOwner(b);
    const clear_output = b.addRunArtifact(owner);
    clear_output.addArg("clear");
    clear_output.addDirectoryArg2(install_prefix, .{ .make_absolute = true });
    clear_output.addDirectoryArg2(site_source_root, .{ .make_absolute = true });
    clear_output.has_side_effects = true;
    render.step.dependOn(&clear_output.step);
    // The marker is written after a successful render. Later clears refuse
    // unmarked non-canonical output, so `--prefix docs` cannot delete a
    // directory this build did not produce.
    const mark = b.addRunArtifact(owner);
    mark.addArg("mark");
    mark.addDirectoryArg2(install_prefix, .{ .make_absolute = true });
    mark.addDirectoryArg2(site_source_root, .{ .make_absolute = true });
    mark.has_side_effects = true;
    mark.step.dependOn(&render.step);
    site_step.dependOn(&mark.step);

    const serve = zine.serve(b, .{});
    serve.addArgs(&.{ "--host", host });
    if (port) |p| serve.addArgs(&.{ "--port", b.fmt("{d}", .{p}) });
    const serve_step = b.step("docs-serve", "Serve the documentation site with Zine's development server");
    serve_step.dependOn(&serve.step);
}

fn siteOutputOwner(b: *std.Build) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path("../tools/check/site_output_owner.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    return b.addExecutable(.{
        .name = "site-output-owner",
        .root_module = mod,
    });
}
