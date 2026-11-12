//! The ocapnviz visualizer's steps: static build checks ride `check`, its own
//! suite rides `runtime-check`, the production Live-mode proof drives
//! Chromium, and the website's copy is built under the site's assets.

const std = @import("std");
const commands = @import("commands.zig");
const Binary = @import("rooms/peers.zig").Binary;
const execution = @import("execution.zig");

pub const Registration = struct {
    /// The page built under the site's assets by `site-ocapnviz-page`. The
    /// site render depends on it.
    site_page: *std.Build.Step,
};

pub fn register(
    b: *std.Build,
    check_step: *std.Build.Step,
    runtime_gate: *execution.RuntimeGate,
    wasm_driver_install_step: *std.Build.Step,
    browser_preflight_step: *std.Build.Step,
    rooms_services_install: *std.Build.Step,
) Registration {
    // ── ocapnviz (the live visualizer) ──────────────────────────────────────
    // ocapnviz is its own Deno scope: the root `deno.json` excludes it, so none
    // of the TypeScript checks above reach it, and its own suite ran only when
    // someone remembered to type `deno test` in that directory. A suite nothing
    // invokes rots invisibly, because every run a human does by hand is green
    // right up until the one nobody did.
    //
    // The suite therefore rides `runtime-check`. Deno is part of the declared
    // in-tree toolchain, so its absence fails instead of silently reducing
    // coverage. Typecheck, format, lint, and the Vite
    // production bundle are build-tool work: keeping them outside the suite's
    // deterministic deadline means that deadline measures tests rather than a
    // cold dependency and bundler cache.
    const ocapnviz_build_check = commands.addRootedSystemCommand(b, .build_tool, &.{ "bash", "tools/check/ocapnviz-build-check.sh" });
    ocapnviz_build_check.has_side_effects = true;
    ocapnviz_build_check.step.dependOn(wasm_driver_install_step);
    const ocapnviz_test = commands.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{"env"});
    ocapnviz_test.has_side_effects = true;
    Binary.server.addEnv(ocapnviz_test);
    ocapnviz_test.addArgs(&.{ "bash", "tools/check/ocapnviz-test.sh" });
    // The suite's Live-mode cases load the installed C ABI archives through the
    // TypeScript binding, which refuses an archive whose callable surface is
    // not this checkout's.
    ocapnviz_test.step.dependOn(b.getInstallStep());
    ocapnviz_test.step.dependOn(rooms_services_install);
    ocapnviz_test.step.dependOn(&ocapnviz_build_check.step);
    const ocapnviz_test_step = b.step("ocapnviz-test", "Run the ocapnviz visualizer's own test suite (needs deno)");
    ocapnviz_test_step.dependOn(&ocapnviz_test.step);
    check_step.dependOn(&ocapnviz_build_check.step);
    runtime_gate.add(ocapnviz_test_step);

    const ocapnviz_check_step = b.step("ocapnviz-check", "Check ocapnviz: types, formatting, lint, and its test suite (needs deno)");
    ocapnviz_check_step.dependOn(&ocapnviz_test.step);
    const ocapnviz_fmt = execution.addSystemCommand(b, .build_tool, &.{ "deno", "fmt" });
    ocapnviz_fmt.setCwd(b.path("apps/ocapnviz"));
    ocapnviz_fmt.has_side_effects = true;
    b.step("ocapnviz-fmt", "Format the ocapnviz sources in place (needs deno)").dependOn(&ocapnviz_fmt.step);

    // The developer launch (ADR-0032): Vite under the app's own supervisor,
    // which owns the child's cleanup so an interrupted run cannot leave a
    // server holding the port. Live mode loads the wasm Host, so that is built
    // first; nothing else here is a build product.
    const ocapnviz_dev = execution.addSystemCommand(b, .service, &.{ "bash", "dev.sh" });
    ocapnviz_dev.setCwd(b.path("apps/ocapnviz"));
    ocapnviz_dev.has_side_effects = true;
    ocapnviz_dev.step.dependOn(wasm_driver_install_step);
    b.step("ocapnviz-dev", "Serve ocapnviz from Vite for development; open the printed URL (needs deno)").dependOn(&ocapnviz_dev.step);

    // Production Live mode is a browser product, so its last proof is a sibling
    // rather than part of `check`: it needs the devcontainer's pinned Chromium.
    // CI runs it in the browser lane (`ci/groups.py`).
    // The app-owned task builds Vite's dist, serves only that output, and drives
    // its wasm OCapN peer against the Rooms server's trace capability endpoint.
    const ocapnviz_live_browser = execution.addSystemCommand(b, .{ .browser_proof = 120 }, &.{"env"});
    ocapnviz_live_browser.setCwd(b.path("apps/ocapnviz"));
    ocapnviz_live_browser.has_side_effects = true;
    Binary.server.addEnv(ocapnviz_live_browser);
    ocapnviz_live_browser.addArgs(&.{ "deno", "task", "test:live-browser" });
    // Its trace host loads the installed C ABI archives through the TypeScript
    // binding, as the suite does, so a job that inherits no build state still
    // installs them first.
    ocapnviz_live_browser.step.dependOn(b.getInstallStep());
    ocapnviz_live_browser.step.dependOn(rooms_services_install);
    ocapnviz_live_browser.step.dependOn(wasm_driver_install_step);
    ocapnviz_live_browser.step.dependOn(browser_preflight_step);
    const ocapnviz_live_browser_step = b.step("ocapnviz-live-browser", "Build and prove production ocapnviz Live mode in Chromium (needs deno + Playwright Chromium)");
    ocapnviz_live_browser_step.dependOn(&ocapnviz_live_browser.step);

    // The website's copy is the app's own production build, written where the
    // site serves static files. The build names every file relative to its
    // entry document, so the bytes proved at one directory serve at another.
    // It runs no check of its own: the pages workflow deploys only a commit
    // whose full `check` passed, and a site edit does not wait on this app's
    // formatter.
    const site_page = execution.addSystemCommand(b, .build_tool, &.{ "deno", "task", "build", "--outDir=../../site/assets/ocapnviz", "--emptyOutDir" });
    site_page.setCwd(b.path("apps/ocapnviz"));
    site_page.has_side_effects = true;
    site_page.step.dependOn(wasm_driver_install_step);
    b.step("site-ocapnviz-page", "Build ocapnviz into site/assets/ocapnviz, where the site and its preview serve it at /ocapnviz/ (needs deno)")
        .dependOn(&site_page.step);
    return .{ .site_page = &site_page.step };
}
