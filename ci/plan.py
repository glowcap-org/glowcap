"""Select the groups check.yml runs, from its event and the changed paths.

Called by the plan job at the checkout root, with complete history and the
standard Actions environment. No network access. Unknown paths or missing
diff history select full validation. Outputs go to GITHUB_OUTPUT and a
readable GITHUB_STEP_SUMMARY.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from groups import GROUP_NAMES, GROUPS


def select(event_name, ref, event, paths):
    """Return selected group names and whether full validation is required.

    Bounded mutation fuzzing runs only in full validation."""
    # Dev supplies the exact commit's promotion evidence, which main reuses
    # after a fast-forward, so every dev push must run full validation. Keep
    # explicit validation on main full for recovery runs too.
    if (
        event_name in ("schedule", "workflow_dispatch")
        or ref in ("refs/heads/main", "refs/heads/dev")
        or event.get("pull_request", {}).get("base", {}).get("ref") == "main"
        or paths is None
    ):
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
            # Build graph, CI, dependencies, and unclassified paths reach
            # everything, the fuzz search included.
            return list(GROUP_NAMES), True
    ordered = [name for name in GROUP_NAMES if name in selected and name != "fuzz"]
    return ordered, False


def changed_paths(event, cwd):
    # A follow-up cancels the prior PR run, so it must cover the whole PR.
    if "pull_request" in event:
        base = event["pull_request"].get("base", {}).get("sha", "")
    else:
        base = event.get("before", "")
    if not re.fullmatch(r"[0-9a-f]{40}", base) or base == "0" * 40:
        return None
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", "--no-renames", "-z", base, "HEAD", "--"],
            cwd=cwd,
            capture_output=True,
            check=True,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if not result.stdout:
        return []
    return result.stdout.decode("utf-8", errors="surrogateescape").rstrip("\0").split("\0")


def main():
    root = Path(__file__).resolve().parents[1]
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    selected, full = select(
        os.environ["GITHUB_EVENT_NAME"], os.environ["GITHUB_REF"], event, changed_paths(event, root)
    )
    groups = [
        {"name": group.name, "phases": list(group.phases), "shards": list(range(1, group.shards + 1))}
        for group in GROUPS
        if group.name in selected
    ]
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"groups={json.dumps(groups)}\nfull={str(full).lower()}\n")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(f"Validation: **{'full' if full else 'development'}**\n\n")
        summary.write("| Group | Build jobs | Test phases |\n| --- | ---: | --- |\n")
        for group in groups:
            summary.write(f"| {group['name']} | {len(group['shards'])} | {', '.join(group['phases'])} |\n")
        summary.write("\nmacOS runs separately.\n\n")
        summary.write(
            "Full validation reports `gates`, which promotion requires. A development "
            "run reports `dev-gates` and cannot promote a commit to main.\n"
        )


if __name__ == "__main__":
    main()
