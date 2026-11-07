"""ci/racket_catalog.py points the Racket catalog at a release's binding archive.

The program runs against a fake catalog: the release's checksum file, a
sequence of public entries, and the API's answer to an edit. The tests prove
that an entry naming the release is left alone, that a missing package is
created and a stale one modified with the tree's description and tags, that
the program waits for the public catalog to state the archive's checksum and
stops at the deadline, and that every refusal names its cause. The one real
request shape, HTTP Basic credentials on a JSON POST, is checked against a
captured request. Nothing here reaches the catalog or GitHub.
"""

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import racket_catalog as program

ROOT = Path(__file__).resolve().parents[1]
SLUG, TAG = "owner/project", "v1.2.3"
SOURCE = program.package_source(SLUG, TAG)
CHECKSUM = "a" * 40
STALE = {"source": "https://github.com/owner/project.git?path=bindings/racket#v1.2.2", "checksum": "b" * 40}
CURRENT = {"source": SOURCE, "checksum": CHECKSUM, "checksum-error": False}
DESCRIPTION, TAGS = program.metadata(ROOT)


class Catalog:
    """The release's checksum file, the public entry over time, and the edit API."""

    def __init__(self, entries, answer="true", checksum=(200, CHECKSUM)):
        self.entries, self.answer, self.checksum = list(entries), answer, checksum
        self.posts, self.fetched, self.slept = [], [], []
        self.now = 0.0

    def fetch(self, url):
        self.fetched.append(url)
        if url.endswith(".CHECKSUM"):
            return self.checksum
        if url == program.CATALOG:
            found = self.entries.pop(0) if len(self.entries) > 1 else self.entries[0]
            return (404, "not found") if found is None else (200, json.dumps(found))
        raise AssertionError(f"unexpected fetch {url}")

    def post(self, url, body, email, password):
        self.posts.append((url, body, email, password))
        return self.answer

    def sleep(self, seconds):
        self.slept.append(seconds)
        self.now += seconds

    def clock(self):
        return self.now


def publish(catalog, root=ROOT):
    out = io.StringIO()
    with (
        mock.patch.object(program, "fetch", catalog.fetch),
        mock.patch.object(program, "post", catalog.post),
        contextlib.redirect_stdout(out),
    ):
        program.publish(SLUG, TAG, "owner@example.invalid", "secret", root, catalog.clock, catalog.sleep)
    return out.getvalue()


class PublishTest(unittest.TestCase):
    def test_an_entry_naming_the_release_is_left_alone(self):
        catalog = Catalog([CURRENT])
        out = publish(catalog)
        self.assertEqual(catalog.posts, [])
        self.assertIn(f"already names {SOURCE}", out)
        self.assertEqual(catalog.fetched, [f"{SOURCE}.CHECKSUM", program.CATALOG])

    def test_a_missing_package_is_created_and_awaited(self):
        catalog = Catalog([None, None, CURRENT])
        out = publish(catalog)
        self.assertEqual(len(catalog.posts), 1)
        url, body, email, password = catalog.posts[0]
        self.assertEqual(url, program.API)
        self.assertEqual(
            body, {"pkg": "", "name": "glowcap", "description": DESCRIPTION, "source": SOURCE, "tags": TAGS}
        )
        self.assertEqual((email, password), ("owner@example.invalid", "secret"))
        self.assertIn("created glowcap", out)
        self.assertIn(f"states {SOURCE} with checksum {CHECKSUM}", out)
        self.assertEqual(catalog.slept, [program.POLL_SECONDS])

    def test_a_stale_entry_is_modified_in_place(self):
        catalog = Catalog([STALE, STALE, {**STALE, "checksum-error": False}, CURRENT])
        out = publish(catalog)
        self.assertEqual(catalog.posts[0][1]["pkg"], "glowcap")
        self.assertIn("updated glowcap", out)
        self.assertEqual(catalog.slept, [program.POLL_SECONDS, program.POLL_SECONDS])

    def test_an_old_read_error_does_not_end_the_wait(self):
        failed = {**STALE, "checksum-error": "git-checkout: won't extract a link"}
        catalog = Catalog([failed, failed, CURRENT])
        publish(catalog)
        self.assertEqual(len(catalog.slept), 1)

    def test_refusals_name_their_cause(self):
        unread = {"source": SOURCE, "checksum": "", "checksum-error": "download failed"}
        cases = (
            ("credentials", Catalog([STALE], answer='"not-authenticated"'), "refused the credentials"),
            ("no session", Catalog([STALE], answer='"authentication-required"'), "refused the credentials"),
            (
                "edit",
                Catalog([STALE], answer="false"),
                f"refused the edit of glowcap (answer false): check {program.PAGE}",
            ),
            ("unreadable archive", Catalog([STALE, unread]), f"could not read {SOURCE}: download failed"),
            ("no checksum file", Catalog([STALE], checksum=(404, "")), f"no readable checksum at {SOURCE}.CHECKSUM"),
            ("bad checksum file", Catalog([STALE], checksum=(200, "xyz")), "no readable checksum"),
            ("catalog down", Catalog([{"status": 500}]), "answered HTTP 500"),
        )
        for name, catalog, expected in cases:
            with self.subTest(name):
                if name == "catalog down":
                    catalog.fetch = lambda url, c=catalog: (500, "") if url == program.CATALOG else c.checksum
                with self.assertRaises(program.Refused) as raised:
                    publish(catalog)
                self.assertIn(expected, str(raised.exception))

    def test_the_wait_stops_at_the_deadline(self):
        catalog = Catalog([STALE])
        with self.assertRaises(program.Refused) as raised:
            publish(catalog)
        self.assertIn("within the deadline", str(raised.exception))
        self.assertEqual(sum(catalog.slept), program.DEADLINE_SECONDS)
        self.assertEqual(len(catalog.posts), 1)

    def test_the_tree_states_the_description_and_tags(self):
        self.assertTrue(DESCRIPTION.startswith("glowcap for Racket"))
        self.assertIn("ocapn", TAGS)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "bindings/racket").mkdir(parents=True)
            for text, message in (
                ('{"description": "", "tags": ["a"]}', "no description"),
                ('{"description": "x", "tags": []}', "no tags"),
                ('{"description": "x", "tags": ["a", 1]}', "no tags"),
            ):
                with self.subTest(text):
                    (root / program.METADATA).write_text(text)
                    with self.assertRaisesRegex(ValueError, message):
                        program.metadata(root)
            (root / program.METADATA).write_text('{"description": "x", "tags": ["a"]}')
            catalog = Catalog([STALE], answer="false")
            with self.assertRaises(program.Refused):
                publish(catalog, root)
            self.assertEqual(catalog.posts[0][1]["description"], "x")


