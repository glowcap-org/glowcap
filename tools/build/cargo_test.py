"""tools/build/cargo.zig: the Rust sidecar link recipe, pointed at a chosen SDK.

Copies the recipe into a temporary build and links an executable for aarch64
macOS against an empty SDK named by `SDKROOT`. The link fails, and the linker
reports where it searched. Those paths show the recipe gave it the SDK's
library and framework directories, which a check of shell arguments cannot.
"""

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RECIPE = ("archives.zig", "cargo.zig", "commands.zig", "execution.zig", "shard.zig")


class SidecarLink(unittest.TestCase):
    def test_transport_linker_searches_the_selected_sdk(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            sdk = directory / "SDK with spaces"
            (sdk / "usr/lib").mkdir(parents=True)
            (sdk / "System/Library/Frameworks").mkdir(parents=True)
            for name in RECIPE:
                (directory / name).write_bytes((ROOT / "tools/build" / name).read_bytes())
            (directory / "sidecar.a").write_bytes(b"!<arch>\n")
            (directory / "main.zig").write_text("pub fn main() void {}\n")
            (directory / "build.zig").write_text(
                textwrap.dedent("""\
                const std = @import("std");
                const cargo = @import("cargo.zig");
                pub fn build(b: *std.Build) void {
                    const target = b.resolveTargetQuery(.{
                        .cpu_arch = .aarch64, .os_tag = .macos,
                        .os_version_min = .{ .semver = .{ .major = 15, .minor = 0, .patch = 0 } },
                    });
                    const module = b.createModule(.{
                        .root_source_file = b.path("main.zig"),
                        .target = target, .optimize = .Debug,
                    });
                    cargo.linkRustSidecar(b, module, target, b.path("sidecar.a"));
                    b.installArtifact(b.addExecutable(.{ .name = "probe", .root_module = module }));
                }
                """)
            )
            result = subprocess.run(
                ["zig", "build", "--cache-dir", str(directory / "cache")],
                cwd=directory,
                env=dict(os.environ, SDKROOT=str(sdk)),
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertNotEqual(result.returncode, 0, "the empty SDK must refuse linking")
            self.assertIn(str(sdk / "usr/lib/libobjc"), result.stderr)
            self.assertIn(str(sdk / "System/Library/Frameworks/Foundation.framework"), result.stderr)
            self.assertNotIn("searched paths: none", result.stderr)


if __name__ == "__main__":
    unittest.main()
