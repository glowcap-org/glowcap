"""Shared Python path helpers for cross-language demo clients."""

from __future__ import annotations

import pathlib
import sys

_REPO_DEPTH_FROM_DEMO = 3  # examples/apps/_demo -> repository root


def repo_root(*, from_file: str | None = None, depth: int | None = None) -> pathlib.Path:
    """Return the repository root from this helper or from ``from_file`` at ``depth``."""
    start = pathlib.Path(from_file or __file__).resolve()
    if depth is not None:
        return start.parents[depth]
    return start.parents[_REPO_DEPTH_FROM_DEMO]


def add_bindings_path(*, from_file: str | None = None, depth: int | None = None) -> None:
    """Prepend ``bindings/python`` on the repository root to ``sys.path``."""
    sys.path.insert(0, str(repo_root(from_file=from_file, depth=depth) / "bindings" / "python"))
