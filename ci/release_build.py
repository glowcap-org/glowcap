"""Build one release host's archives on the runner, outside the devcontainer.

Called by release.yml's `archives` job from the checkout root, after the pinned
Zig, Rust, Python, and Deno are installed. macOS hosts cannot run the
devcontainer, so these are the steps its image would otherwise own:

    release_build.py browser-compiler   add the wasm32 target and install the
                                        wasm-bindgen CLI at the version the
                                        Rooms lockfile holds
    release_build.py archives TARGET    build the C SDK and product archives
                                        for TARGET; a macOS target links
                                        against the SDK xcrun names
    release_build.py browser-bundle     install the pinned Playwright Chromium
                                        and build and prove the browser bundle
                                        and WebAssembly libraries

Each command runs under its own deadline inside the job's, and a failure exits
with the failing command's status and a `release-build:` line.
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
QUICK = 60
INSTALL = 900
BUILD = 3600


def run(*command, timeout, env=None, capture=False):
    return subprocess.run(
        command, cwd=ROOT, env=env, check=True, text=True, timeout=timeout, stdout=subprocess.PIPE if capture else None
    ).stdout


def pin(name):
    """A version .devcontainer/pins.sh declares, read the way every workflow reads it: by sourcing the file."""
    value = run("bash", "-c", f'source .devcontainer/pins.sh && printf %s "${{{name}}}"', timeout=QUICK, capture=True)
    if not value:
        raise ValueError(f".devcontainer/pins.sh declares no {name}")
    return value


def browser_compiler():
    run("rustup", "target", "add", "wasm32-unknown-unknown", timeout=INSTALL)
    version = run(sys.executable, ".devcontainer/image/rooms-toolchain-version.py", timeout=QUICK, capture=True).strip()
    run("cargo", "install", "wasm-bindgen-cli", "--version", version, "--locked", timeout=INSTALL)


def archives(target):
    environment = dict(os.environ)
    if "-macos" in target:
        sdk = run("xcrun", "--sdk", "macosx", "--show-sdk-path", timeout=QUICK, capture=True).strip()
        if not sdk:
            raise ValueError("xcrun named no macOS SDK")
        environment["SDKROOT"] = sdk
    run(
        "zig",
        "build",
        "-Doptimize=safe",
        "c-sdk-pack",
        "glowcap-pack",
        "-Dcpu=baseline",
        f"-Dtarget={target}",
        timeout=BUILD,
        env=environment,
    )


def browser_bundle():
    run(
        "npx", "--yes", f"playwright@{pin('PLAYWRIGHT_VERSION')}", "install", "--with-deps", "chromium", timeout=INSTALL
    )
    run("zig", "build", "portable-package-test", timeout=BUILD)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("browser-compiler")
    commands.add_parser("archives").add_argument("target")
    commands.add_parser("browser-bundle")
    args = parser.parse_args(argv)
    try:
        if args.command == "browser-compiler":
            browser_compiler()
        elif args.command == "archives":
            archives(args.target)
        else:
            browser_bundle()
    except subprocess.CalledProcessError as error:
        print(f"release-build: {error.cmd[0]} exited {error.returncode}", file=sys.stderr)
        return error.returncode
    except subprocess.TimeoutExpired as error:
        print(f"release-build: {error.cmd[0]} gave no result in {error.timeout} s", file=sys.stderr)
        return 124
    except (OSError, ValueError) as error:
        print(f"release-build: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
