#!/usr/bin/env python3
"""glowcap-pack: prove the extracted host product without checkout tooling.

The package check rejects missing runtimes, unsafe members, broken skill links,
and build-directory loader dependencies. The shared process proof then drives
the extracted command through rooms, DMs, listener retirement and restart.
"""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import urllib.parse

import rooms_peer
import glowcap_host


def unpack(archive, destination):
    sums = archive.with_name("SHA256SUMS").read_text().splitlines()
    matches = [line.split()[0] for line in sums
               if len(line.split()) == 2 and line.split()[1] == archive.name]
    assert len(matches) == 1, "archive needs one checksum entry"
    with archive.open("rb") as content:
        assert hashlib.file_digest(content, "sha256").hexdigest() == matches[0], "checksum mismatch"
    with tarfile.open(archive, "r:gz") as source:
        seen = set()
        for member in source.getmembers():
            path = PurePosixPath(member.name)
            assert not path.is_absolute() and ".." not in path.parts, "unsafe archive path"
            assert member.isdir() or member.isfile(), "archive contains a link or special file"
            assert member.name not in seen, "duplicate archive member"
            assert not member.mode & 0o7000, "archive contains privileged mode bits"
            seen.add(member.name)
        source.extractall(destination, filter="data")


def check_skills(root):
    skills = (root / "share/glowcap/skills").resolve()
    for name in ("rooms-peer", "rooms-team"):
        assert (skills / name / "SKILL.md").is_file(), f"missing {name} skill"
    for path in skills.rglob("*.md"):
        for link in re.findall(r"\[[^\]]*\]\(([^)]+)\)", path.read_text()):
            if "://" in link or link.startswith("#"):
                continue
            target = (path.parent / link.split("#", 1)[0]).resolve()
            assert target.is_relative_to(skills), f"skill depends on checkout: {path}: {link}"
            assert target.exists(), f"broken packaged skill link: {path}: {link}"


def check_loader(root):
    root = root.resolve()
    session = root / "libexec/rooms-session"
    if sys.platform == "darwin":
        for binary in [*list((root / "bin").iterdir()), *list((root / "libexec").iterdir()), *list((root / "lib").iterdir())]:
            report = subprocess.check_output(["/usr/bin/otool", "-L", str(binary)], text=True, timeout=5)
            for line in report.splitlines()[1:]:
                name = line.strip().split(" (", 1)[0]
                assert name.startswith(("@rpath/", "@loader_path/", "/usr/lib/", "/System/Library/")), report
        report = subprocess.check_output(["/usr/bin/otool", "-l", str(session)], text=True, timeout=5)
        assert "@loader_path/../lib" in report, "missing relocatable library lookup"
    else:
        for binary in [*(root / "bin").iterdir(), *(root / "libexec").iterdir()]:
            try:
                report = subprocess.check_output(["/usr/bin/ldd", str(binary)], text=True, stderr=subprocess.STDOUT, timeout=5)
            except subprocess.CalledProcessError as error:
                assert "not a dynamic executable" in error.output or "statically linked" in error.output, error.output
                continue
            assert "not found" not in report, report
            for line in report.splitlines():
                if "libglowcap_" in line:
                    resolved = Path(line.split("=>", 1)[1].split(" (", 1)[0].strip()).resolve()
                    assert resolved.is_relative_to(root / "lib"), report


