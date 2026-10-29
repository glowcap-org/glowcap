"""Record ci/gates.sh commands and outcomes without running product gates."""

import json
import os
from pathlib import Path
import subprocess
import sys
import textwrap

ROOT = Path(__file__).resolve().parents[2]

RECORDER = textwrap.dedent("""\
    import json, os, sys
    if sys.argv[1] == 'tools/evidence/record.py':
        from pathlib import Path
        rows = Path(sys.argv[sys.argv.index('--gates') + 1]).read_text()
        Path(os.environ['GATE_RECORD']).write_text(json.dumps({'args': sys.argv[2:], 'rows': rows}))
        sys.exit(int(os.environ.get('RECORD_FAILURE', '0')))
    command = sys.argv[7:] if '--heartbeat' in sys.argv else sys.argv[5:]
    with open(os.environ['GATE_CALLS'], 'a') as output:
        output.write(json.dumps(command) + '\\n')
    sys.exit(37 if '.devcontainer/test/tool-install.sh' in command or os.environ.get('GATE_FAIL') in command else 0)
    """)


class GateRecorder:
    """Runs ci/gates.sh with every gate recorded under `directory`. A gate
    naming GATE_FAIL exits 37, and the evidence recorder exits RECORD_FAILURE."""

    def __init__(self, directory):
        self.calls = directory / 'calls.jsonl'
        self.record = directory / 'record.json'
        program = directory / 'python3'
        program.write_text(f'#!{sys.executable}\n' + RECORDER)
        program.chmod(0o755)
        self.environment = dict(os.environ, PATH=f'{directory}{os.pathsep}{os.environ["PATH"]}',
                                GATE_CALLS=str(self.calls), GATE_RECORD=str(self.record))
        self.environment.pop('GATES_SOURCE_ONLY', None)

    def gates(self, *arguments, **overrides):
        """Run ci/gates.sh with `arguments` after clearing earlier output, and
        return its result and the gates it invoked."""
        self.calls.unlink(missing_ok=True)
        self.record.unlink(missing_ok=True)
        result = subprocess.run(['bash', 'ci/gates.sh', *arguments], cwd=ROOT,
                                env=dict(self.environment, **overrides), capture_output=True, text=True)
        invoked = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        return result, invoked
