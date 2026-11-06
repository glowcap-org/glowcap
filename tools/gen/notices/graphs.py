"""Resolve release dependency sources with the same Cargo and Vite selections.

Cargo's normal/build graph excludes dev-only dependencies. Build dependencies
are deliberately retained because macros and generators can emit shipped code.
Vite's license JSON selects packages from emitted chunks, not its tool graph.
"""

import json
import subprocess
from pathlib import Path


def command(arguments, root):
    return subprocess.check_output(arguments, cwd=root, text=True, timeout=90)


def cargo_packages(root, manifest, package, target):
    common = ["--offline", "--locked", "--manifest-path", manifest]
    metadata = json.loads(
        command(["cargo", "metadata", *common, "--filter-platform", target, "--format-version", "1"], root)
    )
    tree = command(
        [
            "cargo",
            "tree",
            *common,
            "-p",
            package,
            "--target",
            target,
            "--edges",
            "normal,build",
            "--prefix",
            "none",
            "--format",
            "{p}",
        ],
        root,
    )
    selected = {tuple(line.split()[:2]) for line in tree.splitlines() if line.strip()}
    for name, version in sorted(selected):
        candidates = [p for p in metadata["packages"] if p["name"] == name and "v" + p["version"] == version]
        if len(candidates) != 1:
            raise ValueError(f"ambiguous Cargo package: {name} {version}")
        found = candidates[0]
        directory = Path(found["manifest_path"]).parent.resolve()
        if found["source"] is None and directory.is_relative_to(root):
            continue
        yield {
            "ecosystem": "cargo",
            "name": name,
            "version": found["version"],
            "source": found["source"],
            "directory": directory,
            "license_file": found.get("license_file"),
        }


def browser_packages(root, stage):
    # The bundler writes this from emitted module IDs, after tree shaking.
    bundled = json.loads((stage / "share/glowcap/rooms/bundled-packages.json").read_text())
    if not bundled:
        raise ValueError("browser bundle has no dependency inventory")
    sources = {}
    for entry in ("main.tsx", "ground.js"):
        graph = json.loads(
            command(
                [
                    "deno",
                    "info",
                    "--json",
                    "--frozen-lockfile",
                    "--config",
                    "apps/rooms/deno.json",
                    f"apps/rooms/web/ui/{entry}",
                ],
                root,
            )
        )
        for package in graph["npmPackages"].values():
            sources[(package["name"], package["version"])] = package
    for package in bundled:
        name, version = package["name"], package["version"]
        source = sources[(name, version)]
        yield {
            "ecosystem": "npm",
            "name": name,
            "version": version,
            "source": source["registryUrl"],
            "directory": Path(source["localPath"]).resolve(),
            "license_file": None,
        }


def packages(root, stage):
    """Select only dependency owners whose artifacts are present in the stage."""
    host = command(["rustc", "-vV"], root).split("host: ", 1)[1].splitlines()[0]
    selected = []
    for transport in ("iroh", "webrtc"):
        if any((stage / "lib").glob(f"libglowcap_net_transport_{transport}.*")):
            selected.extend(cargo_packages(root, f"transports/{transport}/Cargo.toml", f"glowcap-{transport}", host))
    if (stage / "libexec/rooms-server").is_file():
        selected.extend(cargo_packages(root, "apps/rooms/rust/Cargo.toml", "rooms-product", host))
        selected.extend(cargo_packages(root, "apps/rooms/rust/Cargo.toml", "rooms-browser", "wasm32-unknown-unknown"))
        selected.extend(browser_packages(root, stage))
    unique = {}
    for package in selected:
        key = (package["ecosystem"], package["name"], package["version"], package["source"])
        unique[key] = package
    return [unique[key] for key in sorted(unique)]
