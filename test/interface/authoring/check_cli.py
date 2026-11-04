"""Check the comparison CLI's identifiers and profiles before source output.

Called by interface-test with its compiled checker. Uses only repository fixtures,
standard-library subprocesses, and a temporary output directory. Exits nonzero
if invalid source names or profile requirements are accepted or leave output.
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

    # Independently authored descriptions reach the shared model before any output.
    ordinary = b"{1\"R<9'interface{1\"m<6'method[]6'string4'call>}>}"
    receipt = b"{1\"R<9'interface{1\"m<6'method[<9'parameter1\"p<7'promise5'value>f>]9'undefined12'loam.receipt>}>}"
    mixed = b"{1\"R<9'interface{1\"m<6'method[]6'string4'call>1\"n<6'method[]9'undefined12'loam.receipt>}>}"
    values = b'{14"glowcap.values1+}'
    both = b'{12"loam.receipt1+14"glowcap.values1+}'
    for name, profiles, definitions, target, valid in (
        ("ordinary-rust", values, ordinary, "rust", True),
        ("ordinary-ts", values, ordinary, "ts", True),
        ("receipt", both, receipt, "rust", True),
        ("receipt-undeclared", values, receipt, "rust", False),
        ("unselected-receipt-undeclared", values, mixed, "rust", False),
        ("unused-version-unsupported", b'{12"loam.receipt2+14"glowcap.values1+}', ordinary, "rust", False),
    ):
        source = Path(directory) / f"{name}.syrup"
        source.write_bytes(b"<17'glowcap:interface1+" + profiles + definitions + b">")
        output = Path(directory) / f"{name}.{target}"
        result = subprocess.run(
            [checker, "syrup", source, target, "R", "m", "profile_call", output],
            capture_output=True,
            timeout=5,
            check=False,
        )
        if valid:
            if result.returncode or not output.is_file():
                raise AssertionError(f"{name} refused supported profiles: {result.stderr!r}")
            assert "profile_call" in output.read_text(), "valid profile did not reach emission"
        elif result.returncode == 0 or output.exists() or b"InvalidDescription" not in result.stderr:
            raise AssertionError(f"{name} emitted before profile validation: {result.stderr!r}")
