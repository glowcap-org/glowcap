const std = @import("std");
const zine = @import("zine");

/// The pancake documentation site is its own build so the heavyweight Zine
/// generator never enters the root `pancake` build graph. The root build drives
/// these steps with `zig build --build-file site/build.zig …`, redirecting the
/// install prefix so the rendered pages land in the project's `zig-out/site`.
pub fn build(b: *std.Build) void {
    // `-Dport` matches the root build's port flag and pins the development
    // server; the root `docs-serve` step forwards it here.
    const port = b.option(u16, "port", "Port for the Zine development server (docs-serve)");

    const render = zine.website(b, .{
        .output_path = "site",
        .force = true,
    });
    const site_step = b.step("site", "Render the documentation site under the install prefix");
    site_step.dependOn(&render.step);

    const serve = zine.serve(b, .{});
    serve.addArgs(&.{ "--host", "127.0.0.1" });
    if (port) |p| serve.addArgs(&.{ "--port", b.fmt("{d}", .{p}) });
    const serve_step = b.step("docs-serve", "Serve the documentation site with Zine's development server");
    serve_step.dependOn(&serve.step);
}
