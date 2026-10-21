"""Pages and releases require successful full validation of the main commit.

Usage: python3 tools/check/require-main-check.py COMMIT
GITHUB_REPOSITORY names the repository. The runner supplies gh and its token.
Accept a push or manual check only with successful gates and macos-runtime jobs.
Print the accepted run URL, or fail with a diagnostic. Each API request has a
30-second deadline. API failures retain their status. No publication occurs.
"""

import argparse
import json
import os
import re
import subprocess
import sys


def lookup(endpoint, key, *fields):
    try:
        response = subprocess.run([
            "gh", "api", "--method", "GET", endpoint, *fields,
        ], stdout=subprocess.PIPE, text=True, check=False, timeout=30)
    except subprocess.TimeoutExpired:
        print("require-main-check: Actions lookup exceeded 30 seconds; rerun when GitHub responds.", file=sys.stderr)
        return 124, []
    except OSError as error:
        print(f"require-main-check: cannot run gh: {error}", file=sys.stderr)
        return 1, []
    if response.returncode:
        return response.returncode, []
    try:
        rows = json.loads(response.stdout)[key]
        if not isinstance(rows, list):
            raise ValueError(f"{key} must be an array")
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        print(f"require-main-check: invalid Actions response: {error}", file=sys.stderr)
        return 1, []
    return 0, rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("commit")
    args = parser.parse_args()
    if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", args.commit):
        parser.error("commit must be a full hexadecimal commit ID")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        parser.error("GITHUB_REPOSITORY must name owner/repository")

    status, runs = lookup(
        f"repos/{repository}/actions/workflows/check.yml/runs", "workflow_runs",
        "-f", f"head_sha={args.commit}", "-f", "branch=main",
        "-f", "status=completed", "-f", "per_page=100")
    if status:
        return status
    for run in runs:
        if not isinstance(run, dict):
            continue
        origin = run.get("head_repository")
        url = run.get("html_url")
        run_id, attempt = run.get("id"), run.get("run_attempt")
        if not (run.get("head_sha") == args.commit
                and run.get("head_branch") == "main"
                and run.get("event") in ("push", "workflow_dispatch")
                and run.get("status") == "completed"
                and run.get("conclusion") == "success"
                and isinstance(origin, dict)
                and origin.get("full_name") == repository
                and isinstance(url, str) and url
                and type(run_id) is int and run_id > 0
                and type(attempt) is int and attempt > 0):
            continue
        status, jobs = lookup(
            f"repos/{repository}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100", "jobs")
        if status:
            return status
        passed = {job.get("name") for job in jobs if isinstance(job, dict)
                  and isinstance(job.get("name"), str)
                  and job.get("status") == "completed" and job.get("conclusion") == "success"}
        if {"gates", "macos-runtime"} <= passed:
            print(url)
            return 0
    print(f"require-main-check: {args.commit} has no successful full check on main. "
          "Run `gh workflow run check.yml --ref main -f suite=check`, wait for gates and "
          "macos-runtime to pass, then rerun publication.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
