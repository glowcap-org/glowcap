#!/usr/bin/env python3
"""Normalize the rendered site tree into the shape serving needs.

Two duties, both about what the server and its clients actually receive:

Page bytes: the pinned renderer serializes three shapes the HTML parser
repairs on load — a figure wrapped in the paragraph that carried its markdown
line, a captioned figure image with no alt attribute (the caption is the
description, so the image itself is decorative), and tables whose header and
body rows sit bare inside the table. This pass rewrites the served bytes into
the repaired form, so a no-script reader, a validator, and the browser all
see one document. Each transform asserts its opening and closing counts agree
per file, so a renderer whose emission changes shape fails loudly instead of
shipping a half-rewritten page.

Serving shape: GitHub Pages answers a missing path with the artifact's
top-level `404.html`, so the rendered `404/index.html` is copied there;
`robots.txt` and `sitemap.xml` are written from the walked pages, with the
canonical base read from `site/zine.ziggy` so the URL has one authority,
and each destination's social-preview address and image ride the same base.

Usage: site_normalize.py <site-root>   (reference/api is the generated
autodoc viewer, owned by its own fix-up, and is skipped for page bytes)
"""

import re
import sys
from pathlib import Path

HEADER_ROW = re.compile(r"<table><tr>((?:<th>.*?</th>)+)</tr>")


def normalize(text: str, path: Path) -> str:
    opened_figures = text.count("<p><figure")
    closed_figures = text.count("</figure></p>")
    if opened_figures != closed_figures:
        raise SystemExit(
            f"site_normalize: {path}: {opened_figures} '<p><figure' but "
            f"{closed_figures} '</figure></p>'; the renderer changed shape"
        )
    text = text.replace("<p><figure", "<figure").replace("</figure></p>", "</figure>")

    text = text.replace("<figure><img src=", '<figure><img alt="" src=')

    # A wide listing scrolls, and a scroll region reaches keyboard users only
    # if it can take focus. The page script also sets this, but the served
    # bytes should not need the script for it.
    text = re.sub(r"<pre(?![^>]*tabindex)", '<pre tabindex="0"', text)

    text, headed = HEADER_ROW.subn(r"<table><thead><tr>\1</tr></thead><tbody>", text)
    bare_tables = text.count("<table><tr>")
    text = text.replace("<table><tr>", "<table><tbody><tr>")
    closes = text.count("</tr></table>")
    if headed + bare_tables != closes:
        raise SystemExit(
            f"site_normalize: {path}: opened {headed + bare_tables} table bodies "
            f"but found {closes} '</tr></table>' closes; the renderer changed shape"
        )
    text = text.replace("</tr></table>", "</tr></tbody></table>")
    return text


def canonicalBase(repo_root: Path) -> str:
    """The deployed origin and prefix, read from the site config that owns it."""
    config = (repo_root / "site" / "zine.ziggy").read_text(encoding="utf-8")
    host = re.search(r'\.host_url\s*=\s*"([^"]+)"', config)
    prefix = re.search(r'\.url_path_prefix\s*=\s*"([^"]+)"', config)
    if host is None or prefix is None:
        raise SystemExit("site_normalize: site/zine.ziggy no longer names host_url and url_path_prefix")
    return f"{host.group(1)}/{prefix.group(1)}"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: site_normalize.py <site-root>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1])
    base = canonicalBase(Path(__file__).resolve().parents[2])
    pages = 0
    listed: list[str] = []
    for page in sorted(root.rglob("index.html")):
        rel = str(page.relative_to(root))
        if "reference/api" not in rel:
            original = page.read_text(encoding="utf-8")
            rewritten = normalize(original, page)
            # Every real destination names its one address, so a crawler that
            # reached a variant (the 404 copy, a mirrored path) still indexes
            # the destination itself. The not-found page is no destination.
            if rel != "404/index.html" and '<link rel="canonical"' not in rewritten:
                head_close = "</head>"
                if rewritten.count(head_close) != 1:
                    raise SystemExit(f"site_normalize: {page}: expected one </head>")
                loc = rel.removesuffix("index.html")
                # The link-preview card needs what only the deployed origin
                # can say: the page's one absolute address and an absolute
                # image URL, so a link pasted into a chat shows the mascot
                # instead of a bare domain.
                social = ""
                if 'property="og:url"' not in rewritten:
                    social += f'<meta property="og:url" content="{base}/{loc}">'
                if 'property="og:image"' not in rewritten:
                    social += (
                        f'<meta property="og:image" content="{base}/glowcap-goblin-512.png">'
                        '<meta property="og:image:alt" content="The glowcap mascot: a smiling stack of pancakes with a pat of butter.">'
                    )
                rewritten = rewritten.replace(
                    head_close,
                    f'<link rel="canonical" href="{base}/{loc}">{social}{head_close}',
                )
            if rewritten != original:
                page.write_text(rewritten, encoding="utf-8")
            pages += 1
        # The sitemap lists real destinations: not the not-found page, and not
        # the autodoc viewer's internal frame.
        if rel != "404/index.html" and "reference/api" not in rel:
            listed.append(rel.removesuffix("index.html"))
    if pages < 20:
        print(
            f"site_normalize: only {pages} pages under {root}; a real site build "
            "has more, refusing a vacuous pass",
            file=sys.stderr,
        )
        return 1

    not_found = root / "404" / "index.html"
    if not not_found.exists():
        print("site_normalize: the rendered tree has no 404 page", file=sys.stderr)
        return 1
    (root / "404.html").write_text(not_found.read_text(encoding="utf-8"), encoding="utf-8")

    (root / "robots.txt").write_text(
        f"User-agent: *\nAllow: /\nSitemap: {base}/sitemap.xml\n", encoding="utf-8"
    )
    urls = "\n".join(
        f"  <url><loc>{base}/{rel}</loc></url>" for rel in listed
    )
    (root / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        f"{urls}\n</urlset>\n",
        encoding="utf-8",
    )
    print(f"site_normalize: {pages} pages normalized, {len(listed)} in the sitemap")
    return 0


if __name__ == "__main__":
    sys.exit(main())
