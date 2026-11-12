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
