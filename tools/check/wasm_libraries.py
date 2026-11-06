"""portable-package-test: link an external Rust browser consumer through a cold library download.

Takes the portable-release directory produced by portable-pack. Packages the
local crate without publishing, serves that exact archive and its checksum file on
loopback, and builds an extracted-crate consumer outside the checkout. Requires
the pinned Zig, Cargo/Rust Wasm target, Python, curl, tar and Deno toolchain. Cargo's
dependency cache is shared; the library cache and build output are new for each run.
Every child has a 600-second deadline, errors replay child output, and the
temporary files and HTTP listener are removed on success or failure. No retries,
registry writes or user package installs occur. The check itself proves download,
target selection, headers and linking; it does not execute browser or IndexedDB behavior.
"""

import functools
import hashlib
import http.server
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import threading
import tomllib
from pathlib import Path

from binding_packages import ROOT, verify_license

TARGET = "wasm32-freestanding"
RUST_TARGET = "wasm32-unknown-unknown"


def run(*args, cwd, env):
    try:
        subprocess.run(args, cwd=cwd, env=env, check=True, capture_output=True, text=True, timeout=600)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        for output in (error.stdout, error.stderr):
            if output:
                print(output.decode(errors="replace") if isinstance(output, bytes) else output, file=sys.stderr)
        raise


def prove(directory, work):
    contract = json.loads((ROOT / "bindings/c-abi-resolve.json").read_text())
    version = contract["abi_version"]
    name = contract["tarball_template"].format(version=version, target=TARGET)
    tag = contract["release_tag_template"].format(version=version)
    archive = directory / name
    checksums = directory / "SHA256SUMS"
    sums = {filename: digest for digest, filename in (line.split() for line in checksums.read_text().splitlines())}
    with archive.open("rb") as source:
        assert hashlib.file_digest(source, "sha256").hexdigest() == sums[name], (
            "library checksum differs from its artifact"
        )

    env = {key: value for key, value in os.environ.items() if not key.startswith("GLOWCAP_") and key != "DOCS_RS"}
    libraries = work / "libraries"
    with tarfile.open(archive) as package:
        package.extractall(libraries, filter="data")
    headers = work / "headers.c"
    headers.write_text('#include "glowcap_loam.h"\n')
    run(
        "zig",
        "cc",
        "-target",
        TARGET,
        "-c",
        "-o",
        str(work / "headers.o"),
        "-I",
        str(libraries / "include"),
        str(headers),
        cwd=work,
        env=env,
    )
    target = work / "cargo"
    run(
        "cargo",
        "package",
        "--manifest-path",
        str(ROOT / "bindings/rust/Cargo.toml"),
        "--allow-dirty",
        "--no-verify",
        "--target-dir",
        str(target),
        cwd=ROOT,
        env=env,
    )
    (crate_archive,) = (target / "package").glob("*.crate")
    verify_license(crate_archive)
    with tarfile.open(crate_archive) as package:
        package.extractall(work / "crate", filter="data")
    (crate,) = (work / "crate").iterdir()
    assert tomllib.loads((crate / "Cargo.toml").read_text())["package"]["version"] == version

    consumer = work / "consumer"
    (consumer / "src").mkdir(parents=True)
    (consumer / "Cargo.toml").write_text(
        textwrap.dedent(f"""\
        [package]
        name = "glowcap-wasm-libraries-consumer"
        version = "0.0.0"
        edition = "2024"
        [lib]
        crate-type = ["cdylib"]
        [dependencies]
        glowcap = {{ path = {json.dumps(str(crate))}, version = "={version}", default-features = false, features = ["browser", "loam"] }}
        """)
    )
    (consumer / "src/lib.rs").write_text(
        textwrap.dedent("""\
        #[unsafe(no_mangle)]
        pub extern "C" fn glowcap_wasm_libraries_probe() -> u32 {
            let context = glowcap::Context::new().unwrap();
            let host = glowcap::Host::from_seed_with_options_in(
                [7; 32], glowcap::HostOptions::default(), &context,
            ).unwrap();
            let schema = glowcap::loam::Schema {
                id: 1, version: 1, max_payload: 32, max_edges: 0,
            };
            host.designator().unwrap().len() as u32 + schema.encoded_size_bound().unwrap() as u32
        }
        """)
    )

    mirror = work / "release"
    (mirror / tag).mkdir(parents=True)
    for artifact in (archive, checksums):
        shutil.copyfile(artifact, mirror / tag / artifact.name)
    expected = {f"/{tag}/{name}", f"/{tag}/SHA256SUMS"}
    requested = []

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            requested.append(self.path)
            if self.path not in expected:
                self.send_error(404)
                return
            super().do_GET()

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(mirror)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    cache = work / "cache"
    assert not cache.exists(), "the library consumer must start with an empty cache"
    env.update(
        GLOWCAP_CACHE_DIR=str(cache),
        GLOWCAP_STRICT="1",
        GLOWCAP_ALLOW_INSECURE="1",
        GLOWCAP_RELEASE_BASE_URL=f"http://127.0.0.1:{server.server_port}",
    )
    try:
        run("cargo", "build", "--target", RUST_TARGET, "--target-dir", str(target), cwd=consumer, env=env)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    assert set(requested) == expected, f"library consumer requested {requested}, expected {sorted(expected)}"
    cached = Path(contract["cache_layout"].format(cache_base=cache, version=version, target=TARGET))
    assert sorted(cache.glob("*/*/lib")) == [cached], "library download populated the wrong target cache"
    with tarfile.open(archive) as package:
        for stem in ("host", "ocapn", "loam"):
            library = f"libglowcap_{stem}.a"
            assert (cached / library).read_bytes() == package.extractfile(f"lib/{library}").read(), library
    wasm = target / RUST_TARGET / "debug/glowcap_wasm_libraries_consumer.wasm"
    run(
        "deno",
        "eval",
        """
        const module = new WebAssembly.Module(await Deno.readFile(Deno.args[0]));
        if (!WebAssembly.Module.exports(module).some((entry) => entry.name === "glowcap_wasm_libraries_probe")) {
            throw new Error("consumer Wasm omitted the exported library probe");
        }
        const missing = WebAssembly.Module.imports(module).filter((entry) => entry.name.startsWith("glowcap_"));
        if (missing.length) throw new Error(`unresolved library imports: ${JSON.stringify(missing)}`);
        """,
        str(wasm),
        cwd=consumer,
        env=env,
    )
    print("Extracted Rust crate: downloaded WebAssembly libraries into an empty target cache and linked browser + loam")


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: wasm_libraries.py PORTABLE_RELEASE_DIRECTORY")
    directory = Path(sys.argv[1]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="glowcap-wasm-libraries-") as temporary:
        work = Path(temporary).resolve()
        assert not work.is_relative_to(ROOT), "library consumer must live outside the checkout"
        prove(directory, work)


if __name__ == "__main__":
    main()
