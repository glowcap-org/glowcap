#!/usr/bin/env python3
"""Give the installed autodoc viewer the two accessibility attributes it lacks.

Zig's generated documentation viewer ships an `<html>` with no language and a
logo link with no accessible name. Both are one attribute, both are inert to
the viewer's own script, and the root fix belongs upstream; until it lands,
the site build owns this deterministic fix-up at the same seam that installs
the artifact. Each pattern must be found either unpatched or already patched,
so an upstream change of shape fails this step loudly instead of shipping the
regression quietly.

Usage: autodoc_access.py <path-to-installed-autodoc-index.html>
"""

import sys

PATCHES = [
    ("<html>", '<html lang="en">'),
    # The viewer titles itself generically; the tab should name what it shows.
    ("<title>Zig Documentation</title>", "<title>pancake API reference</title>"),
    ('<a class="logo" href="#">', '<a class="logo" href="#" aria-label="API reference home">'),
    # The viewer's one content section is its main region, and the search box
    # with its scope picker is a search landmark; without the roles, assistive
    # tech sees a page with no landmarks at all.
    ("<section>", '<section role="main">'),
    ('<div id="navWrap">', '<div id="navWrap" role="search">'),
    # Module-doc links render as small adjacent words; give each at least the
    # 24px pointer target WCAG 2.2 asks for without moving the text baseline.
    (
        "</head>",
        "<style>section ul a { display: inline-block; min-height: 24px; }</style></head>",
    ),
]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: autodoc_access.py <autodoc-index.html>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        text = f.read()
    for needle, replacement in PATCHES:
        if replacement in text:
            continue
        if text.count(needle) != 1:
            print(
                f"autodoc_access: expected exactly one {needle!r} in {path}; "
                "the upstream viewer changed shape, so re-derive this patch "
                "or retire it",
                file=sys.stderr,
            )
            return 1
        text = text.replace(needle, replacement)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
