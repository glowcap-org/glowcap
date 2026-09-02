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
    with tempfile.TemporaryDirectory(prefix="glowcap-python-wheel-") as raw_tmp:
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
                "glowcap/_host/__init__.py",
                "glowcap/_host/lifecycle.py",
                "glowcap/_host/progress.py",
                "glowcap/_host/publication.py",
                "glowcap/_driver/__init__.py",
                "glowcap/_loop/__init__.py",
                "glowcap/_loop/configuration.py",
                "glowcap/_loop/dialing.py",
                "glowcap/_loop/errors.py",
                "glowcap/_loop/lifecycle.py",
                "glowcap/_loop/listeners.py",
                "glowcap/_loop/progress.py",
                "glowcap/_loop/sessions.py",
                "glowcap/_session/__init__.py",
                "glowcap/_session/lifecycle.py",
                "glowcap/_session/verbs.py",
            }
            missing = required - names
            assert not missing, f"wheel omitted private ownership packages: {missing}"
            wheel.extractall(site)

        env = os.environ.copy()
        env["PYTHONPATH"] = str(site)
        env["GLOWCAP_LIB_DIR"] = str(root / "zig-out" / "lib")
        subprocess.run(
            [
                sys.executable,
                "-c",
                """
import importlib
import glowcap
host = importlib.import_module("glowcap._host")
host_lifecycle = importlib.import_module("glowcap._host.lifecycle")
host_progress = importlib.import_module("glowcap._host.progress")
host_publication = importlib.import_module("glowcap._host.publication")
loop = importlib.import_module("glowcap._loop")
loop_dialing = importlib.import_module("glowcap._loop.dialing")
loop_lifecycle = importlib.import_module("glowcap._loop.lifecycle")
loop_listeners = importlib.import_module("glowcap._loop.listeners")
loop_progress = importlib.import_module("glowcap._loop.progress")
loop_sessions = importlib.import_module("glowcap._loop.sessions")
session = importlib.import_module("glowcap._session")
lifecycle = importlib.import_module("glowcap._session.lifecycle")
verbs = importlib.import_module("glowcap._session.verbs")
assert glowcap.Session is session.Session
assert glowcap.Host is host.Host
assert loop.DriverLoop.__module__ == "glowcap._loop"
assert glowcap.PartnerIdentity is session.PartnerIdentity
assert glowcap.SendRedeemingResult is session.SendRedeemingResult
assert session.Session.__module__ == "glowcap._session"
assert session.PartnerIdentity.__module__ == "glowcap._session"
assert session.SendRedeemingResult.__module__ == "glowcap._session"
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
