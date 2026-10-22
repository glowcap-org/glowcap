"""Select checks for check.yml from its event and the local checkout.

No network access. Unknown paths or unavailable diff history select the full
suite. Outputs go to GITHUB_OUTPUT and a readable GITHUB_STEP_SUMMARY. The
workflow checks out complete history and supplies the standard Actions env.
"""

import json
import os
from pathlib import Path
import re
import subprocess


# A lane is one hosted runner paying its own cold build. Each holds the phases
# that fit its runner deadline, with headroom, at hosted-runner speed.
LANES = ("core", "shipped", "bindings", "browser", "interop", "transports")


def select(event_name, ref, event, paths):
    """Return selected lanes and whether full validation is required."""
    if (event_name in ("schedule", "workflow_dispatch")
            or ref == "refs/heads/main"
            or event.get("pull_request", {}).get("base", {}).get("ref") == "main"
            or paths is None):
        return list(LANES), True
    lanes = {"core", "shipped"}
    for path in paths:
        if path.endswith((".md", ".smd")):
            continue
        if path.endswith("/fuzz_test.zig"):
            return list(LANES), True
        if path.startswith(("src/loam/", "test/loam/")):
            lanes.add("browser")
        elif path.startswith(("bindings/python/", "bindings/racket/")):
            lanes.update(("bindings", "interop", "transports"))
        elif path.startswith("conformance/"):
            lanes.update(("interop", "transports"))
        elif path.startswith(("src/", "test/", "apps/", "bindings/")):
            lanes.update(LANES)
        else:
            # Build graph, CI, dependencies, and unclassified paths also
            # exercise the full search and qualification machinery.
            return list(LANES), True
    ordered = [lane for lane in LANES if lane in lanes]
    return ordered, False


def changed_paths(event, cwd):
    base = event.get("before") or event.get("pull_request", {}).get("base", {}).get("sha", "")
    if not re.fullmatch(r"[0-9a-f]{40}", base) or base == "0" * 40:
        return None
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", "--no-renames", "-z", base, "HEAD", "--"],
            cwd=cwd, capture_output=True, check=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if not result.stdout:
        return []
    return result.stdout.decode("utf-8", errors="surrogateescape").rstrip("\0").split("\0")


def main():
    root = Path(__file__).resolve().parents[1]
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    lanes, full = select(os.environ["GITHUB_EVENT_NAME"], os.environ["GITHUB_REF"],
                         event, changed_paths(event, root))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"lanes={json.dumps(lanes)}\nfull={str(full).lower()}\n")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(f"Validation: **{'full' if full else 'development'}**\n\n")
        summary.write(f"Linux jobs: {', '.join(lanes)}. macOS runs separately.\n\n")
        summary.write("Full validation supplies `gates` for promotion. Development validation "
                      "supplies `dev-gates` and cannot qualify a commit for main.\n")


if __name__ == "__main__":
    main()
