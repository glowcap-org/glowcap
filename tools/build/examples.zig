//! The runnable examples: the numbered Zig CapTP chapters, the README
//! quick-start, the library-mechanics walkthroughs, and the C examples over
//! the per-archive headers — all built and run under `check`, so a public
//! example cannot stop compiling quietly.

const std = @import("std");
const common = @import("common.zig");
const execution = @import("execution.zig");

const pancakeExecutable = common.pancakeExecutable;

pub fn register(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
    check_step: *std.Build.Step,
    ocapn_static: *std.Build.Step.Compile,
    host_static: *std.Build.Step.Compile,
) void {
    // ── Examples ─────────────────────────────────────────────────────────────
    const examples_step = b.step("examples", "Build and run examples");
    check_step.dependOn(examples_step);

    // Zig example programs, run in array order. The numbered chapters are
    // runnable CapTP walkthroughs whose narrative lives in their `//!` headers,
    // so the prose and the API calls can't drift (each is built and run under
    // `check`); they read top-down, from the application surface to the raw
    // engine. `readme_quick_start` keeps the README's Quick Start snippet
    // compiling. `frame_view`, `connect_explicit_buffers`, and
    // `many_sessions_one_loop` are the lower-level library-mechanics
    // walkthroughs.
    const zig_examples = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "pancake-ex-01-connect-and-serve", .path = "examples/zig/01_connect_and_serve.zig" },
        .{ .name = "pancake-ex-02-introduce-and-redeem", .path = "examples/zig/02_introduce_and_redeem.zig" },
        .{ .name = "pancake-ex-03-actor-far-send", .path = "examples/zig/03_actor_far_send.zig" },
        .{ .name = "pancake-ex-04-look-up-by-name", .path = "examples/zig/04_look_up_by_name.zig" },
        .{ .name = "pancake-ex-05-call-a-remote-method", .path = "examples/zig/05_call_a_remote_method.zig" },
        .{ .name = "pancake-ex-06-pipeline-and-attenuate", .path = "examples/zig/06_pipeline_and_attenuate.zig" },
        .{ .name = "pancake-readme-quick-start", .path = "examples/zig/readme_quick_start.zig" },
        .{ .name = "pancake-dev-frame-view", .path = "examples/zig/frame_view.zig" },
        .{ .name = "pancake-dev-connect-explicit-buffers", .path = "examples/zig/connect_explicit_buffers.zig" },
        .{ .name = "pancake-dev-many-sessions-one-loop", .path = "examples/zig/many_sessions_one_loop.zig" },
    };
    for (zig_examples) |ex| {
        const run = execution.addArtifact(b, .{ .deterministic = 30 }, pancakeExecutable(b, lib_mod, target, optimize, ex.name, ex.path));
        examples_step.dependOn(&run.step);
    }

    // C example programs over the per-archive headers, each linking exactly the
    // composed archive set it includes, the same à-la-carte link the documented
    // recipe gives a C consumer (ADR-0059).
    const c_examples = [_]struct { name: []const u8, path: []const u8, libs: []const *std.Build.Step.Compile }{
        .{ .name = "pancake-c-frame-view", .path = "examples/c/frame_view.c", .libs = &.{ocapn_static} },
        .{ .name = "pancake-c-host-embedder-pump", .path = "examples/c/host_embedder_pump.c", .libs = &.{ ocapn_static, host_static } },
    };
    for (c_examples) |ex| {
        const c_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
        });
        c_mod.addCSourceFile(.{ .file = b.path(ex.path) });
        c_mod.addIncludePath(b.path("include"));
        for (ex.libs) |lib| c_mod.linkLibrary(lib);
        c_mod.link_libc = true;
        const c_exe = b.addExecutable(.{ .name = ex.name, .root_module = c_mod });
        examples_step.dependOn(&execution.addArtifact(b, .{ .deterministic = 30 }, c_exe).step);
    }
}