class RequestTest(unittest.TestCase):
    def test_the_edit_is_a_json_post_with_basic_credentials(self):
        captured = []

        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *_):
                self.close()

        def urlopen(request, timeout):
            captured.append((request, timeout))
            return Response(b"true")

        with mock.patch.object(program.urllib.request, "urlopen", urlopen):
            answer = program.post(program.API, {"pkg": "glowcap"}, "owner@example.invalid", "secret")
        self.assertEqual(answer, "true")
        request, timeout = captured[0]
        self.assertEqual((request.full_url, request.get_method(), timeout), (program.API, "POST", program.TIMEOUT))
        self.assertEqual(json.loads(request.data), {"pkg": "glowcap"})
        self.assertEqual(request.get_header("Content-type"), "application/json")
        self.assertEqual(request.get_header("Authorization"), "Basic b3duZXJAZXhhbXBsZS5pbnZhbGlkOnNlY3JldA==")

    def test_the_source_is_the_release_archive(self):
        self.assertEqual(SOURCE, "https://github.com/owner/project/releases/download/v1.2.3/glowcap-racket-v1.2.3.zip")
        self.assertEqual(program.CATALOG, "https://pkgs.racket-lang.org/pkg/glowcap.json")


class CommandTest(unittest.TestCase):
    def run_program(self, *argv, **env):
        clean = {key: value for key, value in os.environ.items() if not key.startswith("RACKET_CATALOG_")}
        return subprocess.run(
            [sys.executable, "ci/racket_catalog.py", *argv],
            cwd=ROOT,
            env={**clean, "GITHUB_REPOSITORY": SLUG, **env},
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_a_bad_tag_or_missing_input_exits_2_before_any_request(self):
        result = self.run_program("publish", "1.2.3", RACKET_CATALOG_EMAIL="e", RACKET_CATALOG_PASSWORD="p")
        self.assertEqual(result.returncode, 2)
        self.assertIn("not a release tag", result.stderr)
        result = self.run_program("publish", TAG, RACKET_CATALOG_EMAIL="e")
        self.assertEqual(result.returncode, 2)
        self.assertIn("RACKET_CATALOG_PASSWORD is not set", result.stderr)
        result = self.run_program("publish", TAG, RACKET_CATALOG_PASSWORD="p")
        self.assertEqual(result.returncode, 2)
        self.assertIn("RACKET_CATALOG_EMAIL is not set", result.stderr)


if __name__ == "__main__":
    unittest.main()
