"""Check the comparison CLI's dynamic source names without creating invalid output.

Called by interface-test with its compiled checker. Uses only repository fixtures,
standard-library subprocesses, and a temporary output directory. Exits nonzero
if invalid source names are accepted or leave an output file.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

checker = Path(sys.argv[1]).resolve()
fixture = "test/interface/authoring/comparison.syrup"
with tempfile.TemporaryDirectory(prefix="glowcap-authoring-cli-") as directory:
    for target in ("rust", "ts"):
        output = Path(directory) / f"generated.{target}"
        for name in (
            "",
            "_",
            "9invalid",
            "a-b",
            "fn",
            "class",
            "await",
            "eval",
            "arguments",
            "safe\n}\npub fn injected() {}",
        ):
            result = subprocess.run(
                [checker, "syrup", fixture, target, "comparison.Reader", "read", name, output],
                capture_output=True,
                timeout=5,
                check=False,
            )
            if result.returncode == 0 or output.exists() or b"InvalidIdentifier" not in result.stderr:
                raise AssertionError(f"{target} admitted invalid identifier {name!r}: {result.stderr!r}")
        subprocess.run(
            [checker, "syrup", fixture, target, "comparison.Reader", "read", "authoring_read", output],
            capture_output=True,
            timeout=5,
            check=True,
        )
        assert output.is_file(), "valid identifier did not produce output"
