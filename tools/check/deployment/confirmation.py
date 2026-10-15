"""Exercise deployment reset confirmation through a real controlling terminal.

The host product proof supplies an installed CLI and recording Docker fixture.
This module owns terminal input, confirmation, interruption and cleanup.
"""
import fcntl
import json
import os
from pathlib import Path
import pty
import selectors
import subprocess
import termios
import time


def reset_prompt(binary, scratch):
    env = dict(PATH=f"{scratch / 'fake tools'}:/usr/bin:/bin", HOME=str(scratch),
               DOCKER_LOG=str(scratch / "docker.log"), EXISTING_VOLUME="1")
    log = Path(env["DOCKER_LOG"])
    workspace = scratch / "deployment config"

    def controlling_terminal():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    for answer in (b"yes\n", b"no\n", b"\n", b"\x04", b"\x03"):
        before = len(log.read_text())
        master, slave = pty.openpty()
        child = subprocess.Popen([str(binary), "apps", "rooms", "deployment", "reset", "all",
                                  "--dir", str(workspace)], env=env, stdin=slave,
                                 stdout=slave, stderr=slave, preexec_fn=controlling_terminal)
        os.close(slave)
        pending = bytearray()
        transcript = bytearray()

        def prompt():
            marker = b"Type yes to confirm"
            expires = time.monotonic() + 5
            with selectors.DefaultSelector() as selector:
                selector.register(master, selectors.EVENT_READ)
                while marker not in pending:
                    assert time.monotonic() < expires, bytes(transcript)
                    assert selector.select(max(0, expires - time.monotonic())), bytes(transcript)
                    try:
                        chunk = os.read(master, 4096)
                    except OSError as err:
                        raise AssertionError(bytes(transcript)) from err
                    assert chunk, bytes(transcript)
                    pending.extend(chunk)
                    transcript.extend(chunk)
            assert b"all Rooms data, identities, grants, and access links" in transcript, bytes(transcript)
            assert b"deployment restart" in transcript, bytes(transcript)
            del pending[:pending.index(marker) + len(marker)]
            calls = [json.loads(line) for line in log.read_text()[before:].splitlines()]
            assert not any("down" in a or "up" in a or a[:2] == ["volume", "rm"] for a in calls)

        try:
            prompt()
            # Exercise retries, including an overlong line ending in yes: no
            # truncation or leftover suffix may accidentally confirm deletion.
            for invalid in (b"y\n", b"maybe\n", b"x" * 80 + b"yes\n"):
                os.write(master, invalid)
                prompt()
            os.write(master, answer)
            code = child.wait(timeout=5)
            assert (code == 0) == (answer != b"\x03"), bytes(transcript)
            calls = [json.loads(line) for line in log.read_text()[before:].splitlines()]
            removed = [a[-1] for a in calls if a[:2] == ["volume", "rm"]]
            if answer == b"yes\n":
                assert removed == ["glowcap-rooms-session-state", "glowcap-rooms-directory-state"]
                assert any("up" in a for a in calls)
            else:
                assert not removed and not any("down" in a or "up" in a for a in calls)
            assert not (workspace / ".operation-lock").exists()
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)
            os.close(master)
