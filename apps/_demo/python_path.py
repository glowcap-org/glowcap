"""Locate the repository root and `bindings/python` for demo clients."""

from __future__ import annotations

import pathlib
import sys


def repo_root() -> pathlib.Path:
    """Return the repository root, located from this file's own path.

    Self-locating on purpose: this file sits at ``apps/_demo/python_path.py``,
    so the root is always two directories up, no matter where the caller
    lives. A caller-supplied depth broke every app client once when the apps
    tree moved.
    """
    return pathlib.Path(__file__).resolve().parents[2]


def add_bindings_path() -> None:
    """Prepend ``bindings/python`` on the repository root to ``sys.path``."""
    sys.path.insert(0, str(repo_root() / "bindings" / "python"))
