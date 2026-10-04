#!/usr/bin/env python3
"""Check an ELF C archive's glowcap exports against its generated header.

Build-owned caller: common.installArchive, before static/shared installation.
Non-ABI implementation symbols are outside this manifest. nm must be available;
its subprocess has a finite deadline and output is replayed only on refusal.
"""

import re
import subprocess
import sys
from pathlib import Path


def declarations(header):
    text = re.sub(r"/\*.*?\*/|//[^\n]*", "", header, flags=re.S)
    names = set(re.findall(r"^\w[\w\s*]*\b(glowcap_\w+)\s*\([^;{}]*\);", text, re.M))
    if not names:
        raise ValueError("generated header contains no ABI declarations")
    return names


def exports(library):
    with library.open("rb") as source:
        magic = source.read(8)
    flags = ["--defined-only", "--extern-only"]
    if magic[:4] == b"\x7fELF":
        flags.append("--dynamic")
    elif magic != b"!<arch>\n":
        raise ValueError("expected an ELF library or static archive")
    result = subprocess.run(["nm", *flags, str(library)], capture_output=True, text=True, check=True, timeout=10)
    names = set()
    for line in result.stdout.splitlines():
        words = line.split()
        if len(words) >= 2:
            name = words[-1].split("@", 1)[0]
            if name.startswith("glowcap_"):
                names.add(name)
    return names


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: archive_symbols.py LIBRARY HEADER")
    library, header = map(Path, sys.argv[1:])
    try:
        expected = declarations(header.read_text())
        actual = exports(library)
        missing, unexpected = expected - actual, actual - expected
        if missing or unexpected:
            raise ValueError(f"missing: {', '.join(sorted(missing)) or 'none'}; unexpected: {', '.join(sorted(unexpected)) or 'none'}")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(f"archive-symbols: {library}: {error}")


if __name__ == "__main__":
    main()
