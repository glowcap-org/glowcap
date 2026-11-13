//! Cargo crates in the Zig build graph: the formatting check, the sidecar
//! staticlib build, the link recipe that joins it to a Zig module, and the
//! sidecar-runtime crate's test step.

const std = @import("std");
const archives = @import("archives.zig");
const commands = @import("commands.zig");
const execution = @import("execution.zig");

/// Check one Rust crate's formatting without writing. A crate's test step
/// depends on this, so the tree that edits the crate learns about an
/// unformatted file instead of the next tree to run `bindings-fmt-check`.
/// `--all` reaches every member of a workspace manifest.
pub fn rustFmtCheck(b: *std.Build, manifest: []const u8) *std.Build.Step.Run {
    return commands.addRootedSystemCommand(b, .build_tool, &.{ "cargo", "fmt", "--all", "--check", "--manifest-path", manifest });
}

pub const RustSidecar = struct {
    /// The cargo build. Flags such as `--features` go here.
    build: *std.Build.Step.Run,
    /// Cargo's target directory, for the binaries it builds beside the archive.
    target_dir: std.Build.LazyPath,
    /// The staticlib Zig links. It carries the step that installs it, so a
    /// module that links it needs no further dependency.
    archive: std.Build.LazyPath,
};

/// Cargo owns incremental compilation. Its stable output directory is a graph
/// path, so linking a published transport builds its sidecar on demand. Cargo
/// also replaces the uplifted `release/lib<name>.a` on every build, and where
/// it cannot hard-link (the CI stores are separate mounts) the copy is a new
/// inode with a new mtime, which Zig takes as a changed link input and
/// relinks every consumer. `archive` is that file installed by
/// `tools/build/install_if_changed.zig`, rewritten only when its bytes change.
pub fn rustSidecar(b: *std.Build, manifest: []const u8, library: []const u8) RustSidecar {
    const run = commands.addRootedSystemCommand(b, .build_tool, &.{
        "cargo", "build", "--locked", "--release", "--manifest-path", manifest,
    });
    const target_dir = run.addOutputDirectoryArg2("target", .{ .prefix = "--target-dir=" });
    run.has_side_effects = true;
    const name = b.fmt("lib{s}.a", .{library});
    const install = execution.addArtifact(b, .build_tool, archives.installIfChangedExe(b));
    install.setName(b.fmt("install {s} (sidecar)", .{name}));
    install.addFileArg(target_dir.path(b, b.fmt("release/{s}", .{name})));
    const lib = install.addOutputDirectoryArg2("lib", .{});
    // Only the program can see whether the destination holds the bytes.
    install.has_side_effects = true;
    return .{ .build = run, .target_dir = target_dir, .archive = lib.path(b, name) };
}

/// Link Cargo's static archive and system dependencies into a Zig module.
/// Cargo's library and framework link directives do not reach Zig. The
/// LazyPath ties linking to the Cargo build, and both backend families share
/// the system libraries.
pub fn linkRustSidecar(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    archive: std.Build.LazyPath,
) void {
    mod.addObjectFile(archive);
    mod.link_libc = true;
    mod.linkSystemLibrary("unwind", .{});
    if (target.result.os.tag.isDarwin()) {
        // Explicit deployment targets do not inherit the host's SDK search
        // paths. --sysroot alone does not supply -L or -F on this toolchain.
        if (b.graph.environ_map.get("SDKROOT")) |sdk| {
            mod.addLibraryPath(b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "usr", "lib" })));
            mod.addFrameworkPath(b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "System", "Library", "Frameworks" })));
        }
        // The macOS release builds exercise these Rust dependencies.
        inline for (&.{
            "CoreFoundation",
            "CoreWLAN",
            "Foundation",
            "Security",
            "SystemConfiguration",
        }) |framework| mod.linkFramework(framework, .{});
        mod.linkSystemLibrary("objc", .{});
    }
}

/// The runtime plumbing both Rust sidecars depend on by path
/// (`transports/sidecar-runtime`): the private-runtime owner, the task barrier,
/// and the readiness channel. A sidecar's `cargo test` builds the crate but
/// never runs its tests, so the crate has its own step, a cargo-requiring
/// sibling of `check` like `iroh-sidecar-test` and `webrtc-sidecar-test`.
/// `--locked` makes its committed lockfile authoritative.
pub fn registerSidecarRuntime(b: *std.Build) void {
    const test_run = commands.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{
        "cargo", "test", "--locked", "--release", "--manifest-path", "transports/sidecar-runtime/Cargo.toml",
    });
    const test_compile = commands.addRootedSystemCommand(b, .build_tool, &.{
        "cargo", "test", "--locked", "--no-run", "--release", "--manifest-path", "transports/sidecar-runtime/Cargo.toml",
    });
    test_run.step.dependOn(&test_compile.step);
    b.step("sidecar-runtime-test", "Run the Rust unit tests of the runtime plumbing both transport sidecars share: private-runtime calls from inside an ambient runtime and the task barrier (needs cargo)").dependOn(&test_run.step);
}
