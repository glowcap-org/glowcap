"""Release transport policy through urllib's real redirect machinery.

The handlers supply responses without a network or native SDK. Only socket I/O
is replaced: urllib still decides whether to follow each redirect.
"""

import email.message
import hashlib
import importlib.util
import io
import os
import tempfile
import unittest
import urllib.request
import urllib.response
from pathlib import Path
from unittest import mock

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
                io.BytesIO(b"" if redirect else b"archive"), headers, request.full_url, code if redirect else 200
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
                        self.download("https://release.invalid/asset", "http://release.invalid/payload", code, insecure)
                    self.assertEqual(self.requests, ["https://release.invalid/asset"])

    def test_https_redirect_to_another_https_host_succeeds(self):
        self.download("https://release.invalid/asset", "https://cdn.invalid/payload")
        self.assertEqual(self.requests, ["https://release.invalid/asset", "https://cdn.invalid/payload"])

    def test_explicit_http_test_mirror_still_follows_http_redirects(self):
        self.download("http://mirror.invalid/asset", "http://mirror.invalid/payload", insecure=True)
        self.assertEqual(self.requests, ["http://mirror.invalid/asset", "http://mirror.invalid/payload"])


class ReleaseChecksumTest(unittest.TestCase):
    def test_staged_archive_is_verified_without_reading_it_all_into_memory(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "archive.tar.gz"
            for payload in (b"", b"archive", bytes(range(256)) * 4097):
                with self.subTest(size=len(payload)):
                    archive.write_bytes(payload)
                    checksum = hashlib.sha256(payload).hexdigest()
                    with mock.patch.object(Path, "read_bytes", side_effect=AssertionError("whole archive read")):
                        RESOLVE._verify_sha256(f"{checksum} *archive.tar.gz\n", "archive.tar.gz", archive)

    def test_mismatch_and_missing_checksum_still_refuse(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "archive.tar.gz"
            archive.write_bytes(b"archive")
            with self.assertRaisesRegex(OSError, "SHA256 mismatch"):
                RESOLVE._verify_sha256(f"{'0' * 64} archive.tar.gz", "archive.tar.gz", archive)
            with self.assertRaisesRegex(OSError, "no entry"):
                RESOLVE._verify_sha256("", "archive.tar.gz", archive)


class ResolutionNoteTest(unittest.TestCase):
    def test_soft_failure_is_retained_not_printed(self):
        notes = []
        stderr = io.StringIO()
        with mock.patch.dict(os.environ, {"GLOWCAP_STRICT": ""}), mock.patch("sys.stderr", stderr):
            RESOLVE._soft_fail("first")
            RESOLVE._install_note_sink(notes.append)
            RESOLVE._soft_fail("second")
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(notes, ["first (soft-fail)", "second (soft-fail)"])
        self.assertEqual(RESOLVE._pending_notes, [])

    def test_resolution_keeps_its_notes_beside_its_path_after_the_sink(self):
        # The journal's sink takes every note, and a load that fails later
        # still finds the notes its own resolution made.
        with (
            mock.patch.object(RESOLVE, "_note_sink", lambda _note: None),
            mock.patch.object(RESOLVE, "_lib_dir", return_value=None),
            mock.patch.object(RESOLVE.sys, "platform", "linux"),
        ):
            bare = RESOLVE._lib_path("glowcap_notes_probe")
        self.assertEqual(RESOLVE._resolution_notes(bare), (f"loading bare {bare} via the OS search path",))
        with tempfile.TemporaryDirectory() as directory:
            with (
                mock.patch.object(RESOLVE, "_note_sink", lambda _note: None),
                mock.patch.object(RESOLVE, "_lib_dir", return_value=Path(directory)),
            ):
                placed = RESOLVE._lib_path("glowcap_notes_probe")
            self.assertEqual(RESOLVE._resolution_notes(placed), ())
        self.assertEqual(RESOLVE._resolution_notes(bare), (f"loading bare {bare} via the OS search path",))

    def test_strict_soft_failure_raises(self):
        with mock.patch.dict(os.environ, {"GLOWCAP_STRICT": "1"}):
            with self.assertRaisesRegex(RuntimeError, "^refused$"):
                RESOLVE._soft_fail("refused")


if __name__ == "__main__":
    unittest.main()