def check_web(root, scratch, transport="iroh", executable=None):
    binary = executable or root / "bin/glowcap"
    front = [str(binary), "apps", "rooms"]
    with (Path(scratch) / "web.log").open("w+") as log:
        options = [] if transport == "iroh" else ["--transport", transport]
        child = subprocess.Popen([*front, "serve", "--http-port", "0",
                                  "--reachability", "direct", *options], stdout=log, stderr=log,
                                 env={**os.environ, "GLOWCAP_ROOMS_SERVER_BIN": str(Path(scratch) / "unrelated-server")})
        try:
            deadline = time.monotonic() + 10
            url = None
            while time.monotonic() < deadline:
                log.seek(0)
                output = log.read()
                match = re.search(r"web ui\s+(http://localhost:\d+)", output)
                if match:
                    url = match[1]
                    break
                assert child.poll() is None, output
                time.sleep(0.05)
            assert url, "web readiness deadline"
            subprocess.run([*front, "status", "--url", url], check=True, capture_output=True, timeout=6)
            locator = subprocess.check_output([*front, "locator", "--url", url], text=True, timeout=6).strip()
            assert locator.startswith("ocapn://"), locator
            # Generic CapTP currently registers stream transports, while Rooms
            # also composes the multiplexed iroh provider. Exercise both the
            # supported call and the explicit refusal, without implying parity.
            called = subprocess.run([str(binary), "ocapn", "call", locator,
                                     "directory", "list", "--json"],
                                    capture_output=True, text=True, timeout=6)
            if transport == "tcp":
                assert called.returncode == 0, (called.returncode, called.stdout, called.stderr)
                assert json.loads(called.stdout) == {"ok": True, "value_kind": "list"}, called.stdout
            else:
                assert called.returncode == 4 and "transport 'iroh' is not registered" in called.stderr, called.stderr
            revision = subprocess.check_output([*front, "revision", "--url", url], text=True, timeout=6).strip()
            assets_root = root / "share/glowcap/rooms"
            assert revision == (assets_root / "revision").read_text().strip()
            assert json.loads((root / "share/glowcap/release.json").read_text())["browser"] == (assets_root / "source.version").read_text().strip()
            with urllib.request.urlopen(url, timeout=5) as response:
                html = response.read().decode()
                assert response.status == 200 and "<html" in html
            assets = re.findall(r'(?:src|href)\s*=\s*"([^"#]+)"', html)
            assert any(".js" in asset for asset in assets), "page has no application script"
            for asset in assets:
                target = urllib.parse.urljoin(url, asset)
                assert target.startswith(url + "/"), "page depends on an external asset"
                with urllib.request.urlopen(target, timeout=5) as response:
                    assert response.status == 200 and response.read(), asset
            assert (Path(scratch) / ".local/state/glowcap/rooms").is_dir(), "default state is not durable"
        finally:
            child.terminate()
            child.wait(timeout=10)
        assert child.returncode == 0, "web did not retire cleanly"


def check_installation(root, scratch):
    link = Path(scratch) / "glowcap"
    link.symlink_to(root / "bin/glowcap")
    path = subprocess.check_output([str(link), "apps", "rooms", "skills"], text=True, timeout=5).strip()
    assert Path(path).resolve() == (root / "share/glowcap/skills").resolve()
    # A broken installation cannot silently borrow a different version from
    # bin or PATH. Only this disposable extracted fixture is damaged.
    runtime = root / "libexec/rooms-session"
    held = runtime.with_suffix(".held")
    fallback = root / "bin/rooms-session"
    runtime.rename(held)
    try:
        fallback.write_text("#!/bin/sh\nexit 99\n")
        fallback.chmod(0o700)
        result = subprocess.run([str(link), "apps", "rooms", "session", "status", "--dir", str(Path(scratch) / "unused")],
                                capture_output=True, text=True, timeout=5,
                                env={**os.environ, "PATH": str(root / "bin") + ":" + os.environ["PATH"]})
        assert result.returncode not in (0, 99) and "missing installed runtime" in result.stderr, result
    finally:
        fallback.unlink()
        held.rename(runtime)


def check_completion(root):
    # The consumer needs no shell to run Rooms. Bash is the release test driver
    # here, exercising the emitted completion with only builtins and an empty PATH.
    script = subprocess.check_output([str(root / "bin/glowcap"), "completion", "bash"], text=True, timeout=5)
    for arguments in ("", "--dir /tmp/me", "--dir=rooms", "--dir session"):
        proof = script + f'''\nCOMP_WORDS=(glowcap apps rooms session listen {arguments} --)
COMP_CWORD=$((${{#COMP_WORDS[@]}}-1))
_glowcap
printf '%s\\n' "${{COMPREPLY[@]}}"
'''
        result = subprocess.check_output(["/bin/bash", "-c", proof], text=True, timeout=5)
        assert set(result.splitlines()) == {"--dir", "--help"}, (arguments, result)
    proof = script + '\n_glowcap_path --identity apps ocapn dial --repl ocapn://locator\n'
    assert subprocess.check_output(["/bin/bash", "-c", proof], text=True, timeout=5).strip() == "ocapn dial"


