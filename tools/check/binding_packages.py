"""Rehearse or prove binding packages, for `bindings-package-check` and `publish.yml`.

Without --registry, build each package from the checkout and exercise it from a
consumer outside the tree against the installed C archives. Nothing is uploaded.
With --registry VERSION, install that version of each package from its registry
in a fresh consumer and run the same smoke. No GLOWCAP_LIB_DIR is set, so each
binding downloads the release's C archive under GLOWCAP_STRICT=1: this is the
cold-cache proof of a publication. Registry indexes lag an upload by minutes,
so only the install step retries. The Racket consumer installs into its own
PLTADDONDIR, so the user scope of the machine running the proof stays as it was.

Requires the devcontainer tools, or the matching runner toolchain. Packages and
consumers live in a temporary directory outside the checkout. Registry reads may
populate tool caches; no registry writes or user package installs occur.
The optional language argument selects one proof. Child failures stop the
check, child deadlines bound hangs, and temporary installs are removed on exit.
"""

import argparse
import functools
import http.server
import json
import os
import platform
import runpy
import shutil
import subprocess
import tarfile
import tempfile
import textwrap
import threading
import time
import tomllib
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
verify_binding_files = runpy.run_path(str(ROOT / "ci/github_release.py"))["verify_binding_files"]
INSTALL_ATTEMPTS = 12
INSTALL_RETRY_SECONDS = 20
RUST_FEATURES = ["async", "loam", "iroh", "webrtc", "relay", "onion"]


def run(*args, cwd=ROOT, env=None):
    subprocess.run(args, cwd=cwd, env=env, check=True, timeout=600)


def install(*args, cwd, env):
    """Run an install command, retrying while a registry index lags the upload."""
    for attempt in range(1, INSTALL_ATTEMPTS + 1):
        result = subprocess.run(args, cwd=cwd, env=env, timeout=600)
        if result.returncode == 0:
            return
        if attempt == INSTALL_ATTEMPTS:
            raise SystemExit(f"install did not succeed after {attempt} attempts: {args[0]}")
        print(f"install attempt {attempt} failed; retrying in {INSTALL_RETRY_SECONDS}s", flush=True)
        time.sleep(INSTALL_RETRY_SECONDS)


def verify_license(archive):
    expected = (ROOT / "LICENSE-APACHE").read_bytes()
    is_zip = zipfile.is_zipfile(archive)
    with zipfile.ZipFile(archive) if is_zip else tarfile.open(archive) as package:
        names = package.namelist() if is_zip else package.getnames()
        verify_binding_files(names)
        matches = [name for name in names if name.endswith("/LICENSE-APACHE") or name == "LICENSE-APACHE"]
        assert len(matches) == 1, f"{archive}: package needs exactly one Apache license"
        (name,) = matches
        actual = package.read(name) if is_zip else package.extractfile(name).read()
    assert actual == expected, f"{archive}: package must contain the project Apache license"


def verify_typescript_files():
    """JSR packages publish from the tracked TypeScript tree, so check every tracked file in it."""
    names = subprocess.check_output(["git", "ls-files", "-z", "--", "bindings/ts"], cwd=ROOT, text=True, timeout=60)
    tracked = [name for name in names.split("\0") if name]
    assert tracked, "git lists no tracked files under bindings/ts"
    verify_binding_files(tracked)


def downloaded_lib_dir(work):
    """The one release lib directory a registry consumer downloaded into the cache."""
    found = sorted(work.glob("cache/*/*/lib"))
    assert len(found) == 1, f"expected one downloaded C archive under {work / 'cache'}, found {found}"
    return found[0]


