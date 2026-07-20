"""Shared tools demo check helper."""

from __future__ import annotations

import sys


def make_check(nick: str):
    def check(label: str, ok: bool) -> None:
        print(f"{nick}: {'ok' if ok else 'FAIL'}, {label}")
        if not ok:
            sys.exit(1)

    return check
