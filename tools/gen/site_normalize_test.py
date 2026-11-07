"""The site normalizer's rewrites: every header row gets a thead, in a form that
reads each cell once, and a link to an exported application's entry document
names its directory, in HTML and in the markdown twin alike.

Run by infrastructure-check. tools/gen/site_normalize.py runs under `zig build
site` on rendered pages, and this is the focused proof of its regexes.
"""

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

SCRIPT = ROOT / "tools/gen/site_normalize.py"
SPEC = importlib.util.spec_from_file_location("site_normalize", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
HEAD = r"<table><thead><tr>\1</tr></thead><tbody>"


class HeaderRows(unittest.TestCase):
    def test_a_header_row_moves_into_a_thead(self):
        page = (
            "<table><tr><th>Name</th><th><code>x</code> y</th></tr><tr><td>1</td><td>2</td></tr></table>"
            "<table><tr><td>bare</td></tr></table>"
        )
        text, headed = MODULE.HEADER_ROW.subn(HEAD, page)
        self.assertEqual(headed, 1)
        self.assertEqual(
            text,
            "<table><thead><tr><th>Name</th><th><code>x</code> y</th></tr></thead><tbody>"
            "<tr><td>1</td><td>2</td></tr></table><table><tr><td>bare</td></tr></table>",
        )

    def test_only_a_closed_single_line_header_row_matches(self):
        for page in (
            "<table><tr><th>open</tr></table>",
            "<table><tr><th>a\nb</th></tr>",
            "<table><tr><td>1</td><th>2</th></tr>",
            "<table><tr>" + "<th>" * 10000,
        ):
            with self.subTest(page=page[:40]):
                self.assertIsNone(MODULE.HEADER_ROW.search(page))


class EntryLinks(unittest.TestCase):
    def test_a_link_to_an_entry_document_names_its_directory(self):
        page = '<a href="/rooms/app/index.html">app</a> <a href="/index.html">home</a>'
        self.assertEqual(
            MODULE.ENTRY_HREF.sub(r'href="\1"', page), '<a href="/rooms/app/">app</a> <a href="/">home</a>'
        )

    def test_other_links_keep_their_form(self):
        for page in (
            '<a href="/rooms/app/">app</a>',
            '<a href="https://example.test/index.html">away</a>',
            '<a href="/rooms/app/index.htm">near</a>',
            '<a href="/rooms/app/myindex.html">near</a>',
            '<a href="index.html">relative</a>',
        ):
            with self.subTest(page=page):
                self.assertEqual(MODULE.ENTRY_HREF.sub(r'href="\1"', page), page)

    def test_the_markdown_twin_names_the_same_address(self):
        self.assertEqual(
            MODULE.assetAddress("https://glowcap.org", "rooms/app/index.html"), "https://glowcap.org/rooms/app/"
        )
        self.assertEqual(MODULE.assetAddress("https://glowcap.org", "install.sh"), "https://glowcap.org/install.sh")
        body = "open [the page]($link.siteAsset('rooms/app/index.html')) now"
        self.assertEqual(
            MODULE.ASSET_REF.sub(lambda m: f"({MODULE.assetAddress('https://glowcap.org', m.group(1))})", body),
            "open [the page](https://glowcap.org/rooms/app/) now",
        )


if __name__ == "__main__":
    unittest.main()
