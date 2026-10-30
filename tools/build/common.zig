const std = @import("std");
const execution = @import("execution.zig");

/// Build one executable over the public `glowcap` module.
pub fn glowcapExecutable(
    b: *std.Build,
    lib_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root_source: []const u8,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(root_source),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("glowcap", lib_mod);
    return b.addExecutable(.{ .name = name, .root_module = module });
}

/// Run a glowcap executable from the repository root with side effects.
pub fn addGlowcapRun(
    b: *std.Build,
    posture: execution.Posture,
    lib_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root_source: []const u8,
) *std.Build.Step.Run {
    const run = execution.addArtifact(b, posture, glowcapExecutable(
        b,
        lib_mod,
        target,
        optimize,
        name,
        root_source,
    ));
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    return run;
}

/// Run a system command from the repository root.
pub fn addRootedSystemCommand(
    b: *std.Build,
    posture: execution.Posture,
    argv: []const []const u8,
) *std.Build.Step.Run {
    return addSystemCommandIn(b, posture, b.path("."), argv);
}

/// Run a system command from `cwd`. A run under a process deadline gets its
/// launcher's compile as a prior build step from the same directory
/// (`addCompilePreps`).
pub fn addSystemCommandIn(
    b: *std.Build,
    posture: execution.Posture,
    cwd: std.Build.LazyPath,
    argv: []const []const u8,
) *std.Build.Step.Run {
    const run = execution.addSystemCommand(b, posture, argv);
    run.setCwd(cwd);
    switch (posture) {
        .deterministic, .browser_proof => addCompilePreps(b, cwd, argv, run),
        else => {},
    }
    return run;
}

/// Keep a launcher's own compile out of a bounded run, so the deadline times
/// the program and not a cold toolchain: `cargo run|test` builds first,
/// `deno test` type-checks with `--no-run`, a Deno entry point is cached, and
/// a Racket module is compiled with `raco make`. The run's argv stays the one
/// authority, and the scenario never executes twice. Each prep shares the run's
/// environment map, so a variable the caller sets on the run later reaches the
/// prep too, and Cargo never sees a tracked variable change between them.
fn addCompilePreps(b: *std.Build, cwd: std.Build.LazyPath, argv: []const []const u8, run: *std.Build.Step.Run) void {
    var deno_test = false;
    for (1..argv.len) |at| {
        const word = argv[at - 1];
        const next = argv[at];
        const prep_argv: []const []const u8 = if (std.mem.eql(u8, word, "cargo") and std.mem.eql(u8, next, "run"))
            &.{ "cargo", "build" }
        else if (std.mem.eql(u8, word, "cargo") and std.mem.eql(u8, next, "test"))
            &.{ "cargo", "test", "--no-run" }
        else if (std.mem.eql(u8, word, "deno") and std.mem.eql(u8, next, "test"))
            &.{ "deno", "test", "--no-run" }
        else
            continue;
        const prep = addSystemCommandIn(b, .build_tool, cwd, prep_argv);
        prep.environ_map = run.getEnvMap();
        // Cargo links the installed C ABI archives.
        if (std.mem.eql(u8, word, "cargo")) prep.step.dependOn(b.getInstallStep());
        if (std.mem.eql(u8, word, "deno")) deno_test = true;
        for (argv[at + 1 ..]) |arg| {
            if (std.mem.eql(u8, arg, "--")) break;
            prep.addArg(arg);
        }
        run.step.dependOn(&prep.step);
    }
    var deno_cache: ?*std.Build.Step.Run = null;
    var raco_make: ?*std.Build.Step.Run = null;
    for (argv) |arg| {
        if (arg.len == 0 or arg[0] == '-') continue;
        const prep = if (!deno_test and std.mem.endsWith(u8, arg, ".ts"))
            &deno_cache
        else if (std.mem.endsWith(u8, arg, ".rkt"))
            &raco_make
        else
            continue;
        if (prep.* == null) {
            prep.* = addSystemCommandIn(b, .build_tool, cwd, if (prep == &deno_cache) &.{ "deno", "cache" } else &.{ "raco", "make" });
            prep.*.?.environ_map = run.getEnvMap();
            run.step.dependOn(&prep.*.?.step);
        }
        prep.*.?.addArg(arg);
    }
}

/// Check one Rust crate's formatting without writing. A crate's test step
/// depends on this, so the tree that edits the crate learns about an
/// unformatted file instead of the next tree to run `bindings-fmt-check`.
/// `--all` reaches every member of a workspace manifest.
pub fn rustFmtCheck(b: *std.Build, manifest: []const u8) *std.Build.Step.Run {
    return addRootedSystemCommand(b, .build_tool, &.{ "cargo", "fmt", "--all", "--check", "--manifest-path", manifest });
}

