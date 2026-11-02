//! Static and shared archive installation: install-if-changed, the shared
//! archive's soname and linker settings, and the artifact-shape checks every
//! installed archive answers to (exported symbols, TLS size, residency).

const std = @import("std");
const commands = @import("commands.zig");
const execution = @import("execution.zig");

/// The static and shared installs of one archive, with the install steps
/// consumers and artifact-shape checks depend on.
pub const InstalledArchive = struct {
    static: *std.Build.Step.Compile,
    static_install: *std.Build.Step,
    dynamic: *std.Build.Step.Compile,
    dynamic_install: *std.Build.Step,
};

var install_if_changed: ?*std.Build.Step.Compile = null;

/// The program behind `installIfChanged`, compiled once per graph and shared
/// with its unit tests.
pub fn installIfChangedExe(b: *std.Build) *std.Build.Step.Compile {
    if (install_if_changed) |exe| return exe;
    const exe = b.addExecutable(.{ .name = "install-if-changed", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/build/install_if_changed.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    install_if_changed = exe;
    return exe;
}

/// The install prefix's library directory, where `installIfChanged` puts the
/// archives host builds link.
pub const install_lib_dir: std.Build.LazyPath = .{ .relative = .{ .base = .install_lib } };

/// Install a library into `dir` under the install prefix, replacing the file
/// only when its bytes change (`tools/build/install_if_changed.zig` says why).
/// A shared library also gets the soname links the stock install step makes.
pub fn installIfChanged(b: *std.Build, artifact: *std.Build.Step.Compile, dir: std.Build.LazyPath) *std.Build.Step {
    const run = execution.addArtifact(b, .build_tool, installIfChangedExe(b));
    run.setName(b.fmt("install {s} ({s})", .{ artifact.name, if (artifact.isDynamicLibrary()) "shared" else "static" }));
    run.addFileArg(artifact.getEmittedBin());
    run.addDirectoryArg(dir);
    const target = artifact.rootModuleTarget();
    if (artifact.isDynamicLibrary() and std.Build.wantSharedLibSymLinks(target)) {
        const major = artifact.version.?.major;
        if (target.os.tag.isDarwin()) {
            run.addArgs(&.{ b.fmt("lib{s}.{d}.dylib", .{ artifact.name, major }), b.fmt("lib{s}.dylib", .{artifact.name}) });
        } else {
            run.addArgs(&.{ b.fmt("lib{s}.so.{d}", .{ artifact.name, major }), b.fmt("lib{s}.so", .{artifact.name}) });
        }
    }
    // The destination is the state this step owns, and only the program can
    // see whether it already holds the bytes, so it runs on every build.
    run.has_side_effects = true;
    return &run.step;
}

/// Shared archives use their ABI major as the runtime identity. ELF export
/// visibility and version scripts require LLVM/lld; Zig's non-LLVM x86 backend
/// leaks hidden exports and does not enforce version scripts.
pub fn configureSharedArchive(artifact: *std.Build.Step.Compile) void {
    const target = artifact.root_module.resolved_target.?.result;
    if (target.os.tag == .macos) {
        const version = artifact.version orelse return;
        artifact.install_name = artifact.step.owner.fmt("@rpath/lib{s}.{d}.dylib", .{ artifact.name, version.major });
    } else if (target.ofmt == .elf) {
        artifact.use_llvm = true;
        artifact.use_lld = true;
    }
}

/// Build and install one archive in both static (`.a`) and shared (`.so`) form
/// from `root_module`, stamping the shared library's soname with `version` so a
/// distro can express the ABI contract. Returns both artifacts and the shared
/// install step so consumers and artifact-shape checks depend on the exact
/// form they use.
pub fn installArchive(
    b: *std.Build,
    name: []const u8,
    root_module: *std.Build.Module,
    version: std.SemanticVersion,
) InstalledArchive {
    const static_lib = b.addLibrary(.{ .name = name, .linkage = .static, .root_module = root_module });
    // Foreign linkers do not supply Zig's stack probes and compiler builtins.
    // Each shipped archive owns the runtime its generated code needs.
    static_lib.bundle_compiler_rt = true;
    const static_install = installIfChanged(b, static_lib, install_lib_dir);
    checkArchiveSymbols(b, static_lib, static_install, name);
    b.getInstallStep().dependOn(static_install);
    const shared_lib = b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .root_module = root_module,
        .version = version,
    });
    configureSharedArchive(shared_lib);
    const dynamic_install = installIfChanged(b, shared_lib, install_lib_dir);
    checkArchiveTls(b, shared_lib, dynamic_install);
    checkArchiveResident(b, shared_lib, dynamic_install);
    checkArchiveSymbols(b, shared_lib, dynamic_install, name);
    b.getInstallStep().dependOn(dynamic_install);
    return .{
        .static = static_lib,
        .static_install = static_install,
        .dynamic = shared_lib,
        .dynamic_install = dynamic_install,
    };
}

/// Exact C-family ownership for ELF archives consumed by foreign linkers.
/// Reflection supplies declarations, artifact inspection catches incidental
/// exports pulled into companions by implementation imports.
fn checkArchiveSymbols(b: *std.Build, artifact: *std.Build.Step.Compile, install: *std.Build.Step, name: []const u8) void {
    if (artifact.root_module.resolved_target.?.result.ofmt != .elf) return;
    const check = commands.addRootedSystemCommand(b, .{ .deterministic = 15 }, &.{ "python3", "tools/check/archive_symbols.py" });
    check.addFileArg(artifact.getEmittedBin());
    check.addFileArg(b.path(b.fmt("include/{s}.h", .{name})));
    install.dependOn(&check.step);
}

/// ELF TLS consumes storage on host-created pthread stacks. Keep each ABI
/// artifact small enough to compose with its siblings in an ordinary worker.
pub fn checkArchiveTls(b: *std.Build, artifact: *std.Build.Step.Compile, install: *std.Build.Step) void {
    if (artifact.root_module.resolved_target.?.result.ofmt != .elf) return;
    const check = commands.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/abi_tls.py" });
    check.addFileArg(artifact.getEmittedBin());
    install.dependOn(&check.step);
}

/// A libc-linked shared archive declares itself resident for the process
/// lifetime (`src/c_abi/shared/archive_pin.zig`). Hold the installed artifact
/// to it where the build host can load it: load, close, and ask the loader
/// whether it is still mapped.
pub fn checkArchiveResident(b: *std.Build, artifact: *std.Build.Step.Compile, install: *std.Build.Step) void {
    if (artifact.root_module.link_libc != true) return;
    const target = artifact.root_module.resolved_target.?.result;
    const host = b.graph.host.result;
    if (target.ofmt != .elf or target.os.tag != host.os.tag or target.cpu.arch != host.cpu.arch) return;
    const check = commands.addRootedSystemCommand(b, .{ .deterministic = 15 }, &.{ "python3", "tools/check/archive_resident.py" });
    check.addFileArg(artifact.getEmittedBin());
    install.dependOn(&check.step);
}
