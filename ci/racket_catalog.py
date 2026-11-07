"""Point the Racket package catalog at a release's binding archive, for publish.yml.

  python3 ci/racket_catalog.py publish TAG

The catalog at pkgs.racket-lang.org holds one entry per package: a source URL,
the checksum the catalog read from it, and the description and tags of
bindings/racket/catalog.json. Each release ships the binding as
glowcap-racket-TAG.zip beside its SHA-1 .CHECKSUM, and this program sets the
entry's source to that archive through the catalog's own API (the call its
website makes when a person saves the edit form), then waits until the public
catalog has read the archive and states its checksum. An entry that already
names the release is left alone, so a rerun finishes an interrupted
publication. An unknown package is created; a known one is modified.

Inputs: GITHUB_REPOSITORY (owner/name), and RACKET_CATALOG_EMAIL and
RACKET_CATALOG_PASSWORD, the catalog account that owns the entry, which the
racket environment of publish.yml holds. Only that environment's reviewer can
start the job, and the catalog offers no other credential. Exit 0 once the
public catalog states the release's archive and checksum, 2 on a bad argument
or a missing input, and 1 when the catalog refuses the credentials or the edit,
cannot read the archive, or does not show the edit within the deadline.
Nothing else is written. ci/racket_catalog_test.py drives every path against
a fake catalog.
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "glowcap"
CATALOG = f"https://pkgs.racket-lang.org/pkg/{PACKAGE}.json"
PAGE = f"https://pkgs.racket-lang.org/package/{PACKAGE}"
API = "https://pkgd.racket-lang.org/api/package/modify-all"
EMAIL, PASSWORD = "RACKET_CATALOG_EMAIL", "RACKET_CATALOG_PASSWORD"
METADATA = "bindings/racket/catalog.json"
TIMEOUT = 30
# The catalog re-reads the archive as soon as the edit is saved and rebuilds
# its public pages on a schedule of minutes, so the wait is bounded, not short.
DEADLINE_SECONDS = 20 * 60
POLL_SECONDS = 30


class Refused(Exception):
    """The catalog answered, and the answer is not the release."""


def package_source(slug, tag):
    """The release archive the catalog entry names: the one authority for its URL."""
    return f"https://github.com/{slug}/releases/download/{tag}/{PACKAGE}-racket-{tag}.zip"


def fetch(url):
    """GET url: (status, body). An HTTP error status is an answer, not a failure."""
    request = urllib.request.Request(url, headers={"User-Agent": "glowcap-racket-catalog"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        try:
            return error.code, error.read().decode(errors="replace")
        finally:
            error.close()


def post(url, body, email, password):
    """POST a JSON body with the account as HTTP Basic credentials, as the catalog's website does."""
    token = base64.b64encode(f"{email}:{password}".encode()).decode()
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={
            "User-Agent": "glowcap-racket-catalog",
            "Content-Type": "application/json",
            "Authorization": f"Basic {token}",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return response.read().decode()


def metadata(root):
    """The description and tags bindings/racket/catalog.json states for the entry."""
    path = root / METADATA
    data = json.loads(path.read_text())
    description, tags = data.get("description"), data.get("tags")
    if not isinstance(description, str) or not description.strip():
        raise ValueError(f"{METADATA} has no description")
    if not isinstance(tags, list) or not tags or not all(isinstance(tag, str) and tag for tag in tags):
        raise ValueError(f"{METADATA} has no tags")
    return description, tags


def release_checksum(source):
    """The SHA-1 the release publishes beside the archive, which the catalog must come to state."""
    status, body = fetch(f"{source}.CHECKSUM")
    checksum = body.strip()
    if status != 200 or len(checksum) != 40 or any(char not in "0123456789abcdef" for char in checksum):
        raise Refused(f"the release has no readable checksum at {source}.CHECKSUM (HTTP {status})")
    return checksum


def entry():
    """The public catalog's entry, or None before the package exists."""
    status, body = fetch(CATALOG)
    if status == 404:
        return None
    if status != 200:
        raise Refused(f"the catalog answered HTTP {status} for {CATALOG}")
    return json.loads(body)


def states(found, source, checksum):
    """Whether the public catalog names the release's archive and has read it."""
    return (
        found is not None
        and found.get("source") == source
        and found.get("checksum") == checksum
        and not found.get("checksum-error")
    )


def save(found, source, description, tags, email, password):
    """Set the entry's source; '' as the old name creates a package the catalog lacks."""
    body = {
        "pkg": "" if found is None else PACKAGE,
        "name": PACKAGE,
        "description": description,
        "source": source,
        "tags": tags,
    }
    answer = post(API, body, email, password)
    if answer.strip() != "true":
        if answer.strip() in ('"not-authenticated"', '"authentication-required"'):
            raise Refused(f"the catalog refused the credentials in {EMAIL} and {PASSWORD}")
        raise Refused(f"the catalog refused the edit of {PACKAGE} (answer {answer.strip()[:80]}): check {PAGE}")


def wait(source, checksum, clock=time.monotonic, sleep=time.sleep):
    """Poll the public catalog until it states the release, within the deadline."""
    deadline = clock() + DEADLINE_SECONDS
    while True:
        found = entry()
        if states(found, source, checksum):
            return
        # An error on the previous source is history; one on the release's
        # archive is the catalog's answer.
        error = (found or {}).get("checksum-error")
        if error and found.get("source") == source:
            raise Refused(f"the catalog could not read {source}: {error}")
        if clock() >= deadline:
            raise Refused(f"the catalog did not show {source} with checksum {checksum} within the deadline")
        sleep(POLL_SECONDS)


def publish(slug, tag, email, password, root=ROOT, clock=time.monotonic, sleep=time.sleep):
    source = package_source(slug, tag)
    checksum = release_checksum(source)
    found = entry()
    if states(found, source, checksum):
        print(f"racket-catalog: {PACKAGE} already names {source}")
        return
    description, tags = metadata(root)
    save(found, source, description, tags, email, password)
    print(f"racket-catalog: {'created' if found is None else 'updated'} {PACKAGE} with source {source}", flush=True)
    wait(source, checksum, clock, sleep)
    print(f"racket-catalog: the catalog states {source} with checksum {checksum}")


def environment(name):
    value = os.environ.get(name, "")
    if not value:
        raise ValueError(f"{name} is not set")
    return value


def release_tag(value):
    if not value.startswith("v") or value.count(".") != 2 or not value[1:].replace(".", "").isdigit():
        raise argparse.ArgumentTypeError(f"not a release tag: {value}")
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    modes = parser.add_subparsers(dest="mode", required=True)
    modes.add_parser("publish").add_argument("tag", type=release_tag)
    args = parser.parse_args(argv)
    publish(environment("GITHUB_REPOSITORY"), args.tag, environment(EMAIL), environment(PASSWORD))


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        print(f"racket-catalog: {error}", file=sys.stderr)
        sys.exit(2)
    except Refused as error:
        print(f"racket-catalog: {error}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as error:
        print(f"racket-catalog: cannot reach the catalog: {error.reason}", file=sys.stderr)
        sys.exit(1)