def python_package(work, env, registry):
    distributions = work / "dist"
    if registry is None:
        source = work / "python"
        shutil.copytree(
            ROOT / "bindings/python",
            source,
            ignore=shutil.ignore_patterns("__pycache__", "*.egg-info", "build", ".venv"),
        )
        run("uv", "build", "--sdist", "--out-dir", str(distributions), str(source))
        (sdist,) = distributions.glob("*.tar.gz")
        verify_license(sdist)
        run("uv", "build", "--wheel", "--out-dir", str(distributions), str(sdist))
        (wheel,) = distributions.glob("*.whl")
        verify_license(wheel)
    venv = work / "venv"
    run("uv", "venv", "--python", shutil.which("python3"), str(venv))
    python = str(venv / "bin/python")
    if registry is None:
        run("uv", "pip", "install", "--python", python, "--no-deps", str(wheel))
    else:
        install("uv", "pip", "install", "--python", python, "--no-cache", f"glowcap=={registry}", cwd=work, env=env)
    run(
        python,
        "-I",
        "-c",
        textwrap.dedent("""\
        import asyncio, importlib, pkgutil
        from pathlib import Path
        import glowcap
        for module in pkgutil.walk_packages(glowcap.__path__, glowcap.__name__ + '.'):
            importlib.import_module(module.name)
        package = Path(glowcap.__file__).parent
        assert (package / 'py.typed').is_file()
        assert (package / 'c-abi-resolve.json').is_file()
        async def smoke():
            host = glowcap.Host()
            await host.close()
        asyncio.run(smoke())
        """),
        cwd=work,
        env=env,
    )


def rust_package(work, env, registry):
    target = work / "cargo"
    if registry is None:
        run(
            "cargo",
            "package",
            "--manifest-path",
            str(ROOT / "bindings/rust/Cargo.toml"),
            "--allow-dirty",
            "--no-verify",
            "--target-dir",
            str(target),
        )
        (archive,) = (target / "package").glob("*.crate")
        verify_license(archive)
        with tarfile.open(archive) as package:
            package.extractall(work / "crate", filter="data")
        (crate,) = (work / "crate").iterdir()
        version = tomllib.loads((crate / "Cargo.toml").read_text())["package"]["version"]
        dependency = (
            f'{{ path = {json.dumps(str(crate))}, version = "={version}", features = {json.dumps(RUST_FEATURES)} }}'
        )
    else:
        dependency = f'{{ version = "={registry}", features = {json.dumps(RUST_FEATURES)} }}'
    consumer = work / "consumer"
    (consumer / "src").mkdir(parents=True)
    (consumer / "Cargo.toml").write_text(
        textwrap.dedent(f"""\
        [package]
        name = "glowcap-package-consumer"
        version = "0.0.0"
        edition = "2024"
        [dependencies]
        glowcap = {dependency}
        """)
    )
    (consumer / "src/main.rs").write_text("fn main() { let _context = glowcap::Context::new().unwrap(); }\n")
    manifest = str(consumer / "Cargo.toml")
    if registry is not None:
        # The index lags the upload; fetching is the retried step, the build is not.
        install("cargo", "fetch", "--manifest-path", manifest, cwd=work, env=env)
    run("cargo", "build", "--manifest-path", manifest, "--target-dir", str(target), cwd=work, env=env)
    # The iroh and WebRTC features link shared libraries that the loader finds
    # through the library path, beside the static core the build script linked.
    lib_dir = env["GLOWCAP_LIB_DIR"] if registry is None else str(downloaded_lib_dir(work))
    run(
        "cargo",
        "run",
        "--manifest-path",
        manifest,
        "--target-dir",
        str(target),
        cwd=work,
        env=dict(env, LD_LIBRARY_PATH=lib_dir, DYLD_LIBRARY_PATH=lib_dir),
    )
    if registry is None:
        # docs.rs builds without the native SDK. Rustdoc must also accept the
        # extracted crate and resolve its public links without a source checkout.
        run(
            "cargo",
            "doc",
            "--manifest-path",
            str(crate / "Cargo.toml"),
            "--lib",
            "--no-deps",
            "--all-features",
            "--target-dir",
            str(target),
            cwd=work,
            env=dict(
                {key: value for key, value in env.items() if key != "GLOWCAP_LIB_DIR"},
                DOCS_RS="1",
                GLOWCAP_STRICT="1",
                RUSTDOCFLAGS="-D rustdoc::broken_intra_doc_links",
            ),
        )


