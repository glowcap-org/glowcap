"""Pages and release workflows require successful main-push evidence.

Usage: python3 tools/check/require-main-check.py COMMIT
GITHUB_REPOSITORY names the repository. The runner supplies gh and its token.
Print the accepted run URL, or fail with a diagnostic. Bound the API lookup to
30 seconds. API failures retain their status. No checkout or publication occurs.
"""

import argparse
import json
import os
import re
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("commit")
    args = parser.parse_args()
    if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", args.commit):
        parser.error("commit must be a full hexadecimal commit ID")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        parser.error("GITHUB_REPOSITORY must name owner/repository")

    try:
        response = subprocess.run([
            "gh", "api", "--method", "GET",
            f"repos/{repository}/actions/workflows/check.yml/runs",
            "-f", f"head_sha={args.commit}", "-f", "branch=main",
            "-f", "event=push", "-f", "status=completed", "-f", "per_page=100",
        ], stdout=subprocess.PIPE, text=True, check=False, timeout=30)
    except subprocess.TimeoutExpired:
        print("require-main-check: Actions lookup exceeded 30 seconds; rerun when GitHub responds.", file=sys.stderr)
        return 124
    except OSError as error:
        print(f"require-main-check: cannot run gh: {error}", file=sys.stderr)
        return 1
    if response.returncode:
        return response.returncode
    try:
        runs = json.loads(response.stdout)["workflow_runs"]
        if not isinstance(runs, list):
            raise ValueError("workflow_runs must be an array")
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        print(f"require-main-check: invalid Actions response: {error}", file=sys.stderr)
        return 1

    for run in runs:
        if not isinstance(run, dict):
            continue
        origin = run.get("head_repository")
        url = run.get("html_url")
        if (run.get("head_sha") == args.commit
                and run.get("head_branch") == "main"
                and run.get("event") == "push"
                and run.get("status") == "completed"
                and run.get("conclusion") == "success"
                and isinstance(origin, dict)
                and origin.get("full_name") == repository
                and isinstance(url, str) and url):
            print(url)
            return 0
    print(f"require-main-check: {args.commit} has no successful completed main push. "
          "Wait for its main check workflow to pass, then rerun.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