def check_command_refusal(root, scratch):
    front = [str(root / "bin/glowcap"), "apps", "rooms"]
    state = str(Path(scratch) / "refused-state")
    for args, reason in (
        (["directory", "serve", "--state", state, "--transport", "invalid"], "transport must be"),
        (["archive", "serve", "--state", state, "--transport", "invalid"], "transport must be"),
        (["session", "serve", "--dir", state, "--transport", "invalid"], "transport must be"),
        (["irc", "front", "--directory", "not-a-locator"], "--directory must name"),
        (["irc", "bridge", "--irc-realname", "bridge bot; admin: alice", "--mode", "invalid"], "--mode must be"),
    ):
        result = subprocess.run([*front, *args], capture_output=True, text=True, timeout=5)
        assert result.returncode != 0 and result.stderr, args
        assert reason in result.stderr, (args, result.stderr)
        assert "missing installed runtime" not in result.stderr, result.stderr
        assert not Path(state).exists(), "refused options acquired state"


def check_source_installation(root, launcher):
    with tempfile.TemporaryDirectory(prefix="glowcap-install-", dir="/tmp") as scratch:
        # The checkout launcher needs shell utilities, but no host compiler or
        # repository cwd. The installed product proof separately uses empty PATH.
        os.environ.clear()
        os.environ.update(PATH="/usr/bin:/bin", HOME=scratch)
        # Exercise the ordinary launcher with no override. The complete product
        # exists; even while this proof owns the build lease, client operations
        # must not invoke the builder or depend on a running devcontainer.
        os.chdir(scratch)
        check_web(root, scratch, executable=launcher)
        check_skills(root)
        check_completion(root)
        rooms_peer.main(launcher.parent, transport="iroh")
        print("glowcap-install-test: checkout launcher serves Rooms; installed sessions, skills and completion passed")


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--installed":
        return check_source_installation(Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve())
    if len(sys.argv) != 2:
        raise SystemExit("usage: glowcap_release.py TARBALL | --installed PREFIX CHECKOUT_LAUNCHER")
    archive = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="rooms-release-", dir="/tmp") as scratch:
        root = Path(scratch) / "installation with spaces"
        root.mkdir()
        unpack(archive, root)
        installed = glowcap_host.installation(root, Path(scratch))
        glowcap_host.deployment(installed, root, Path(scratch))
        root = installed.resolve().parent.parent
        assert sorted(path.name for path in (root / "bin").iterdir()) == ["glowcap"]
        for name in ("rooms-server", "rooms-session", "rooms-web", "rooms-chat", "rooms-archive", "rooms-irc-front", "rooms-irc-bridge"):
            assert os.access(root / "libexec" / name, os.X_OK), f"missing private executable {name}"
        for name in ("README.md", "PROVENANCE.md", "LICENSE-APACHE", "LICENSE-THIRD-PARTY"):
            assert (root / name).is_file(), f"missing {name}"
        check_skills(root)
        # No compiler, package resolver, loader override, or repository env is
        # needed by a consumer. Python and the directory are test drivers only.
        os.environ.clear()
        empty_path = Path(scratch) / "empty-path"
        empty_path.mkdir()
        os.environ.update(PATH=str(empty_path), HOME=scratch)
        os.chdir(scratch)
        check_loader(root)
        check_installation(root, scratch)
        check_completion(root)
        check_command_refusal(root, scratch)
        for command in ([], ["apps", "rooms"], ["apps", "rooms", "session"], ["apps", "rooms", "team"],
                        ["apps", "rooms", "irc", "bridge"], ["apps", "rooms", "irc", "front"]):
            subprocess.run([str(root / "bin/glowcap"), *command, "--help"], check=True,
                           capture_output=True, timeout=5)
        check_web(root, scratch)
        check_web(root, scratch, transport="tcp")
        rooms_peer.main(root / "bin", transport="iroh")
        print("glowcap-pack: extracted CLI, browser serving, skills, HTTP bootstrap, iroh, rooms, DMs and restart passed")


if __name__ == "__main__":
    main()
