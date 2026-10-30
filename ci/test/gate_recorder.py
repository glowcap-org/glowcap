"""Record ci/gates.sh commands and outcomes without running product gates."""

import os
from pathlib import Path
import subprocess
import sys
import textwrap

ROOT = Path(__file__).resolve().parents[2]

# Every gate starts this stand-in for python3, so it is a shell script: an
# interpreter launch per gate dominates the suite's time on macOS runners.
# Arguments are unit-separated and each call is record-separated.
GATE = textwrap.dedent("""\
    #!/bin/sh
    if [ "$1" = tools/evidence/record.py ]; then
        exec "$GATE_EVIDENCE_PYTHON" "$GATE_EVIDENCE_RECORDER" "$@"
    fi
    skip=4
    for argument in "$@"; do
        [ "$argument" = --heartbeat ] && skip=6
    done
    [ "$#" -ge "$skip" ] || skip=$#
    shift "$skip"
    {
        for argument in "$@"; do printf '%s\\037' "$argument"; done
        printf '\\036'
    } >>"$GATE_CALLS"
    for argument in "$@"; do
        [ "$argument" = .devcontainer/test/tool-install.sh ] && exit 37
        [ -n "${GATE_FAIL+set}" ] && [ "$argument" = "$GATE_FAIL" ] && exit 37
    done
    exit 0
    """)

EVIDENCE = textwrap.dedent("""\
    import json, os, sys
    from pathlib import Path
    rows = Path(sys.argv[sys.argv.index('--gates') + 1]).read_text()
    Path(os.environ['GATE_RECORD']).write_text(json.dumps({'args': sys.argv[2:], 'rows': rows}))
    sys.exit(int(os.environ.get('RECORD_FAILURE', '0')))
    """)


class GateRecorder:
    """Runs ci/gates.sh with every gate recorded under `directory`. A gate
    naming GATE_FAIL exits 37, and the evidence recorder exits RECORD_FAILURE."""

    def __init__(self, directory):
        self.calls = directory / 'calls'
        self.record = directory / 'record.json'
        program = directory / 'python3'
        program.write_text(GATE)
        program.chmod(0o755)
        evidence = directory / 'evidence.py'
        evidence.write_text(EVIDENCE)
        self.environment = dict(os.environ, PATH=f'{directory}{os.pathsep}{os.environ["PATH"]}',
                                GATE_CALLS=str(self.calls), GATE_RECORD=str(self.record),
                                GATE_EVIDENCE_PYTHON=sys.executable,
                                GATE_EVIDENCE_RECORDER=str(evidence))
        self.environment.pop('GATES_SOURCE_ONLY', None)

    def gates(self, *arguments, **overrides):
        """Run ci/gates.sh with `arguments` after clearing earlier output, and
        return its result and the gates it invoked."""
        self.calls.unlink(missing_ok=True)
        self.record.unlink(missing_ok=True)
        result = subprocess.run(['bash', 'ci/gates.sh', *arguments], cwd=ROOT,
                                env=dict(self.environment, **overrides), capture_output=True, text=True)
        calls = self.calls.read_text().split('\x1e')[:-1] if self.calls.exists() else []
        invoked = [call.split('\x1f')[:-1] for call in calls]
        return result, invoked
