//! Host product and C SDK release profiles share staging, target guards, and
//! checksummed archives. Product proofs run only extracted public commands.
const std = @import("std");
const common = @import("common.zig");
const execution = @import("execution.zig");
const staging = @import("release/stage.zig");
const transaction = @import("release/transaction.zig");
pub const Manifest = staging.Manifest;

pub fn register(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, version: std.SemanticVersion, iroh_abi_step: *std.Build.Step, check_step: *std.Build.Step, manifest: Manifest) void {
    productPreset(b, target);
    const manifest_tests = staging.addManifestTests(b);
    check_step.dependOn(&manifest_tests.step);
    b.step("product-manifest-test", "Generate and parse a sealed staged product without a release package build")
        .dependOn(&manifest_tests.step);
    const tests = common.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/glowcap_release_test.py" });
    tests.addArg(archive_script);
    const test_step = b.step("glowcap-package-test", "Prove release rollback and reject damaged packages, broken skills, and loader fallbacks");
    test_step.dependOn(&tests.step);
    check_step.dependOn(test_step);

    const sdk = staging.add(b, target, version, "sdk", manifest);
    sdk.step.dependOn(iroh_abi_step);
    const sdk_archive = archive(b, target, version, "glowcap-c", "sdk", "release");
    sdk_archive.run.step.dependOn(&sdk.step);
    const sdk_proof = common.addRootedSystemCommand(b, .build_tool, &.{ "bash", "tools/check/release-pack-smoke.sh" });
    sdk_proof.addFileArg(sdk_archive.path);
    sdk_proof.addArgs(&.{ staging.join(b, manifest.static_archives), staging.join(b, manifest.dynamic_archives), staging.join(b, manifest.headers) });
    sdk_proof.step.dependOn(&sdk_archive.run.step);
    gate(b, target, optimize, b.step("release-pack", "Package and verify the C SDK (explicit Release mode and baseline CPU required)"), &sdk_proof.step);

    const product_archive = archive(b, target, version, "glowcap", "product", "glowcap-release");
    product_archive.run.step.dependOn(&b.top_level_steps.get("rooms-build").?.step);
    // A finite sequence of release operations; every child command and
    // readiness wait owns its deadline rather than sharing one 30s timer.
    const proof = common.addRootedSystemCommand(b, .child_bounded, &.{ "python3", "tools/check/glowcap_release.py" });
    proof.addFileArg(product_archive.path);
    proof.step.dependOn(&product_archive.run.step);
    proof.step.dependOn(test_step);
    gate(b, target, optimize, b.step("glowcap-pack", "Package and exercise the complete relocatable glowcap product (explicit Release mode and baseline CPU required)"), &proof.step);
}

fn productPreset(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const step = b.step("rooms-release", "Prepare the complete host product with ReleaseSafe and baseline CPU settings for installation or Linux deployment");
    if (hostTargetFailure(b, target)) |reason| {
        step.dependOn(&b.addFail(reason).step);
        return;
    }
    // Build options apply to the whole graph. Invoke the shared product graph
    // in its fixed configuration, preserving the caller's target, prefix, and
    // cache root. The environment front owns the lease across both builds.
    const run = execution.addSystemCommand(b, .build_tool, &.{
        b.graph.zig_exe, "build", "rooms-build", "-Doptimize=ReleaseSafe", "-Dcpu=baseline", "--cache-dir",
    });
    run.addDirectoryArg2(std.Build.LazyPath.cache_root, .{ .make_absolute = true });
    run.addArg("--prefix");
    run.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix } }, .{ .make_absolute = true });
    run.addArg(b.fmt("-Dtarget={s}", .{target.query.zigTriple(b.allocator) catch @panic("OOM")}));
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    step.dependOn(&run.step);
}

fn hostTargetFailure(b: *std.Build, target: std.Build.ResolvedTarget) ?[]const u8 {
    if (target.result.os.tag != b.graph.host.result.os.tag or target.result.cpu.arch != b.graph.host.result.cpu.arch or target.result.abi != b.graph.host.result.abi)
        return "host products must be built on their target OS and architecture; use the Linux/macOS release matrix, not a mixed Zig/Cargo cross-build";
    if (target.result.os.tag == .linux and target.result.os.version_range.linux.glibc.order(b.graph.host.result.os.version_range.linux.glibc) == .lt)
        return "Rust runtimes use the build host's libc; build on the chosen Linux baseline instead of labeling host artifacts with an older glibc target";
    return null;
}

fn gate(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, step: *std.Build.Step, proof: *std.Build.Step) void {
    if (optimize == .debug) {
        step.dependOn(&b.addFail("release packages refuse Debug; pass -Doptimize=ReleaseSafe").step);
    } else if (hostTargetFailure(b, target)) |reason| {
        step.dependOn(&b.addFail(reason).step);
    } else if (!target.query.cpu_model.eql(.baseline) or !target.query.cpu_features_add.isEmpty()) {
        step.dependOn(&b.addFail("release packages require -Dcpu=baseline without added CPU features").step);
    } else {
        step.dependOn(proof);
    }
}

const archive_script = transaction.begin ++
    \\source="$2"
    \\name="$3"
    \\marker=SHA256SUMS
    \\LC_ALL=C TAR_OPTIONS= COPYFILE_DISABLE=1 tar -czf "$stage/tree/$name" -C "$source" bin lib libexec include share README.md PROVENANCE.md LICENSE-APACHE LICENSE-THIRD-PARTY
    \\(cd "$stage/tree"; if command -v sha256sum >/dev/null 2>&1; then sha256sum "$name"; else shasum -a 256 "$name"; fi) > "$stage/tree/SHA256SUMS"
    \\
++ transaction.commit ++
    \\echo "release-pack: $output/$name"
;

fn archive(b: *std.Build, target: std.Build.ResolvedTarget, version: std.SemanticVersion, name: []const u8, source: []const u8, output: []const u8) struct { run: *std.Build.Step.Run, path: std.Build.LazyPath } {
    const filename = b.fmt("{s}-v{d}.{d}.{d}-{s}-{s}.tar.gz", .{ name, version.major, version.minor, version.patch, @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) });
    const run = common.addInstalledSystemRun(b, .build_tool, &.{ "sh", "-ec", archive_script, "glowcap-archive" });
    run.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = output } }, .{ .make_absolute = true });
    run.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = source } }, .{ .make_absolute = true });
    run.addArg(filename);
    return .{ .run = run, .path = .{ .relative = .{ .base = .install_prefix, .sub_path = b.fmt("{s}/{s}", .{ output, filename }) } } };
}
