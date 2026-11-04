"""Check the comparison CLI's identifiers and profiles before source output.

Called by interface-test with its compiled checker. Uses only repository fixtures,
standard-library subprocesses, and a temporary output directory. Exits nonzero
if invalid source names or profile requirements are accepted or leave output.
"""

import os
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

        for name in ("Error", "Pending", "Observation") if target == "rust" else ("Pending", "then"):
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

    # Rooted imports are compiler inputs. The expected bytes were authored with
    # the pinned upstream encoder, independently of either text or bundle code.
    imported = Path("test/interface/authoring/imports").resolve()
    expected = (imported / "expected.syrup").read_bytes()
    output = Path(directory) / "imported.syrup"
    subprocess.run(
        [checker, "text", imported / "board.interface", "description", "unused", "--direct", "unused", output],
        capture_output=True,
        timeout=5,
        check=True,
    )
    assert output.read_bytes() == expected, "default-root imported fixture differs"
    subprocess.run(
        [
            checker,
            "--root",
            imported,
            "text",
            imported / "board.interface",
            "description",
            "unused",
            "--direct",
            "unused",
            output,
        ],
        cwd=directory,
        capture_output=True,
        timeout=5,
        check=True,
    )
    assert output.read_bytes() == expected, "explicit root depends on working directory"
    project = Path(directory) / "project"
    project.mkdir()
    entry = project / "entry.interface"

    def checked_imports(body, error=None):
        entry.write_text(body)
        result = subprocess.run(
            [checker, "--root", project, "text", entry], capture_output=True, timeout=5, check=False
        )
        if error is None:
            assert result.returncode == 0, result.stderr
        else:
            assert result.returncode and error.encode() in result.stderr, result.stderr
        return result

    outside = Path(directory) / "outside.interface"
    outside.write_text("module Outside\ntype T = string\n")
    (project / "escape.interface").symlink_to(outside)
    for path, error in (
        ("missing.interface", "FileNotFound"),
        ("../outside.interface", "ImportOutsideRoot"),
        ("escape.interface", "ImportOutsideRoot"),
        (str(outside), "InvalidImportPath"),
        ("https://example.invalid/source", "InvalidImportPath"),
    ):
        checked_imports(f'module Entry\nimport "{path}" as library\n', error)

    if hasattr(os, "mkfifo"):
        fifo = project / "fifo.interface"
        os.mkfifo(fifo)
        checked_imports('module Entry\nimport "fifo.interface" as fifo\n', "InvalidImportPath")
        result = subprocess.run([checker, "text", fifo], capture_output=True, timeout=5, check=False)
        assert result.returncode and b"InvalidImportPath" in result.stderr, result.stderr

    library = project / "library.interface"
    library.write_text("module Library\ntype T = string\n")
    (project / "alias.interface").symlink_to(library)
    checked_imports(
        'module Entry\nimport "library.interface" as a\nimport "alias.interface" as b\ninterface R { call(value: a.T) -> b.T }\n'
    )
    library.write_text('module Library\nimport "entry.interface" as entry\ntype R = entry.R\ntype T = string\n')
    checked_imports('module Entry\nimport "library.interface" as a\ninterface R { call(value: a.T) -> string }\n')

    for declaration, location in (
        ("type T = string(min_bytes: 65, max_bytes: 64)", "library.interface:2:10:"),
        ("type T = Missing", "library.interface:2:10:"),
    ):
        library.write_text(f"module Library\n{declaration}\n")
        result = checked_imports('module Entry\nimport "library.interface" as a\n', "InvalidDescription")
        assert location.encode() in result.stderr, result.stderr

    library.write_text("module Library\ntype T = string\n")
    entry.write_text(
        'module Entry\nimport "library.interface" as a\nimport "alias.interface" as b\ninterface R { call(value: a.T) -> b.T }\n'
    )
    canonical = []
    for first, second in (("library.interface", "alias.interface"), ("alias.interface", "library.interface")):
        entry.write_text(
            f'module Entry\nimport "{first}" as a\nimport "{second}" as b\ninterface R {{ call(value: a.T) -> b.T }}\n'
        )
        subprocess.run(
            [checker, "text", entry, "description", "unused", "--direct", "unused", output],
            capture_output=True,
            timeout=5,
            check=True,
        )
        canonical.append(output.read_bytes())
    assert canonical[0] == canonical[1], "import order changes canonical output"

    # Both files fit individually, while the compilation exceeds one MiB.
    library.write_text("module Library\n" + " " * 600_000)
    checked_imports('module Entry\nimport "library.interface" as a\n' + " " * 600_000, "ResourceLimit")
    library.write_text("module Library\n")
    for count in (63, 64):
        declarations = []
        for index in range(count):
            (project / f"f{index}.interface").write_text(f"module F{index}\n")
            declarations.append(f'import "f{index}.interface" as f{index}\n')
        checked_imports("module Entry\n" + "".join(declarations), None if count == 63 else "ResourceLimit")
    for depth in (32, 33):
        for index in range(depth):
            next_import = f'import "d{index + 1}.interface" as next\n' if index + 1 < depth else ""
            (project / f"d{index}.interface").write_text(f"module D{index}\n" + next_import)
        checked_imports('module Entry\nimport "d0.interface" as next\n', None if depth == 32 else "ResourceLimit")

    complete = Path("test/interface/authoring/contracts").resolve()
    subprocess.run(
        [checker, "text", complete / "contracts.interface", "description", "unused", "--direct", "unused", output],
        capture_output=True,
        timeout=5,
        check=True,
    )
    assert output.read_bytes() == Path("test/interface/contracts.syrup").read_bytes(), (
        "complete authored contract differs"
    )
    refused = Path(directory) / "rest.rs"
    result = subprocess.run(
        [
            checker,
            "text",
            complete / "contracts.interface",
            "rust",
            "fixture.AnyReceiver",
            "--direct",
            "invoke",
            refused,
        ],
        capture_output=True,
        timeout=5,
        check=False,
    )
    assert result.returncode and b"UnsupportedProjection" in result.stderr and not refused.exists(), result.stderr
