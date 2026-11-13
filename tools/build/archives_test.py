"""tools/build/archives.zig: the shared archive recipe, built for macOS.

Copies the recipe into a temporary build, links a small dynamic library for
aarch64 macOS through it, and reads the result's Mach-O load commands. The
install name carries the ABI major alone.
"""

import struct
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RECIPE = ("archives.zig", "commands.zig", "execution.zig", "shard.zig")
MACH_O_64 = 0xFEEDFACF
LC_ID_DYLIB = 0xD


class SharedArchive(unittest.TestCase):
    def test_macos_shared_archive_records_its_abi_major(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name in RECIPE:
                (directory / name).write_bytes((ROOT / "tools/build" / name).read_bytes())
            (directory / "library.zig").write_text("export fn answer() u32 { return 42; }\n")
            (directory / "build.zig").write_text(
                textwrap.dedent("""\
                const std = @import("std");
                const archives = @import("archives.zig");
                pub fn build(b: *std.Build) void {
                    const library = b.addLibrary(.{
                        .name = "probe", .linkage = .dynamic,
                        .version = .{ .major = 3, .minor = 2, .patch = 1 },
                        .root_module = b.createModule(.{
                            .root_source_file = b.path("library.zig"),
                            .target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos }),
                            .optimize = .debug,
                        }),
                    });
                    archives.configureSharedArchive(library);
                    b.installArtifact(library);
                }
                """)
            )
            result = subprocess.run(
                ["zig", "build", "--cache-dir", str(directory / "cache")],
                cwd=directory,
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            binary = (directory / "zig-out/lib/libprobe.3.2.1.dylib").read_bytes()
            self.assertEqual(struct.unpack_from("<I", binary)[0], MACH_O_64)
            offset = 32
            for _ in range(struct.unpack_from("<I", binary, 16)[0]):
                command, size = struct.unpack_from("<II", binary, offset)
                if command == LC_ID_DYLIB:
                    start = offset + struct.unpack_from("<I", binary, offset + 8)[0]
                    self.assertEqual(binary[start : binary.index(b"\0", start)], b"@rpath/libprobe.3.dylib")
                    break
                offset += size
            else:
                self.fail("shared archive has no LC_ID_DYLIB")


if __name__ == "__main__":
    unittest.main()
