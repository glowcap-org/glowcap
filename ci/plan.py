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


# A group compiles once and then tests in parallel: `shards` build jobs each
# compile one slice of what its ci/gates.sh phases run, then one test job per
# phase runs it on their combined state. A shard count of zero runs no build
# job, for phases whose gates compile in a nested build at run time. Shards
# split the group's slowest cold build across hosted runners; phases split its
# runs. Only compiles no Cargo or Deno build reaches can leave the first shard
# (execution.zig compileOnly), so a count above one pays only where those
# compiles are many. Every gates.sh phase belongs to exactly one group.
GROUPS = (
    ("source", ("source", "infrastructure"), 0),
    ("core", ("core", "memcheck"), 2),
    ("runtime", ("runtime",), 2),
    ("tls", ("tls",), 1),
    ("shipped", ("shipped", "smoke"), 2),
    ("fuzz", ("fuzz-1", "fuzz-2", "fuzz-3", "fuzz-4"), 0),
    ("bindings", ("sidecars", "bindings"), 1),
    ("browser", ("browser", "browser-proofs-1", "browser-proofs-2", "browser-proofs-3",
                 "browser-proofs-4"), 1),
    ("interop", ("rooms-interop", "interop"), 1),
    ("transports", ("transports",), 1),
)
GROUP_NAMES = tuple(name for name, _, _ in GROUPS)


def select(event_name, ref, event, paths):
    """Return selected group names and whether full validation is required.

    Bounded mutation fuzzing runs only in full validation."""
    # Dev supplies the exact commit's promotion evidence, which main reuses
    # after a fast-forward, so every dev push must run full validation. Keep
    # explicit validation on main full for recovery runs too.
    if (event_name in ("schedule", "workflow_dispatch")
            or ref in ("refs/heads/main", "refs/heads/dev")
            or event.get("pull_request", {}).get("base", {}).get("ref") == "main"
            or paths is None):
        return list(GROUP_NAMES), True
    selected = {"source", "core", "runtime", "tls", "shipped"}
    for path in paths:
        if path.endswith((".md", ".smd")):
            continue
        if path.endswith("/fuzz_test.zig"):
            return list(GROUP_NAMES), True
        if path.startswith(("src/loam/", "test/loam/")):
            selected.add("browser")
        elif path.startswith(("bindings/python/", "bindings/racket/")):
            selected.update(("bindings", "interop", "transports"))
        elif path.startswith("conformance/"):
            selected.update(("interop", "transports"))
        elif path.startswith(("src/", "test/", "apps/", "bindings/")):
            selected.update(GROUP_NAMES)
        else:
            # Build graph, CI, dependencies, and unclassified paths also
            # exercise the full search and qualification machinery.
            return list(GROUP_NAMES), True
    ordered = [name for name in GROUP_NAMES if name in selected and name != "fuzz"]
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
    selected, full = select(os.environ["GITHUB_EVENT_NAME"], os.environ["GITHUB_REF"],
                            event, changed_paths(event, root))
    groups = [{"name": name, "phases": list(phases), "shards": list(range(1, shards + 1))}
              for name, phases, shards in GROUPS if name in selected]
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"groups={json.dumps(groups)}\nfull={str(full).lower()}\n")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(f"Validation: **{'full' if full else 'development'}**\n\n")
        summary.write("| Group | Build jobs | Test phases |\n| --- | ---: | --- |\n")
        for group in groups:
            summary.write(f"| {group['name']} | {len(group['shards'])} | {', '.join(group['phases'])} |\n")
        summary.write("\nmacOS runs separately.\n\n")
        summary.write("Full validation supplies `gates` for promotion. Development validation "
                      "supplies `dev-gates` and cannot qualify a commit for main.\n")


if __name__ == "__main__":
    main()