/// Absolute path under the repository root, for environment variables passed
/// to subprocesses that cannot consume a `LazyPath`.
pub fn rootPath(b: *std.Build, sub_path: []const u8) []const u8 {
    return b.root.joinString(b.allocator, sub_path) catch @panic("OOM");
}

pub const RustSidecar = struct {
    build: *std.Build.Step.Run,
    target_dir: std.Build.LazyPath,
    archive: std.Build.LazyPath,
};

/// Cargo owns incremental compilation; its stable output directory is a graph
/// path, so linking a published transport builds its sidecar on demand.
pub fn rustSidecar(b: *std.Build, manifest: []const u8, library: []const u8) RustSidecar {
    const run = addRootedSystemCommand(b, .build_tool, &.{
        "cargo", "build", "--locked", "--release", "--manifest-path", manifest,
    });
    const target_dir = run.addPrefixedOutputDirectoryArg("--target-dir=", "target");
    run.has_side_effects = true;
    return .{
        .build = run,
        .target_dir = target_dir,
        .archive = target_dir.path(b, b.fmt("release/lib{s}.a", .{library})),
    };
}

pub const AbiImport = struct { name: []const u8, module: *std.Build.Module };

/// A module over a transport's public C ABI root (`src/c_abi/net_transport/<transport>/mod.zig`),
/// the generalization of the iroh companion (ADR-0021) to every transport
/// archive (ADR-0022). Minted fresh per call so the artifact, the hermetic check
/// object, and the header generator can each have their own (no source file
/// lands in two modules of one compilation). `imports` supplies the layer
/// instances the transport draws on, always the shared vocabulary leaf
/// (`c_abi_shared`), never the `c_abi` ocapn root, so the artifact stays
/// symbol-disjoint from `libglowcap_ocapn`. These are the `.graph = false`
/// `c_abi_*` rows' only materialization: they sit outside the layer DAG because
/// a transport's injected sidecar resident is not a DAG edge.
pub fn transportAbiModule(
    b: *std.Build,
    t: std.Build.ResolvedTarget,
    o: std.builtin.OptimizeMode,
    root_source: []const u8,
    imports: []const AbiImport,
) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path(root_source),
        .target = t,
        .optimize = o,
        .pic = true,
    });
    for (imports) |imp| m.addImport(imp.name, imp.module);
    return m;
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
    _ = b;
    mod.addObjectFile(archive);
    mod.link_libc = true;
    mod.linkSystemLibrary("unwind", .{});
    if (target.result.os.tag.isDarwin()) {
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
/// (`transports/sidecar-common`): the private-runtime owner, the task barrier,
/// and the readiness channel. A sidecar's `cargo test` builds the crate but
/// never runs its tests, so the crate has its own step, a cargo-requiring
/// sibling of `check` like `iroh-sidecar-test` and `webrtc-sidecar-test`.
/// `--locked` makes its committed lockfile authoritative.
pub fn registerSidecarCommon(b: *std.Build) void {
    const test_run = addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{
        "cargo", "test", "--locked", "--release", "--manifest-path", "transports/sidecar-common/Cargo.toml",
    });
    const test_compile = addRootedSystemCommand(b, .build_tool, &.{
        "cargo", "test", "--locked", "--no-run", "--release", "--manifest-path", "transports/sidecar-common/Cargo.toml",
    });
    test_run.step.dependOn(&test_compile.step);
    b.step("sidecar-common-test", "Run the Rust unit tests of the runtime plumbing both transport sidecars share: private-runtime calls from inside an ambient runtime and the task barrier (needs cargo)").dependOn(&test_run.step);
}

