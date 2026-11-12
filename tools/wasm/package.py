"""portable-pack: seal the built browser module and WebAssembly libraries as release archives.

Called by the build graph with the install prefix and a fresh staging directory. Uses the checkout's version,
Git revision and dirty state, writes portable-release/{archives,SHA256SUMS}, and
writes both archives before the build graph commits the directory as one generation. Exits nonzero
for missing inputs or a failed browser bundle. portable-package-test exercises the
extracted browser package, and release assembly verifies metadata and inventory.
"""

import hashlib
import json
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def package(prefix: Path, output: Path) -> None:
    version = json.loads((ROOT / "bindings/ts/web/deno.json").read_text())["version"]
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, timeout=60).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, timeout=60))
    output.mkdir(parents=True, exist_ok=True)
    archives = []
    for role, target in (("web", "browser"), ("c", "wasm32-freestanding")):
        with tempfile.TemporaryDirectory(prefix="glowcap-portable-", dir=output) as directory:
            stage = Path(directory) / "tree"
            stage.mkdir()
            for name in ("LICENSE-APACHE", "LICENSE-THIRD-PARTY", "PROVENANCE.md"):
                shutil.copyfile(ROOT / name, stage / name)
            if role == "web":
                shutil.copyfile(ROOT / "bindings/ts/web/README.md", stage / "README.md")
                shutil.copyfile(prefix / "wasm/glowcap_host.wasm", stage / "glowcap_host.wasm")
                for name in ("index.html", "example.js"):
                    shutil.copyfile(ROOT / "bindings/ts/web/examples" / name, stage / name)
                subprocess.run(
                    [
                        "deno",
                        "bundle",
                        "--platform",
                        "browser",
                        "--no-lock",
                        "--quiet",
                        "--config",
                        "bindings/ts/web/browser-bundle.json",
                        "--output",
                        str(stage / "glowcap.js"),
                        "bindings/ts/web/browser.ts",
                    ],
                    cwd=ROOT,
                    check=True,
                    timeout=120,
                )
            else:
                shutil.copyfile(ROOT / "bindings/rust/README.md", stage / "README.md")
                (stage / "lib").mkdir()
                for stem in ("host", "ocapn", "loam"):
                    name = f"libglowcap_{stem}.a"
                    shutil.copyfile(prefix / "wasm/lib" / name, stage / "lib" / name)
                (stage / "include").mkdir()
                for stem in ("ocapn", "locator", "host", "loam"):
                    header = f"glowcap_{stem}.h"
                    shutil.copyfile(ROOT / "include" / header, stage / "include" / header)
            metadata = stage / "share/glowcap/release.json"
            metadata.parent.mkdir(parents=True)
            metadata.write_text(
                json.dumps(
                    {
                        "version": version,
                        "target": target,
                        "revision": revision,
                        "dirty": dirty,
                        "minimum_runtime": "WebAssembly",
                    }
                )
                + "\n"
            )
            name = f"glowcap-{role}-v{version}-{target}.tar.gz"
            archive = Path(directory) / name
            with tarfile.open(archive, "w:gz") as bundle:
                for entry in sorted(stage.rglob("*")):
                    if entry.is_file():
                        bundle.add(entry, arcname=entry.relative_to(stage), recursive=False)
            archive.replace(output / name)
            archives.append(output / name)
    (output / "SHA256SUMS").write_text(
        "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in archives)
    )


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: package.py INSTALL_PREFIX STAGING_DIRECTORY")
    package(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
