"""The release workflow's job graph, attestation scope, and build steps at their boundaries.

Reads release.yml for what each job needs, which events select it, and which job
holds the attestation permissions. A tag push runs every job. A manual dispatch
rehearses the builds and image proofs and publishes nothing. The image context
step verifies the archive checksums against fixture archives, and the shell step
that selects the macOS SDK and the browser steps run against stub tools. This does not reach GitHub runners, registries, or the signing
service. The Zig and Rust packaging checks below it run the real recipes.
"""

import contextlib
import hashlib
import io
import json
import os
import struct
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

import release_build as BUILD
from workflows import ROOT, jobs, load, on_path, run, selected, step, stub, text, workflow

PACKAGE = load("tools/check/zig_package.py")
WORKFLOW = ".github/workflows/release.yml"
RELEASE = jobs(WORKFLOW)


class ReleaseBuild(unittest.TestCase):
    def test_a_tag_push_releases_and_a_dispatch_only_rehearses(self):
        release = RELEASE["release"]
        predicate = release["if"]
        self.assertEqual(predicate, "github.ref_type == 'tag'")
        self.assertEqual(release["needs"], ["contract", "archives", "images"])
        self.assertTrue(selected(predicate, {"event_name": "push", "ref_type": "tag"}))
        self.assertFalse(selected(predicate, {"event_name": "workflow_dispatch", "ref_type": "branch"}))
        self.assertFalse(selected(predicate, {"event_name": "workflow_dispatch", "ref_type": "tag"}, success=False))
        for name, needs in (("contract", None), ("archives", "contract"), ("images", ["contract", "archives"])):
            with self.subTest(job=name):
                job = RELEASE[name]
                self.assertNotIn("if", job)
                self.assertEqual(job.get("needs"), needs)
                self.assertIn("timeout-minutes", job)
        self.assertNotIn("needs", RELEASE["contract"])
        self.assertEqual(set(RELEASE), {"contract", "archives", "images", "release"})

    def test_triggers_are_a_version_tag_and_a_bare_dispatch(self):
        triggers = workflow(WORKFLOW)["on"]
        self.assertEqual(triggers, {"push": {"tags": ["v*"]}, "workflow_dispatch": None})
        source = text(WORKFLOW)
        self.assertNotIn("actions/cache", source)

    def test_only_a_tag_attests_and_only_the_archives_and_release_may_attest(self):
        archives = RELEASE["archives"]
        attest = step(archives, "Attest the archives' build provenance")
        for ref_type, expected in (("tag", True), ("branch", False), ("", False)):
            self.assertEqual(selected(attest["if"], {"ref_type": ref_type}), expected)
        self.assertTrue(attest["uses"].startswith("actions/attest-build-provenance@"))
        self.assertEqual(archives["permissions"]["attestations"], "write")
        self.assertEqual(archives["permissions"]["id-token"], "write")
        for name in ("contract", "images"):
            with self.subTest(job=name):
                job = RELEASE[name]
                body = json.dumps(job)
                self.assertNotIn("attestations", body)
                self.assertNotIn("id-token", body)
                self.assertNotIn("write", job["permissions"].values())
                self.assertNotIn("attest", body)

    def test_images_take_the_archives_of_their_own_run_and_check_them_before_extracting(self):
        images = RELEASE["images"]
        self.assertEqual(run(images, "Extract the verified Linux product"), "python3 ci/release_image.py context")
        [download] = [
            found for found in images["steps"] if found.get("uses", "").startswith("actions/download-artifact@")
        ]
        self.assertEqual(download["with"], {"name": "archives-${{ matrix.runner }}", "path": "archive-artifact"})
        self.assertNotIn("run-id", json.dumps(images))
        self.assertNotIn("github-token", json.dumps(images))
        good = b"product"
        for label, content, name, accepted in (
            ("intact", good, "glowcap-v0.1.0-x86_64-linux.tar.gz", True),
            ("wrong digest", b"damaged", "glowcap-v0.1.0-x86_64-linux.tar.gz", False),
            ("other architecture", good, "glowcap-v0.1.0-aarch64-linux.tar.gz", False),
        ):
            with self.subTest(label), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                directory = root / "archive-artifact/glowcap-release"
                directory.mkdir(parents=True)
                with tarfile.open(directory / name, "w:gz") as archive:
                    member = tarfile.TarInfo("bin/glowcap")
                    member.size = len(content)
                    archive.addfile(member, io.BytesIO(content))
                recorded = hashlib.sha256(
                    b"other" if label == "wrong digest" else (directory / name).read_bytes()
                ).hexdigest()
                (directory / "SHA256SUMS").write_text(f"{recorded}  {name}\n")
                result = subprocess.run(
                    [sys.executable, str(ROOT / "ci/release_image.py"), "context"],
                    cwd=root,
                    env=dict(os.environ, VERSION="0.1.0", ARCHIVE_ARCH="x86_64"),
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                self.assertEqual(result.returncode == 0, accepted, result.stderr)
                self.assertEqual((root / "image-context/bin/glowcap").exists(), accepted)

    def test_every_attestation_precedes_the_public_release_and_the_packages_follow_it(self):
        names = [found.get("name", "") for found in RELEASE["release"]["steps"]]
        public = names.index("Fill the draft release, then make it public")
        attestations = [index for index, name in enumerate(names) if name.startswith("Attest ")]
        self.assertEqual(len(attestations), 3, "the checksums, the image, and its bill of materials")
        self.assertLess(max(attestations), public)
        self.assertLess(public, names.index("Publish the language packages at the tag"))

    def test_failed_product_archives_are_preserved_without_qualifying_them(self):
        [predicate] = [found["if"] for found in RELEASE["archives"]["steps"] if "hashFiles" in found.get("if", "")]
        for present in (False, True):
            expression = predicate.replace(
                "hashFiles('zig-out/glowcap-release/*.tar.gz')", repr("digest" if present else "")
            )
            for cancelled in (False, True):
                self.assertEqual(selected(expression, success=False, cancelled=cancelled), present and not cancelled)

    def test_packaging_contracts_run_before_product_compilation(self):
        archives = RELEASE["archives"]
        names = [found.get("name") for found in archives["steps"]]
        before = names.index("Check release packaging contracts")
        self.assertLess(before, names.index("Install the matching browser compiler"))
        self.assertLess(before, names.index("Build the release archives"))
        packaging = step(archives, "Check release packaging contracts")
        self.assertEqual(packaging["run"], "zig build glowcap-package-test --summary all")
        self.assertNotIn("continue-on-error", packaging)

    def test_sidecar_inspection_uses_the_producing_rust_toolchain(self):
        self.assertRegex(text(".devcontainer/image/rust.sh"), r"rustup component add [^\n]*\bllvm-tools\b")
        [rust] = [found for found in RELEASE["archives"]["steps"] if found.get("uses") == "./.github/actions/rust"]
        self.assertIn("llvm-tools", rust["with"]["components"].split())
        added = workflow(".github/actions/rust/action.yml")["runs"]["steps"][1]["run"]
        self.assertIn('rustup component add "${components[@]}"', added)
        with tempfile.TemporaryDirectory(prefix="Rust toolchain ") as temporary:
            host = Path(temporary) / "lib/rustlib/host"
            tool = host / "bin/llvm-nm"
            tool.parent.mkdir(parents=True)
            tool.touch()
            with mock.patch.object(PACKAGE, "run", return_value=str(host / "lib") + "\n") as package_run:
                self.assertEqual(PACKAGE.rust_nm(), str(tool))
                package_run.assert_called_once_with("rustc", "--print", "target-libdir", cwd=ROOT, timeout=30)
                tool.unlink()
                with self.assertRaisesRegex(SystemExit, "rustup component add llvm-tools"):
                    PACKAGE.rust_nm()

    def test_sidecar_export_inspection_remains_exact(self):
        consumer = Path("/consumer with spaces")
        nm = "/Rust toolchain/bin/llvm-nm"
        expected = {"glowcap_iroh_sidecar_new", "glowcap_iroh_sidecar_drop"}
        declarations = "\n".join(f"extern fn {name}(" for name in expected)
        good = (
            "0000 T _glowcap_iroh_sidecar_new\n0000 T _glowcap_iroh_sidecar_drop\n"
            "         U _glowcap_iroh_sidecar_undefined\n0000 T _unrelated\n"
        )
        for symbols, passes in (
            (good, True),
            (good.replace("T _glowcap_iroh_sidecar_drop", "U _glowcap_iroh_sidecar_drop"), False),
            (good + "0000 T _glowcap_iroh_sidecar_extra\n", False),
        ):
            with (
                self.subTest(symbols=symbols),
                mock.patch.object(Path, "read_text", return_value=declarations),
                mock.patch.object(PACKAGE, "run", return_value=symbols) as run,
            ):
                if passes:
                    PACKAGE.sidecar_exports(consumer, "iroh", nm)
                else:
                    with self.assertRaisesRegex(AssertionError, "sidecar exports differ"):
                        PACKAGE.sidecar_exports(consumer, "iroh", nm)
                run.assert_called_once_with(nm, "-g", str(consumer / "zig-out/sidecars.a"), cwd=consumer, timeout=30)

    def test_archives_fetch_through_the_shared_front(self):
        self.assertEqual(run(RELEASE["archives"], "Fetch pinned Zig dependencies"), "python3 ci/gates.py fetch")

    def test_macos_shared_archive_records_its_abi_major(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name in ("archives.zig", "commands.zig", "execution.zig", "shard.zig"):
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
                            .optimize = .Debug,
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
            self.assertEqual(struct.unpack_from("<I", binary)[0], 0xFEEDFACF)
            offset = 32
            for _ in range(struct.unpack_from("<I", binary, 16)[0]):
                command, size = struct.unpack_from("<II", binary, offset)
                if command == 0xD:  # LC_ID_DYLIB
                    start = offset + struct.unpack_from("<I", binary, offset + 8)[0]
                    self.assertEqual(binary[start : binary.index(b"\0", start)], b"@rpath/libprobe.3.dylib")
                    break
                offset += size
            else:
                self.fail("shared archive has no LC_ID_DYLIB")

    def test_transport_linker_searches_the_selected_sdk(self):
        # An empty SDK makes the linker report where it searched. Exercise the
        # real shared recipe: shell argument checks cannot prove SDK discovery.
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            sdk = directory / "SDK with spaces"
            (sdk / "usr/lib").mkdir(parents=True)
            (sdk / "System/Library/Frameworks").mkdir(parents=True)
            for name in ("archives.zig", "cargo.zig", "commands.zig", "execution.zig", "shard.zig"):
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

    def test_archive_build_selects_the_sdk_only_for_a_macos_target(self):
        self.assertEqual(
            run(RELEASE["archives"], "Build the release archives"),
            'python3 ci/release_build.py archives "$RELEASE_TARGET"',
        )
        self.assertEqual(RELEASE["archives"]["env"]["RELEASE_TARGET"], "${{ matrix.target }}")
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            log = directory / "arguments.json"
            sdk = directory / "SDK with spaces"
            stub(
                directory,
                "zig",
                "#!/usr/bin/env python3\nimport json,os,sys\n"
                'open(os.environ["ARGUMENT_LOG"], "w").write(json.dumps([sys.argv[1:], os.environ.get("SDKROOT")]))\n',
            )
            stub(
                directory,
                "xcrun",
                '#!/bin/bash\n[[ "$*" == "--sdk macosx --show-sdk-path" ]] || exit 2\n'
                '[[ "$SDK_FAIL" == 0 ]] || exit 1\nprintf "%s\\n" "$SDK_PATH"\n',
            )
            for target, failed in [
                ("aarch64-linux-gnu.2.39", False),
                ("aarch64-macos.15.0", False),
                ("x86_64-macos.15.0", True),
            ]:
                with self.subTest(target=target, sdk_failed=failed):
                    log.unlink(missing_ok=True)
                    environment = on_path(
                        directory, SDK_FAIL=str(int(failed)), SDK_PATH=str(sdk), ARGUMENT_LOG=str(log)
                    )
                    environment.pop("SDKROOT", None)
                    with (
                        mock.patch.dict(os.environ, environment, clear=True),
                        contextlib.redirect_stderr(io.StringIO()),
                    ):
                        status = BUILD.main(["archives", target])
                    self.assertEqual(status == 0, not failed)
                    if failed:
                        self.assertFalse(log.exists(), "no build runs without its SDK")
                        continue
                    expected = [
                        "build",
                        "-Doptimize=ReleaseSafe",
                        "c-sdk-pack",
                        "glowcap-pack",
                        "-Dcpu=baseline",
                        "-Dtarget=" + target,
                    ]
                    self.assertEqual(json.loads(log.read_text()), [expected, str(sdk) if "macos" in target else None])

    def test_the_browser_steps_take_their_versions_from_their_owners(self):
        archives = RELEASE["archives"]
        self.assertEqual(
            run(archives, "Install the matching browser compiler"), "python3 ci/release_build.py browser-compiler"
        )
        bundle = step(archives, "Build and verify the browser bundle and WebAssembly libraries")
        self.assertEqual(bundle["run"], "python3 ci/release_build.py browser-bundle")
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            log = directory / "calls"
            for name in ("rustup", "cargo", "npx", "zig"):
                stub(directory, name, f'#!/bin/bash\nprintf "%s\\n" "{name} $*" >> "$CALL_LOG"\n')
            with mock.patch.dict(os.environ, on_path(directory, CALL_LOG=str(log)), clear=True):
                self.assertEqual(BUILD.main(["browser-compiler"]), 0)
                self.assertEqual(BUILD.main(["browser-bundle"]), 0)
            wasm_bindgen = subprocess.run(
                [sys.executable, ".devcontainer/image/rooms-toolchain-version.py"],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=20,
                check=True,
            ).stdout.strip()
            self.assertEqual(
                log.read_text().splitlines(),
                [
                    "rustup target add wasm32-unknown-unknown",
                    f"cargo install wasm-bindgen-cli --version {wasm_bindgen} --locked",
                    f"npx --yes playwright@{BUILD.pin('PLAYWRIGHT_VERSION')} install --with-deps chromium",
                    "zig build portable-package-test",
                ],
            )

    def test_a_failed_command_fails_with_its_status(self):
        with tempfile.TemporaryDirectory() as temporary:
            stub(temporary, "rustup", "#!/bin/bash\nexit 3\n")
            stderr = io.StringIO()
            with mock.patch.dict(os.environ, on_path(temporary), clear=True), contextlib.redirect_stderr(stderr):
                self.assertEqual(BUILD.main(["browser-compiler"]), 3)
            self.assertIn("release-build: rustup exited 3", stderr.getvalue())
        with self.assertRaisesRegex(ValueError, "declares no GLOWCAP_NO_SUCH_PIN"):
            BUILD.pin("GLOWCAP_NO_SUCH_PIN")
