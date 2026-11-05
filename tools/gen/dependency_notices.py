"""Release staging writes actual third-party notices into its private tree.

Called by glowcap-pack and c-sdk-pack after binaries and browser assets are
staged, before publication. Argument: stage directory. Outputs one deterministic
share/glowcap/DEPENDENCY-NOTICES.txt. Package tools use locked, fetched sources.
Missing notices, stale supplements, command failure or unsafe paths fail the
stage. The release transaction owns cleanup and publication.
"""

import hashlib
import json
import re
import sys
from pathlib import Path

from notices.graphs import packages

ROOT = Path(__file__).resolve().parents[2]
SUPPLEMENTS = Path(__file__).with_name("notices")
NAME = re.compile(r"^(licen[sc]es?|copying|notice|copyright)([._-]|$)", re.I)


def contained(root, relative):
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()) or not path.is_file():
        raise ValueError(f"notice is missing or escapes its source: {relative}")
    return path


def source_notices(package):
    root = package["directory"]
    paths = set()
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if path.is_file() and (
            NAME.match(path.name)
            or any(part.lower() in ("license", "licenses", "licence", "licences") for part in relative.parts[:-1])
        ):
            paths.add(relative.as_posix())
    if package["license_file"]:
        paths.add(package["license_file"])
    return [(name, contained(root, name).read_bytes()) for name in sorted(paths)]


def supplement_notices(package, supplements, directory):
    key = f"{package['ecosystem']}:{package['name']}@{package['version']}"
    entry = supplements.get(key)
    if entry is None:
        return []
    vcs = json.loads((package["directory"] / ".cargo_vcs_info.json").read_text())
    if vcs["git"]["sha1"] != entry["revision"]:
        raise ValueError(f"supplement source revision changed: {key}")
    result = []
    for item in entry["files"]:
        body = contained(directory, item["file"]).read_bytes()
        if hashlib.sha256(body).hexdigest() != item["sha256"]:
            raise ValueError(f"supplement digest mismatch: {item['file']}")
        result.append((f"{item['path']}\nSource: {item['url']}", body))
    return result


def render(selected, supplements, directory):
    output = [
        "Third-party dependency notices\n",
        "Generated from the staged product's selected Cargo graph and bundled JavaScript packages.\n"
        "Cargo build dependencies are retained because generators can emit shipped code.\n"
        "Nested files keep their package-relative attribution, including bundled-source notices.\n"
        "License alternatives are reproduced as supplied, without imposing a new license policy.\n"
        "See LICENSE-THIRD-PARTY for the Zig dependencies, fonts, and other repository notices.\n",
    ]
    for package in selected:
        label = f"{package['ecosystem']}:{package['name']}@{package['version']}"
        source = source_notices(package)
        supplemental = supplement_notices(package, supplements, directory)
        has_terms = any(
            name == package["license_file"]
            or any(re.match(r"^(licen[sc]es?|copying)([._-]|$)", part, re.I) for part in Path(name).parts)
            for name, _ in source
        )
        notices = source + supplemental
        if not notices or not (has_terms or supplemental):
            raise ValueError(f"no license/notice text for {label}; add verified exact-version upstream evidence")
        output.append(f"\n{'=' * 72}\n{label}\nPackage source: {package['source']}\n")
        for name, body in notices:
            if not body.strip():
                raise ValueError(f"empty notice: {label}/{name}")
            output.append(f"\n--- {name} ---\n")
            output.append(body.decode("utf-8"))
            if not body.endswith(b"\n"):
                output.append("\n")
    return "".join(output)


def main():
    if len(sys.argv) != 2:
        raise ValueError("usage: dependency_notices.py STAGE")
    stage = Path(sys.argv[1]).resolve(strict=True)
    groups = json.loads((SUPPLEMENTS / "supplements.json").read_text())
    supplements = {}
    for group in groups:
        for package in group["packages"]:
            if package in supplements:
                raise ValueError(f"duplicate supplement: {package}")
            supplements[package] = group
    body = render(packages(ROOT, stage), supplements, SUPPLEMENTS)
    destination = stage / "share/glowcap/DEPENDENCY-NOTICES.txt"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(body, encoding="utf-8")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        sys.exit(f"dependency notices: {error}")
