"""Build and import the Python wheel outside the source tree.

Source-tree dogfood cannot detect a private package omitted by setuptools.
This proof inspects the shipped archive, extracts it without installing into
the developer environment, and verifies the public/private type identities in
an isolated interpreter.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile


def main() -> int:
    root = Path(__file__).resolve().parents[3]
    project = root / "bindings" / "python"
    with tempfile.TemporaryDirectory(prefix="pancake-python-wheel-") as raw_tmp:
        tmp = Path(raw_tmp)
        staged = tmp / "project"
        shutil.copytree(
            project,
            staged,
            ignore=shutil.ignore_patterns(".venv", "build", "*.egg-info", "__pycache__"),
        )
        wheel_dir = tmp / "wheel"
        wheel_dir.mkdir()
        subprocess.run(
            [
                "uv",
                "build",
                "--wheel",
                "--no-build-logs",
                "--out-dir",
                str(wheel_dir),
                str(staged),
            ],
            cwd=tmp,
            check=True,
        )
        wheels = tuple(wheel_dir.glob("*.whl"))
        assert len(wheels) == 1, wheels
        site = tmp / "site"
        site.mkdir()
        with zipfile.ZipFile(wheels[0]) as wheel:
            names = set(wheel.namelist())
            required = {
                "pancake/_host/__init__.py",
                "pancake/_host/lifecycle.py",
                "pancake/_host/progress.py",
                "pancake/_host/publication.py",
                "pancake/_driver/__init__.py",
                "pancake/_loop/__init__.py",
                "pancake/_loop/configuration.py",
                "pancake/_loop/dialing.py",
                "pancake/_loop/errors.py",
                "pancake/_loop/lifecycle.py",
                "pancake/_loop/listeners.py",
                "pancake/_loop/progress.py",
                "pancake/_loop/sessions.py",
                "pancake/_session/__init__.py",
                "pancake/_session/lifecycle.py",
                "pancake/_session/verbs.py",
            }
            missing = required - names
            assert not missing, f"wheel omitted private ownership packages: {missing}"
            wheel.extractall(site)

        env = os.environ.copy()
        env["PYTHONPATH"] = str(site)
        env["PANCAKE_LIB_DIR"] = str(root / "zig-out" / "lib")
        subprocess.run(
            [
                sys.executable,
                "-c",
                """
import importlib
import pancake
host = importlib.import_module("pancake._host")
host_lifecycle = importlib.import_module("pancake._host.lifecycle")
host_progress = importlib.import_module("pancake._host.progress")
host_publication = importlib.import_module("pancake._host.publication")
loop = importlib.import_module("pancake._loop")
loop_dialing = importlib.import_module("pancake._loop.dialing")
loop_lifecycle = importlib.import_module("pancake._loop.lifecycle")
loop_listeners = importlib.import_module("pancake._loop.listeners")
loop_progress = importlib.import_module("pancake._loop.progress")
loop_sessions = importlib.import_module("pancake._loop.sessions")
session = importlib.import_module("pancake._session")
lifecycle = importlib.import_module("pancake._session.lifecycle")
verbs = importlib.import_module("pancake._session.verbs")
assert pancake.Session is session.Session
assert pancake.Host is host.Host
assert loop.DriverLoop.__module__ == "pancake._loop"
assert pancake.PartnerIdentity is session.PartnerIdentity
assert pancake.SendRedeemingResult is session.SendRedeemingResult
assert session.Session.__module__ == "pancake._session"
assert session.PartnerIdentity.__module__ == "pancake._session"
assert session.SendRedeemingResult.__module__ == "pancake._session"
host_mixins = (
    host_lifecycle._LifecycleMixin,
    host_progress._ProgressMixin,
    host_publication._PublicationMixin,
)
loop_mixins = (
    loop_dialing._DialingMixin,
    loop_lifecycle._LifecycleMixin,
    loop_listeners._ListenersMixin,
    loop_progress._ProgressMixin,
    loop_sessions._SessionsMixin,
)
for base in (*host_mixins, *loop_mixins, lifecycle._LifecycleMixin, verbs._VerbsMixin):
    assert "__init__" not in base.__dict__
    assert "__del__" not in base.__dict__
for mixins in (host_mixins, loop_mixins):
    owned = [
        {name for name in base.__dict__ if not name.startswith("__")}
        for base in mixins
    ]
    for index, names in enumerate(owned):
        assert all(names.isdisjoint(other) for other in owned[index + 1 :])
lifecycle_names = {name for name in lifecycle._LifecycleMixin.__dict__ if not name.startswith("__")}
verb_names = {name for name in verbs._VerbsMixin.__dict__ if not name.startswith("__")}
assert lifecycle_names.isdisjoint(verb_names)
""",
            ],
            cwd=tmp,
            env=env,
            check=True,
        )
    print("python artifact smoke OK: wheel contains every ownership package")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
