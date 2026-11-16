"""The site normalizer's rewrites: every header row gets a thead, in a form that
reads each cell once, and a link to an exported application's entry document
names its directory, in HTML and in the markdown twin alike.

Run by infrastructure-check. tools/gen/site_normalize.py runs under `zig build
site` on rendered pages, and this is the focused proof of its regexes.
"""

import importlib.util
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[2]

SCRIPT = ROOT / "tools/gen/site_normalize.py"
SPEC = importlib.util.spec_from_file_location("site_normalize", SCRIPT)
assert SPEC is not None and SPEC.loader is not None, "the script loads as a module"
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
HEAD = r"<table><thead><tr>\1</tr></thead><tbody>"


class ExportedApplications(unittest.TestCase):
    def test_the_site_config_lists_each_exported_application(self):
        applications = MODULE.exportedApplications(ROOT)
        self.assertIn("rooms/app/", applications)
        self.assertIn("ocapnviz/", applications)
        # A static file is served as it is too, and it is no application.
        self.assertTrue(all(entry.endswith("/") for entry in applications), applications)


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


class DiagramFigures(unittest.TestCase):
    def test_scoped_svg_preserves_caption_and_accessible_name(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "drawing.svg").write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 10">'
                "<style>.node{fill:var(--ink,red)}</style>"
                '<rect id="node" class="node" width="20" height="10"/></svg>'
            )
            page = '<figure><img alt="A &amp; B" src="/drawing.svg"><figcaption>Two peers</figcaption></figure>'
            page += '<script id="preview-diagrams">previewOnly()</script>'
            result = MODULE.inlineDiagrams(page, root / "concepts/index.html", root)
            self.assertIn('role="img" aria-label="A &amp; B"', result)
            self.assertIn('<template shadowrootmode="open">', result)
            self.assertIn('viewBox="0 0 20 10"', result)
            self.assertIn(".node{fill:var(--ink,red)}", result)
            self.assertIn("</template></span><figcaption>Two peers</figcaption></figure>", result)
            self.assertNotIn("<img", result)
            self.assertNotIn("previewOnly", result)
            self.assertEqual(MODULE.inlineDiagrams(result, root / "concepts/index.html", root), result)
            decorative = MODULE.inlineDiagrams(page.replace("A &amp; B", ""), root / "index.html", root)
            self.assertIn('aria-hidden="true"', decorative)

    def test_relative_asset_and_external_image_keep_their_ownership(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "drawing.svg").write_text('<svg xmlns="http://www.w3.org/2000/svg"/>')
            page = '<figure><img alt="" src="../drawing.svg"></figure>'
            result = MODULE.inlineDiagrams(page, root / "concepts/index.html", root)
            self.assertIn('shadowrootmode="open"', result)
            for src in ("https://example.test/drawing.svg", "//example.test/drawing.svg", "/photo.webp"):
                page = f'<figure><img alt="" src="{src}"></figure>'
                self.assertEqual(MODULE.inlineDiagrams(page, root / "index.html", root), page)

    def test_broken_authored_diagram_refuses_the_build(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            for content in ("<html/>", "<svg"):
                (root / "broken.svg").write_text(content)
                with self.subTest(content=content), self.assertRaises(SystemExit):
                    MODULE.inlineDiagrams('<figure><img alt="" src="/broken.svg">', root / "index.html", root)
            for src in ("/missing.svg", "../outside.svg"):
                with self.subTest(src=src), self.assertRaises(SystemExit):
                    MODULE.inlineDiagrams(f'<figure><img alt="" src="{src}">', root / "index.html", root)


if __name__ == "__main__":
    unittest.main()
