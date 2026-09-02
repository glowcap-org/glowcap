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
    const run = execution.addSystemCommand(b, posture, argv);
    run.setCwd(b.path("."));
    return run;
}

/// Absolute path under the repository root, for environment variables passed
/// to subprocesses that cannot consume a `LazyPath`.
pub fn rootPath(b: *std.Build, sub_path: []const u8) []const u8 {
    return b.root.joinString(b.allocator, sub_path) catch @panic("OOM");
}

pub const AbiImport = struct { name: []const u8, module: *std.Build.Module };

/// A module over a transport's public C ABI root (`src/c_abi/net_transport/<transport>/mod.zig`),
/// the generalization of the iroh companion (ADR-0055) to every transport
/// archive (ADR-0059). Minted fresh per call so the artifact, the hermetic check
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

/// Link one Rust sidecar staticlib into `mod`, plus the native runtime its
/// panic machinery and its crates' platform bindings need.
///
/// Both sidecars share this recipe because they share the problem: a Rust
/// staticlib does not carry its own native link directives into Zig's final
/// link, so every library the Rust side reaches for has to be named here. The
/// Apple frameworks cover networking, TLS, and interface discovery, which both
/// sidecars do; naming them once keeps the two from drifting into "one
/// platform works and the other does not". The artifact consuming `mod` must
/// `archive` is the staticlib as a build-graph path, so an artifact that links
/// it depends on the cargo step that writes it without naming that step.
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
        // Derived from the crates' own link requirements and not exercised by
        // any check step: nothing links these on Darwin in CI, so the first
        // Mac to build a sidecar is the check. A missing one surfaces as an
        // undefined-symbol error from `zig build iroh-interop` or
        // `webrtc-interop`; add it here.
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

/// The iroh sidecar (ADR-0055): the drivers and bench, the public C ABI
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
    dynamic: *std.Build.Step.Compile,
    dynamic_install: *std.Build.Step.InstallArtifact,
};

pub fn installArchive(
    b: *std.Build,
    name: []const u8,
    root_module: *std.Build.Module,
    version: std.SemanticVersion,
) InstalledArchive {
    const static_lib = b.addLibrary(.{ .name = name, .linkage = .static, .root_module = root_module });
    b.installArtifact(static_lib);
    const shared_lib = b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .root_module = root_module,
        .version = version,
    });
    const dynamic_install = b.addInstallArtifact(shared_lib, .{});
    b.getInstallStep().dependOn(&dynamic_install.step);
    return .{
        .static = static_lib,
        .dynamic = shared_lib,
        .dynamic_install = dynamic_install,
    };
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
