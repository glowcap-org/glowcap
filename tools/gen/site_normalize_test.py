"""The site normalizer's table header rewrite: every header row gets a thead, in a form that reads each cell once.

Run by infrastructure-check. tools/gen/site_normalize.py runs under `zig build
site` on rendered pages, and this is the focused proof of its header-row regex.
"""

import importlib.util
import unittest

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

SCRIPT = ROOT / 'tools/gen/site_normalize.py'
SPEC = importlib.util.spec_from_file_location('site_normalize', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
HEAD = r'<table><thead><tr>\1</tr></thead><tbody>'


class HeaderRows(unittest.TestCase):
    def test_a_header_row_moves_into_a_thead(self):
        page = ('<table><tr><th>Name</th><th><code>x</code> y</th></tr><tr><td>1</td><td>2</td></tr></table>'
                '<table><tr><td>bare</td></tr></table>')
        text, headed = MODULE.HEADER_ROW.subn(HEAD, page)
        self.assertEqual(headed, 1)
        self.assertEqual(text, '<table><thead><tr><th>Name</th><th><code>x</code> y</th></tr></thead><tbody>'
                               '<tr><td>1</td><td>2</td></tr></table><table><tr><td>bare</td></tr></table>')

    def test_only_a_closed_single_line_header_row_matches(self):
        for page in ('<table><tr><th>open</tr></table>', '<table><tr><th>a\nb</th></tr>',
                     '<table><tr><td>1</td><th>2</th></tr>', '<table><tr>' + '<th>' * 10000):
            with self.subTest(page=page[:40]):
                self.assertIsNone(MODULE.HEADER_ROW.search(page))


if __name__ == '__main__':
    unittest.main()