RACKET_SMOKE = """(for ([module '(glowcap/glowcap glowcap/glowcap-tcp glowcap/glowcap-inproc
                     glowcap/glowcap-onion glowcap/glowcap-iroh glowcap/glowcap-webrtc
                     glowcap/glowcap-relay)])
        (dynamic-require module #f))
      (define make-host (dynamic-require 'glowcap/glowcap 'make-fresh-host))
      ((dynamic-require 'glowcap/glowcap 'host-close!) (make-host))"""


def racket_package(work, env, registry):
    if registry is not None:
        # The catalog names the release archive publish.yml pointed it at, so
        # the install is the one a reader runs. Its user scope lives under the
        # work directory, and the version proves the catalog serves the release.
        env = dict(env, PLTADDONDIR=str(work / "racket-addon"))
        install("raco", "pkg", "install", "--auto", "--batch", "--no-docs", "glowcap", cwd=work, env=env)
        expression = f"""(define info ((dynamic-require 'setup/getinfo 'get-info) (list "glowcap")))
      (unless (equal? (info 'version) {json.dumps(registry)})
        (error 'catalog "installed glowcap ~a, expected ~a" (info 'version) {json.dumps(registry)}))
      {RACKET_SMOKE}"""
        run("racket", "-e", expression, cwd=work, env=env)
        downloaded_lib_dir(work)
        return
    source = runpy.run_path(str(ROOT / "ci/racket_catalog.py"))["package_source"]("owner/project", "v1.2.3")
    # The catalog downloads only the binding archive. Checking out the whole
    # repository fails Racket's strict link policy on contributor-tool symlinks.
    expression = f"""(require pkg/name)
      (define source {json.dumps(source)})
      (define-values (_name type) (package-source->name+type source #f))
      (unless (eq? type 'file-url)
        (error 'catalog-source "expected an archive, got ~s for ~a" type source))"""
    run("racket", "-e", expression, cwd=work, env=env)
    run("raco", "pkg", "create", "--source", "--format", "zip", "--dest", str(work), str(ROOT / "bindings/racket"))
    verify_license(work / "racket.zip")
    scope = work / "racket-pkgs"
    # The disposable scope has no dependency database. Use the devcontainer's
    # installed dependencies through the existing collection links at load time.
    run(
        "raco",
        "pkg",
        "install",
        "--scope-dir",
        str(scope),
        "--no-setup",
        "--deps",
        "force",
        "--name",
        "glowcap",
        str(work / "racket.zip"),
    )
    expression = f"""(parameterize ([current-library-collection-links
        (cons (string->path {json.dumps(str(scope / "links.rktd"))})
              (current-library-collection-links))])
      {RACKET_SMOKE})"""
    run("racket", "-e", expression, cwd=work, env=env)


