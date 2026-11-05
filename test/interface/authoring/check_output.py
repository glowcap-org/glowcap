"""Check authoring output preservation and generation diagnostics.

Called by interface-test with its compiled checker. Repository fixtures resolve
from the caller's repository cwd. Standard-library subprocesses have five-second
deadlines. Temporary inputs, aliases and output are removed on exit. POSIX file
size pressure checks partial-write cleanup without changing system-wide limits.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

checker = Path(sys.argv[1]).resolve()
fixture = "test/interface/authoring/comparison.syrup"
with tempfile.TemporaryDirectory(prefix="glowcap-authoring-output-") as directory:
    # Output publication owns source preservation, independently of the emitter.
    source = Path(directory) / "safe.interface"
    library = Path(directory) / "safe-library.interface"
    source_text = 'module Safe\nimport "safe-library.interface" as lib\ninterface R { read() -> lib.Text }\n'
    library_text = "module Library\ntype Text = string\n"
    source.write_text(source_text)
    library.write_text(library_text)
    aliases = [source, library]
    for original in (source, library):
        alias = original.with_suffix(".link")
        alias.symlink_to(original)
        aliases.append(alias)
    for output in aliases:
        result = subprocess.run(
            [checker, "text", source, "rust", "Safe.R", "--named", "read", "read_value", output],
            capture_output=True,
            timeout=5,
            check=False,
        )
        assert result.returncode and b"OutputIsInput" in result.stderr, result.stderr
        assert source.read_text() == source_text and library.read_text() == library_text, "input was overwritten"
        assert b"tools/interface/" not in result.stderr, "expected refusal printed compiler internals"

    raw = Path(directory) / "safe.syrup"
    raw.write_bytes(Path(fixture).read_bytes())
    before = raw.read_bytes()
    result = subprocess.run(
        [checker, "syrup", raw, "description", "unused", "--direct", "unused", raw],
        capture_output=True,
        timeout=5,
        check=False,
    )
    assert result.returncode and b"OutputIsInput" in result.stderr and raw.read_bytes() == before, result.stderr

    # An unloaded hardlink name is a safe output: atomic replacement must
    # preserve the loaded name and its original bytes instead of truncating it.
    output = Path(directory) / "safe-output.rs"
    output.hardlink_to(library)
    subprocess.run(
        [checker, "text", source, "rust", "Safe.R", "--named", "read", "read_value", output],
        capture_output=True,
        timeout=5,
        check=True,
    )
    assert "pub use" in output.read_text(), "normal generation did not publish output"
    assert library.read_text() == library_text and source.read_text() == source_text, "hardlink truncated input"
    assert not output.samefile(library), "output publication kept its hardlink to a source"

    unrelated = Path(directory) / "unrelated.txt"
    unrelated.write_text("keep this target")
    output.unlink()
    output.symlink_to(unrelated)
    subprocess.run(
        [checker, "text", source, "rust", "Safe.R", "--named", "read", "read_value", output],
        capture_output=True,
        timeout=5,
        check=True,
    )
    assert not output.is_symlink() and "pub use" in output.read_text(), "output symlink was not replaced"
    assert unrelated.read_text() == "keep this target", "output publication wrote through a symlink"

    if os.name == "posix":
        import resource
        import signal

        def private_creation_mask():
            os.umask(0o077)

        for mode, prepare in ((0o600, None), (0o640, private_creation_mask)):
            output.chmod(mode)
            subprocess.run(
                [checker, "text", source, "rust", "Safe.R", "--named", "read", "read_value", output],
                capture_output=True,
                timeout=5,
                check=True,
                preexec_fn=prepare,
            )
            assert output.stat().st_mode & 0o777 == mode, "publication changed existing output permissions"

        def refuse_large_write():
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
            resource.setrlimit(resource.RLIMIT_FSIZE, (1024, 1024))

        output.write_text("keep this output")
        names = set(Path(directory).iterdir())
        result = subprocess.run(
            [checker, "text", source, "rust", "Safe.R", "--named", "read", "read_value", output],
            capture_output=True,
            timeout=5,
            check=False,
            preexec_fn=refuse_large_write,
        )
        assert result.returncode and b"FileTooBig" in result.stderr, result.stderr
        assert output.read_text() == "keep this output", "partial write changed existing output"
        assert set(Path(directory).iterdir()) == names, "failed write left a temporary output"

    # Expected projection and selection errors retain author-facing context.
    library.write_text("module Library\ntype Text = null\n")
    for target, receiver, selector, expected in (
        ("rust", "Safe.R", "read", b"UnsupportedTarget"),
        ("ts", "Safe.R", "read", b"UnsupportedTarget"),
        ("rust", "Safe.R", "renamed", b"InvalidDescription"),
        ("rust", "Safe.R", "", b"InvalidDescription"),
        ("rust", "Safe.Missing", "read", b"InvalidDescription"),
    ):
        before = output.read_bytes()
        result = subprocess.run(
            [checker, "text", source, target, receiver, "--named", selector, "read_value", output],
            capture_output=True,
            timeout=5,
            check=False,
        )
        assert result.returncode and expected in result.stderr, result.stderr
        for context in (str(source), target, receiver, f'named "{selector}"', 'as "read_value"'):
            assert context.encode() in result.stderr, result.stderr
        assert b"tools/interface/" not in result.stderr, "expected refusal printed compiler internals"
        assert output.read_bytes() == before, "generation refusal changed existing output"
        if expected == b"UnsupportedTarget":
            assert b"safe-library.interface:2:" in result.stderr, result.stderr

    library.write_text(library_text)
    for target in ("rust", "ts"):
        for name, expected, quoted in (
            ("Pending", b"ExportCollision", b'as "Pending"'),
            ("bad\nname", b"InvalidIdentifier", b'as "bad\\nname"'),
            ("", b"InvalidIdentifier", b'as ""'),
        ):
            before = output.read_bytes()
            result = subprocess.run(
                [checker, "text", source, target, "Safe.R", "--named", "read", name, output],
                capture_output=True,
                timeout=5,
                check=False,
            )
            assert result.returncode and expected in result.stderr and quoted in result.stderr, result.stderr
            assert b"tools/interface/" not in result.stderr, "export refusal printed compiler internals"
            assert output.read_bytes() == before, "export refusal changed existing output"
