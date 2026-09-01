//! Release packaging: the installed archive set, headers, product binaries, the
//! project provenance disclosure, and licenses staged into one versioned,
//! checksummed per-target tarball that the bindings' find leg resolves against.

const std = @import("std");
const common = @import("common.zig");

const addInstalledSystemRun = common.addInstalledSystemRun;

pub const Manifest = struct {
    static_archives: []const []const u8,
    dynamic_archives: []const []const u8,
    headers: []const []const u8,
    binaries: []const []const u8,
};

pub fn register(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    abi_version: std.SemanticVersion,
    iroh_abi_step: *std.Build.Step,
    manifest: Manifest,
) void {
    // ── release packaging ────────────────────────────────────────────────────
    // Stage the complete installed archive set — the pure-Zig archives plus the
    // iroh companion — with the headers, authorship disclosure, and licenses
    // into one versioned, checksummed tarball under `zig-out/release/`, named by
    // `abi_version` and the host target triple. `.github/workflows/release.yml`
    // runs this per platform on a version tag and attaches the tarballs to the
    // release, the hosted upstream the bindings' find leg resolves against.
    const release_tarball = b.fmt(
        "pancake-c-v{d}.{d}.{d}-{s}-{s}.tar.gz",
        .{
            abi_version.major,                abi_version.minor,              abi_version.patch,
            @tagName(target.result.cpu.arch), @tagName(target.result.os.tag),
        },
    );
    const static_archives = std.mem.join(b.allocator, " ", manifest.static_archives) catch @panic("OOM");
    const dynamic_archives = std.mem.join(b.allocator, " ", manifest.dynamic_archives) catch @panic("OOM");
    const headers = std.mem.join(b.allocator, " ", manifest.headers) catch @panic("OOM");
    const binaries = std.mem.join(b.allocator, " ", manifest.binaries) catch @panic("OOM");
    const version = b.fmt("{d}.{d}.{d}", .{ abi_version.major, abi_version.minor, abi_version.patch });
    const major = b.fmt("{d}", .{abi_version.major});
    const target_os = @tagName(target.result.os.tag);
    const release_pack_run = addInstalledSystemRun(b, .build_tool, &.{
        "sh", "-ec",
        b.fmt(
            \\rm -rf zig-out/release
            \\mkdir -p zig-out/release/stage/lib zig-out/release/stage/include zig-out/release/stage/bin
            \\for name in {s}; do
            \\  src="zig-out/lib/lib${{name}}.a"
            \\  test -f "$src" || {{ echo "release-pack: missing static archive $src" >&2; exit 1; }}
            \\  cp -L "$src" "zig-out/release/stage/lib/lib${{name}}.a"
            \\done
            \\case '{s}' in
            \\  linux) dynamic_suffixes='.so .so.{s} .so.{s}' ;;
            \\  macos) dynamic_suffixes='.dylib .{s}.dylib .{s}.dylib' ;;
            \\  *) echo 'release-pack: target OS {s} has no published dynamic-library layout' >&2; exit 1 ;;
            \\esac
            \\for name in {s}; do
            \\  for suffix in $dynamic_suffixes; do
            \\    src="zig-out/lib/lib${{name}}${{suffix}}"
            \\    test -f "$src" || {{ echo "release-pack: missing shared-library member $src" >&2; exit 1; }}
            \\    cp -L "$src" "zig-out/release/stage/lib/lib${{name}}${{suffix}}"
            \\  done
            \\done
            \\for name in {s}; do
            \\  src="include/${{name}}"
            \\  test -f "$src" || {{ echo "release-pack: missing public header $src" >&2; exit 1; }}
            \\  cp "$src" "zig-out/release/stage/include/${{name}}"
            \\done
            \\for name in {s}; do
            \\  src="zig-out/bin/${{name}}"
            \\  test -f "$src" || {{ echo "release-pack: missing product binary $src" >&2; exit 1; }}
            \\  cp "$src" "zig-out/release/stage/bin/${{name}}"
            \\done
            \\if find zig-out/release/stage ! -type d ! -type f -print | grep -q .; then
            \\  echo 'release-pack: stage must contain only regular files and directories' >&2
            \\  exit 1
            \\fi
            \\cp PROVENANCE.md LICENSE-APACHE LICENSE-THIRD-PARTY zig-out/release/stage/
            \\tar -czf 'zig-out/release/{s}' -C zig-out/release/stage lib include bin PROVENANCE.md LICENSE-APACHE LICENSE-THIRD-PARTY
            \\rm -rf zig-out/release/stage
            \\cd zig-out/release
            \\(sha256sum '{s}' || shasum -a 256 '{s}') > SHA256SUMS
            \\echo 'release-pack: zig-out/release/{s}'
        , .{
            static_archives,
            target_os,
            major,
            version,
            major,
            version,
            target_os,
            dynamic_archives,
            headers,
            binaries,
            release_tarball,
            release_tarball,
            release_tarball,
            release_tarball,
        }),
    });
    release_pack_run.step.dependOn(b.getInstallStep());
    release_pack_run.step.dependOn(iroh_abi_step);
    const release_smoke = common.addRootedSystemCommand(b, .build_tool, &.{
        "bash",
        "tools/check/release-pack-smoke.sh",
        b.fmt("zig-out/release/{s}", .{release_tarball}),
        static_archives,
        dynamic_archives,
        headers,
    });
    release_smoke.step.dependOn(&release_pack_run.step);
    const release_pack_step = b.step("release-pack", "Stage and verify optimized installed archives, headers, product binaries, provenance, and licenses in a versioned, checksummed per-target tarball under zig-out/release/ (needs cargo for the iroh companion)");
    if (optimize == .debug) {
        release_pack_step.dependOn(&b.addFail("release-pack refuses Debug artifacts; pass -Doptimize=ReleaseSafe (or another explicit Release mode)").step);
    } else {
        release_pack_step.dependOn(&release_smoke.step);
    }
}
