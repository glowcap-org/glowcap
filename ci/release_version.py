"""The release version format, read by every program that accepts a version.

Every Python program under ci/ and tools/ that accepts or checks a version
imports this module. Release publication accepts only prerelease versions,
0.x.y with no leading zeros, tagged v0.x.y (docs/maintaining.md). Each caller
keeps its own refusal message. ci/release_version_test.py holds the format.
"""

import re

_VERSION = re.compile(r"0\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")


def accepted(version):
    """Whether `version` is a prerelease version such as 0.1.2."""
    return isinstance(version, str) and _VERSION.fullmatch(version) is not None


def of_tag(tag):
    """The version a release tag such as v0.1.2 names, or None for any other value."""
    if isinstance(tag, str) and tag.startswith("v") and accepted(tag[1:]):
        return tag[1:]
    return None


def version_key(version):
    """Numeric comparison key for an accepted version."""
    return tuple(map(int, version.split(".")))


def highest_public_tag(repository, gh):
    """Select the highest supported public version, including prereleases and every page."""
    tags = gh(
        "api",
        f"repos/{repository}/releases?per_page=100",
        "--paginate",
        "--jq",
        ".[] | select(.draft == false) | .tag_name",
    )
    return max((tag for tag in tags.splitlines() if of_tag(tag)), key=lambda tag: version_key(tag[1:]), default="")
