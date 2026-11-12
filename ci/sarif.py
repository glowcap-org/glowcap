"""Refuse a static audit report that holds a finding or describes no run.

Called by check.yml's `workflows` job after zizmor, which in SARIF mode sends
its findings to code scanning and exits 0 on them, so the job's verdict is read
here. The report is the SARIF file the action names. Prints each finding as
`rule path:line message` and exits 1 when there is one, or when the report
holds no run, because a report with no run audited nothing. Either refusal
ends with the next step on stderr. Exits 0 with nothing printed on a clean
report. Touches no network.

    sarif.py refuse REPORT
"""

import argparse
import json
import sys
from pathlib import Path


def findings(report):
    """Each finding of a SARIF report, as one line. Raises ValueError for a report with no run."""
    runs = report.get("runs") if isinstance(report, dict) else None
    if not isinstance(runs, list) or not runs:
        raise ValueError("the report holds no run, so nothing was audited")
    lines = []
    for run in runs:
        for result in run.get("results") or ():
            location = (result.get("locations") or [{}])[0].get("physicalLocation", {})
            path = location.get("artifactLocation", {}).get("uri", "?")
            line = location.get("region", {}).get("startLine", "?")
            lines.append(f"{result.get('ruleId', '?')} {path}:{line} {result.get('message', {}).get('text', '')}")
    return lines


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("refuse").add_argument("report", type=Path)
    args = parser.parse_args(argv)
    try:
        found = findings(json.loads(args.report.read_text()))
    except (OSError, ValueError, AttributeError) as error:
        return f"sarif: {args.report}: {error}. Read the audit step's log, which wrote no usable report."
    for line in found:
        print(line)
    if found:
        print(
            f"sarif: {len(found)} finding(s). Fix each named workflow line and push. "
            "This check reads the report, so dismissing a code scanning alert does not clear it.",
            file=sys.stderr,
        )
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
