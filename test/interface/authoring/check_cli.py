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
                [checker, "syrup", fixture, target, "comparison.Reader", "--named", "read", name, output],
                capture_output=True,
                timeout=5,
                check=False,
            )
            if result.returncode == 0 or output.exists() or b"InvalidIdentifier" not in result.stderr:
                raise AssertionError(f"{target} admitted invalid identifier {name!r}: {result.stderr!r}")
        subprocess.run(
            [checker, "syrup", fixture, target, "comparison.Reader", "--named", "read", "authoring_read", output],
            capture_output=True,
            timeout=5,
            check=True,
        )
        assert output.is_file(), "valid identifier did not produce output"

        for name in ("Error", "Pending", "Observation") if target == "rust" else ("Pending",):
            refused = Path(directory) / f"refused-{name}.{target}"
            result = subprocess.run(
                [checker, "syrup", fixture, target, "comparison.Reader", "--named", "read", name, refused],
                capture_output=True,
                timeout=5,
                check=False,
            )
            if result.returncode == 0 or refused.exists() or b"ExportCollision" not in result.stderr:
                raise AssertionError(f"{target} admitted public support collision {name!r}: {result.stderr!r}")

    # Independently authored selectors distinguish both option strings from direct calls.
    source = Path(directory) / "selector.interface"
    source.write_text(
        'module names\ninterface R { "--direct"() -> string "--named"() -> string ""() -> string }\ninterface D { () -> string }\n'
    )
    for target in ("rust", "ts"):
        for index, selector in enumerate(("--direct", "--named", "")):
            output = Path(directory) / f"selector-{index}.{target}"
            result = subprocess.run(
                [checker, "text", source, target, "names.R", "--named", selector, "selected", output],
                capture_output=True,
                timeout=5,
                check=False,
            )
            if result.returncode or f'"{selector}", ' not in output.read_text():
                raise AssertionError(f"{target} lost named selector {selector!r}: {result.stderr!r}")
        output = Path(directory) / f"direct.{target}"
        subprocess.run(
            [checker, "text", source, target, "names.D", "--direct", "selected", output],
            capture_output=True,
            timeout=5,
            check=True,
        )
        assert ("None::<&str>" if target == "rust" else "target, null,") in output.read_text()
        for selection in (("--named",), ("read",), ("--direct", "unexpected")):
            refused = Path(directory) / "bad-selector"
            result = subprocess.run(
                [checker, "text", source, target, "names.D", *selection, "selected", refused],
                capture_output=True,
                timeout=5,
                check=False,
            )
            if result.returncode == 0 or refused.exists() or b"InvalidArguments" not in result.stderr:
                raise AssertionError(f"{target} admitted malformed selector {selection!r}: {result.stderr!r}")

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
            [checker, "syrup", source, target, "R", "--named", "m", "profile_call", output],
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
