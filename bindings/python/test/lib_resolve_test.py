"""Release transport policy through urllib's real redirect machinery.

The handlers supply responses without a network or native SDK. Only socket I/O
is replaced: urllib still decides whether to follow each redirect.
"""

import email.message
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.request
import urllib.response

SPEC = importlib.util.spec_from_file_location(
    "lib_resolve", Path(__file__).resolve().parents[1] / "glowcap/_lib_resolve.py"
)
RESOLVE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RESOLVE)


class ReleaseTransportTest(unittest.TestCase):
    def download(self, start, destination, code=302, insecure=False):
        requests = []

        def respond(request):
            requests.append(request.full_url)
            headers = email.message.Message()
            redirect = request.full_url == start
            if redirect:
                headers["Location"] = destination
            response = urllib.response.addinfourl(
                io.BytesIO(b"" if redirect else b"archive"), headers,
                request.full_url, code if redirect else 200,
            )
            response.msg = "Found" if redirect else "OK"
            return response

        with (
            tempfile.TemporaryDirectory() as directory,
            mock.patch.dict(os.environ, {"GLOWCAP_ALLOW_INSECURE": "1" if insecure else "0"}),
            mock.patch("urllib.request._opener", None),
            mock.patch.object(urllib.request.HTTPSHandler, "https_open", side_effect=respond),
            mock.patch.object(urllib.request.HTTPHandler, "http_open", side_effect=respond),
        ):
            output = Path(directory) / "archive"
            try:
                RESOLVE._download(start, output, max_bytes=32, user_agent="test")
            finally:
                self.requests = requests
            self.assertEqual(output.read_bytes(), b"archive")

    def test_https_redirect_cannot_downgrade_even_with_insecure_override(self):
        for code in (301, 302, 303, 307, 308):
            for insecure in (False, True):
                with self.subTest(code=code, insecure=insecure):
                    with self.assertRaisesRegex(RuntimeError, "non-HTTPS"):
                        self.download("https://release.invalid/asset", "http://release.invalid/payload",
                                      code, insecure)
                    self.assertEqual(self.requests, ["https://release.invalid/asset"])

    def test_https_redirect_to_another_https_host_succeeds(self):
        self.download("https://release.invalid/asset", "https://cdn.invalid/payload")
        self.assertEqual(self.requests, ["https://release.invalid/asset", "https://cdn.invalid/payload"])

    def test_explicit_http_test_mirror_still_follows_http_redirects(self):
        self.download("http://mirror.invalid/asset", "http://mirror.invalid/payload", insecure=True)
        self.assertEqual(self.requests, ["http://mirror.invalid/asset", "http://mirror.invalid/payload"])


if __name__ == "__main__":
    unittest.main()