/// Compile one `site/examples/` Zig snippet as a checked claim. The snippet
/// becomes a module rooted by `tools/check/site_example_root.zig`, whose
/// header says why compiling the snippet file alone would read nothing.
/// `imports` are the modules the snippet names, `glowcap` included.
pub fn addSiteZigExampleCompile(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    path: []const u8,
    imports: []const std.Build.Module.Import,
    check: *std.Build.Step,
) void {
    const snippet_mod = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    const root_mod = b.createModule(.{
        .root_source_file = b.path("tools/check/site_example_root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "snippet", .module = snippet_mod }},
    });
    const object = b.addObject(.{
        .name = b.fmt("{s}-compile", .{name}),
        .root_module = root_mod,
    });
    check.dependOn(&object.step);
}

/// A sibling-step system command that needs the installed archive set and its
/// headers and runs from the repository root with side effects, the shape
/// every cross-language interop and demo orchestrator shares.
pub fn addInstalledSystemRun(b: *std.Build, posture: execution.Posture, argv: []const []const u8) *std.Build.Step.Run {
    const run = addRootedSystemCommand(b, posture, argv);
    run.step.dependOn(b.getInstallStep());
    run.has_side_effects = true;
    return run;
}

/// Resolve `-Dtarget`/`-Dcpu` with the baseline CPU as the default, the one
/// releases ship, and build every host tool for it too. Selecting the host's
/// CPU keys each compile on the model of whichever core ran the build process, so
/// heterogeneous cores and the separate machines of CI build and test jobs
/// each miss the others' cache. Call it first in `build`, before any
/// dependency configures, so their generators use the same host. Measure the
/// host with -Dcpu=native.
pub fn baselineTarget(b: *std.Build) std.Build.ResolvedTarget {
    b.graph.host = b.resolveTargetQuery(.{ .cpu_model = .baseline });
    return b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
}

/// The iroh sidecar (ADR-0021): the drivers and bench, the public C ABI
/// companion, the iroh-enabled rooms client, and the published `glowcap_iroh`
/// module all link it through the shared `linkRustSidecar` recipe.
/// `archive` is the staticlib the iroh family's cargo step emits.
pub fn linkIrohSidecar(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    archive: std.Build.LazyPath,
) void {
    linkRustSidecar(b, mod, target, archive);
}

/// A fresh module over an iroh driver root with the `glowcap` and injected
/// `iroh` resident imports, the shape the iroh drivers, the iroh bench, and the
/// iroh-enabled rooms client share. Minted per call so the hermetic
/// compile-only object and the sidecar-linked executable can each root their
/// own (no source file lands in two modules of one compilation). The caller
/// adds `linkIrohSidecar` for a runnable artifact and leaves it off for the
/// hermetic object, whose externs stay unresolved.
pub fn irohDriverModule(
    b: *std.Build,
    t: std.Build.ResolvedTarget,
    o: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
    resident: *std.Build.Module,
    root_source: []const u8,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root_source),
        .target = t,
        .optimize = o,
    });
    mod.addImport("glowcap", lib_mod);
    mod.addImport("iroh", resident);
    return mod;
}

/// Build and install one archive in both static (`.a`) and shared (`.so`) form
/// from `root_module`, stamping the shared library's soname with `version` so a
/// distro can express the ABI contract. Returns both artifacts and the shared
/// install step so consumers and artifact-shape checks depend on the exact
/// form they use.
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

/// ELF export visibility and version scripts require LLVM/lld. Zig's non-LLVM
/// x86 backend leaks hidden exports and does not enforce version scripts.
pub fn configureSharedArchive(artifact: *std.Build.Step.Compile) void {
    if (artifact.root_module.resolved_target.?.result.ofmt != .elf) return;
    artifact.use_llvm = true;
    artifact.use_lld = true;
}

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
    const check = addRootedSystemCommand(b, .{ .deterministic = 15 }, &.{ "python3", "tools/check/archive_symbols.py" });
    check.addFileArg(artifact.getEmittedBin());
    check.addFileArg(b.path(b.fmt("include/{s}.h", .{name})));
    install.dependOn(&check.step);
}

/// ELF TLS consumes storage on host-created pthread stacks. Keep each ABI
/// artifact small enough to compose with its siblings in an ordinary worker.
pub fn checkArchiveTls(b: *std.Build, artifact: *std.Build.Step.Compile, install: *std.Build.Step) void {
    if (artifact.root_module.resolved_target.?.result.ofmt != .elf) return;
    const check = addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/abi_tls.py" });
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
    const check = addRootedSystemCommand(b, .{ .deterministic = 15 }, &.{ "python3", "tools/check/archive_resident.py" });
    check.addFileArg(artifact.getEmittedBin());
    install.dependOn(&check.step);
}

/// The shared Zig interop-driver harness (`interop/_common/zig/harness.zig`),
/// imported as `interop_harness` by every Zig interop executable. Scaffolding
/// like `test/support`, so it sits outside the `src/` layer DAG. The wait
/// vocabulary is `test/support/wait.zig` itself, handed in as `support_wait`
/// so the two scaffolding trees share one owner instead of hand-synced copies.
pub fn interopHarnessModule(
    b: *std.Build,
    t: std.Build.ResolvedTarget,
    o: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
) *std.Build.Module {
    const wait_mod = b.createModule(.{
        .root_source_file = b.path("test/support/wait.zig"),
        .target = t,
        .optimize = o,
    });
    const mod = b.createModule(.{
        .root_source_file = b.path("interop/_common/zig/harness.zig"),
        .target = t,
        .optimize = o,
    });
    mod.addImport("glowcap", lib_mod);
    mod.addImport("support_wait", wait_mod);
    return mod;
}
