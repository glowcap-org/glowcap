//! Release packaging: the installed archive set, headers, product binaries,
//! and licenses staged into one versioned, checksummed per-target tarball
//! that the bindings' find leg resolves against.

const std = @import("std");
const common = @import("common.zig");

const addInstalledSystemRun = common.addInstalledSystemRun;

pub fn register(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    abi_version: std.SemanticVersion,
    iroh_abi_step: *std.Build.Step,
) void {
    // ── release packaging ────────────────────────────────────────────────────
    // Stage the complete installed archive set — the pure-Zig archives plus the
    // iroh companion — with the headers and licenses into one versioned,
    // checksummed tarball under `zig-out/release/`, named by `abi_version` and
    // the host target triple. `.github/workflows/release.yml` runs this per
    // platform on a version tag and attaches the tarballs to the release, the
    // hosted upstream the bindings' find leg resolves against.
    const release_tarball = b.fmt(
        "pancake-c-v{d}.{d}.{d}-{s}-{s}.tar.gz",
        .{
            abi_version.major,                abi_version.minor,              abi_version.patch,
            @tagName(target.result.cpu.arch), @tagName(target.result.os.tag),
        },
    );
    const release_pack_run = addInstalledSystemRun(b, .build_tool, &.{
        "sh", "-ec",
        b.fmt(
            \\rm -rf zig-out/release
            \\mkdir -p zig-out/release/stage
            \\# Dereference soname symlinks so the tarball has only regular files
            \\# (ADR-0077 extract hygiene refuses symlink members).
            \\cp -aL zig-out/lib zig-out/include zig-out/release/stage/
            \\if [ -d zig-out/bin ]; then cp -aL zig-out/bin zig-out/release/stage/; fi
            \\if find zig-out/release/stage/lib \( -type l -o -type b -o -type c \) 2>/dev/null | grep -q .; then
            \\  echo 'release-pack: lib/ must contain only regular files and directories (no symlinks/special files)' >&2
            \\  exit 1
            \\fi
            \\cp LICENSE-APACHE LICENSE-THIRD-PARTY zig-out/release/stage/
            \\tar -czf 'zig-out/release/{s}' -C zig-out/release/stage lib include bin LICENSE-APACHE LICENSE-THIRD-PARTY 2>/dev/null || tar -czf 'zig-out/release/{s}' -C zig-out/release/stage lib include LICENSE-APACHE LICENSE-THIRD-PARTY
            \\rm -rf zig-out/release/stage
            \\cd zig-out/release
            \\(sha256sum '{s}' || shasum -a 256 '{s}') > SHA256SUMS
            \\echo 'release-pack: zig-out/release/{s}'
        , .{ release_tarball, release_tarball, release_tarball, release_tarball, release_tarball }),
    });
    release_pack_run.step.dependOn(b.getInstallStep());
    release_pack_run.step.dependOn(iroh_abi_step);
    const release_pack_step = b.step("release-pack", "Stage the installed archives + headers (+ bin/pancake and rooms-peer shim) into a versioned, checksummed per-target tarball under zig-out/release/ (needs cargo for the iroh companion)");
    release_pack_step.dependOn(&release_pack_run.step);
}