def typescript_http_consumer(work, env):
    """Exercise remote module URLs with the installed SDK in its versioned cache."""
    consumer = work / "http-consumer"
    packages = consumer / "packages"
    manifests = {}
    for name in ("runtime", "abi"):
        source = ROOT / "bindings/ts" / name
        manifests[name] = json.loads((source / "deno.json").read_text())
        shutil.copytree(source, packages / name, ignore=shutil.ignore_patterns("test", "deno.json"))
    contract = json.loads((packages / "runtime/internal/ffi/c-abi-resolve.json").read_text())
    arch = {"arm64": "aarch64", "AMD64": "x86_64"}.get(platform.machine(), platform.machine())
    system = {"Darwin": "macos"}.get(platform.system(), platform.system().lower())
    cache = consumer / "cache"
    lib_dir = Path(
        contract["cache_layout"].format(cache_base=cache, version=contract["abi_version"], target=f"{arch}-{system}")
    )
    lib_dir.parent.mkdir(parents=True)
    lib_dir.symlink_to(Path(env["GLOWCAP_LIB_DIR"]).resolve(strict=True), target_is_directory=True)

    class Handler(http.server.SimpleHTTPRequestHandler):
        extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, ".ts": "application/typescript"}

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(packages)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        base = f"http://127.0.0.1:{server.server_port}"
        imports = {
            manifest["name"]: f"{base}/{name}/{manifest['exports']['.'].removeprefix('./')}"
            for name, manifest in manifests.items()
        }
        (consumer / "deno.json").write_text(json.dumps({"imports": imports}))
        (consumer / "smoke.ts").write_text(
            'import { Runtime } from "@glowcap/runtime";\n'
            "await using runtime = await Runtime.open({ providers: [] });\n"
            'console.log("opened a Runtime from HTTP packages and the versioned SDK cache");\n'
        )
        remote_env = {key: value for key, value in env.items() if key != "GLOWCAP_LIB_DIR"}
        remote_env.update(
            DENO_DIR=str(consumer / "deno-cache"), GLOWCAP_CACHE_DIR=str(cache), GLOWCAP_SKIP_DOWNLOAD="1"
        )
        run("deno", "run", "--no-prompt", "--allow-all", "smoke.ts", cwd=consumer, env=remote_env)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def typescript_package(work, env, registry):
    if registry is None:
        verify_typescript_files()
        for manifest in (ROOT / "bindings/ts").glob("*/deno.json"):
            package = json.loads(manifest.read_text())
            assert "LICENSE-APACHE" in package["publish"]["include"], manifest
            assert (manifest.parent / "LICENSE-APACHE").read_bytes() == (ROOT / "LICENSE-APACHE").read_bytes(), manifest
        # Deno checks cross-package imports, public declaration generation and the
        # actual publish include/exclude lists. --allow-dirty permits review edits;
        # --dry-run is unconditional, so this command never uploads anything.
        run("deno", "publish", "--dry-run", "--allow-dirty", cwd=ROOT / "bindings/ts", env=env)
        typescript_http_consumer(work, env)
        return
    consumer = work / "deno-consumer"
    consumer.mkdir()
    packages = sorted(json.loads(path.read_text())["name"] for path in (ROOT / "bindings/ts").glob("*/deno.json"))
    (consumer / "deno.json").write_text(
        json.dumps(
            {
                "imports": {name: f"jsr:{name}@{registry}" for name in packages},
                # These are the packages this release just published. Keep the
                # age policy for third-party dependencies in the fresh consumer.
                "minimumDependencyAge": {"age": "P1D", "exclude": [f"jsr:{name}" for name in packages]},
            },
            indent="\t",
        )
        + "\n"
    )
    (consumer / "smoke.ts").write_text(
        "".join(f'import "{name}";\n' for name in packages if name not in ("@glowcap/runtime", "@glowcap/tcp"))
        + textwrap.dedent("""\
        import { Runtime } from "@glowcap/runtime";
        import * as tcp from "@glowcap/tcp";
        await using managed = await Runtime.open({ providers: [tcp.provider()] });
        console.log("opened a Runtime from the published packages");
        """)
    )
    install("deno", "install", "--entrypoint", "smoke.ts", cwd=consumer, env=env)
    # The loader downloads with curl and tar and reads the cache, so the proof
    # runs with every permission a documented client has.
    run("deno", "run", "--allow-all", "smoke.ts", cwd=consumer, env=env)


def main():
    proofs = {
        "python": python_package,
        "rust": rust_package,
        "racket": racket_package,
        "typescript": typescript_package,
    }
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("language", nargs="?", choices=proofs)
    parser.add_argument(
        "--registry",
        metavar="VERSION",
        help="install this published version from each registry instead of building packages",
    )
    args = parser.parse_args()
    languages = [args.language] if args.language else list(proofs)
    with tempfile.TemporaryDirectory(prefix="glowcap-packages-") as temporary:
        work = Path(temporary)
        env = {key: value for key, value in os.environ.items() if not key.startswith("GLOWCAP_")}
        env["GLOWCAP_CACHE_DIR"] = str(work / "cache")
        if args.registry is None:
            env.update(GLOWCAP_LIB_DIR=str(ROOT / "zig-out/lib"), GLOWCAP_SKIP_DOWNLOAD="1")
        else:
            env["GLOWCAP_STRICT"] = "1"
        for name in languages:
            print(f"binding package: {name}", flush=True)
            proofs[name](work, env, args.registry)
            print(f"binding package: {name} passed", flush=True)


if __name__ == "__main__":
    main()
