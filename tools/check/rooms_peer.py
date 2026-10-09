#!/usr/bin/env python3
"""rooms-agent-test: exercise the skill front and installed session on loopback.

The public front owns all participant actions. Temporary TCP peers prove
multi-room observation, DM isolation, acknowledgements, restart, and shutdown.
The restart assertion was validated by injecting an automatic inbox
acknowledgement into start: it failed on the missing unanswered garden line.
"""
import json
from contextlib import ExitStack, contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
FRONT = ROOT / "zig-out/bin/glowcap"


def cli(state, verb, *args):
    subject, action = ("team", verb[5:]) if verb.startswith("team-") else ("session", verb)
    result = subprocess.run([str(FRONT), "apps", "rooms", subject, action, "--dir", str(state), *args],
                            cwd="/tmp", text=True, capture_output=True, timeout=10)
    if result.returncode:
        raise AssertionError(f"{verb}: {result.stdout}\n{result.stderr}")
    return json.loads(result.stdout)


def line_text(row):
    if row.get("unavailable"):
        return ""
    notice = row["event"]["notice"]
    return notice["text"] if notice["kind"] == "line" else ""


def target(row):
    return row["event"]["target"]


def marker(row):
    return row["event"]["notice"]["marker"]


def until(state, text):
    deadline = time.monotonic() + 5
    after_id = 0
    while True:
        batch = cli(state, "tick", "--wait", "0", "--after-id", str(after_id))
        rows = batch["pending"]
        found = [row for row in rows if line_text(row) == text]
        if found:
            return found[0]
        if time.monotonic() >= deadline:
            raise AssertionError(f"missing {text!r}: {rows!r}")
        if rows:
            after_id = rows[-1]["id"]
        if batch["more"]:
            continue
        time.sleep(0.05)


@contextmanager
def bootstrap(locator, content_type="text/plain"):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/locator":
                self.send_error(404)
                return
            body = locator.encode()
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/locator"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
        assert not thread.is_alive(), "bootstrap server did not stop"


def rejected_bootstrap(root):
    state = root / "rejected-login"
    with bootstrap("<html>login</html>" * 3000, "text/html") as locator:
        result = subprocess.run([str(FRONT), "apps", "rooms", "session", "start",
            "--dir", str(state), "--nick", "Alice", "--room", "garden",
            "--transport", "tcp", "--locator", locator],
            cwd="/tmp", text=True, capture_output=True, timeout=15)
        try:
            assert result.returncode != 0
            error = json.loads(result.stdout)["error"]
            assert error["class"] == "bootstrap" and "HTML" in error["message"], result.stdout
            assert not state.exists(), "failed bootstrap created a workspace or launched a peer"
        finally:
            if (state / "control.sock").exists():
                cli(state, "stop")


def main(bin_dir=ROOT / "zig-out/bin", transport="tcp"):
    global FRONT
    FRONT = Path(bin_dir) / "glowcap"
    # macOS's default temporary root can consume the Unix socket path budget.
    with tempfile.TemporaryDirectory(prefix="rooms-agent-proof-", dir="/tmp") as temp, ExitStack() as services:
        root = Path(temp)
        rejected_bootstrap(root)
        alice, team = root / "alice", root / "team"
        bob, carol = team / "Bob", team / "Carol"
        with (root / "server.log").open("w+") as log:
            server = subprocess.Popen([str(FRONT), "apps", "rooms", "directory", "serve",
                f"--transport={transport}", "--reachability=direct", "--port=0"],
                stdout=subprocess.PIPE, stderr=log, text=True)
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(server.stdout, selectors.EVENT_READ)
                    assert selector.select(5), "server readiness deadline"
                    line = server.stdout.readline().strip()
                assert line.startswith("ROOMS-SERVER-LISTENING "), line
                locator = line.split(" ", 1)[1]
                if locator.isdecimal():
                    locator = f"127.0.0.1:{locator}"
                if transport == "iroh":
                    locator = services.enter_context(bootstrap(locator))
                cli(alice, "start", "--transport", transport, "--reachability", "direct", "--locator", locator,
                    "--nick", "Alice", "--room", "garden", "--room", "workshop")
                cli(team, "team-start", "--transport", transport, "--reachability", "direct", "--locator", locator,
                    "--lead", "Bob", "--member", "Carol", "--room", "garden", "--room", "workshop")
                assert len(cli(team, "team-status")["members"]) == 2
                rooms = {row["name"]: row["id"] for row in cli(alice, "status")["workspace"]["conversations"]
                         if row["kind"] == "room"}
                # Both inactive and active conversations deliver; no @mention.
                cli(bob, "reply", "--room", "garden", "--text", "garden-message")
                cli(bob, "reply", "--room", "workshop", "--text", "workshop-message")
                garden = until(alice, "garden-message")
                workshop = until(alice, "workshop-message")
                assert target(garden)["id"] != target(workshop)["id"]
                assert target(garden)["id"] == rooms["garden"] and target(workshop)["id"] == rooms["workshop"]
                cli(alice, "reply", "--id", str(workshop["id"]), "--text", "workshop-answer")
                assert target(until(bob, "workshop-answer"))["id"] == target(until(bob, "workshop-message"))["id"]
                # First contact, then reply-by-id; no text appears in Carol's rooms.
                cli(bob, "reply", "--dm", "Alice", "--text", "private-question")
                private = until(alice, "private-question")
                assert target(private)["kind"] == "direct", private
                cli(alice, "reply", "--id", str(private["id"]), "--text", "private-answer")
                assert target(until(bob, "private-answer"))["kind"] == "direct"
                assert not any(line_text(row).startswith("private-")
                               for row in cli(carol, "tick", "--wait", "0")["pending"])
                cli(carol, "reply", "--dm", "Alice", "--text", "second-private-question")
                second_private = until(alice, "second-private-question")
                assert target(second_private)["kind"] == "direct"
                assert target(second_private)["id"] != target(private)["id"]
                cli(alice, "reply", "--id", str(second_private["id"]), "--text", "second-private-answer")
                assert target(until(carol, "second-private-answer"))["kind"] == "direct"
                assert not any(line_text(row).startswith("second-private-")
                               for row in cli(bob, "tick", "--wait", "0")["pending"])
                answer = until(bob, "private-answer")
                cli(bob, "leave", "--conversation", target(answer)["id"])
                assert target(until(bob, "private-answer"))["kind"] == "direct"
                # Edits are observed as edits, with their original line identity.
                own = until(bob, "garden-message")
                cli(bob, "command", "editLine", target(own)["id"], str(marker(own)["id"]), "garden-edited")
                edited = until(alice, "garden-edited")
                assert marker(edited)["id"] == marker(garden)["id"] and marker(edited)["change"] == "edited"
                sent = cli(bob, "reply", "--dm", "Alice", "--text", "private-unread")
                unread_dm = until(alice, "private-unread")
                cli(alice, "reply", "--conversation", target(unread_dm)["id"],
                    "--text", "private-reopened-answer")
                assert target(until(bob, "private-reopened-answer"))["kind"] == "direct"
                assert not any(line_text(row) == "private-reopened-answer"
                               for row in cli(carol, "tick", "--wait", "0")["pending"])
                bob_direct = next(row["id"] for row in cli(bob, "status")["workspace"]["conversations"]
                                  if row["kind"] == "direct" and row["peer"] == "Alice" and not row["closed"])
                replay_args = ("--conversation", bob_direct, "--operation", sent["operation"],
                               "--base", str(sent["base"]), "--text", "private-unread")
                cli(bob, "reply", *replay_args)
                unread_rows = [row for row in cli(alice, "tick", "--wait", "0")["pending"]
                               if line_text(row) == "private-unread"]
                assert [row["id"] for row in unread_rows] == [unread_dm["id"]], "exact replay sent twice"
                # A new process keeps the same unanswered IDs and memberships.
                cli(alice, "dismiss", "--id", str(workshop["id"]))
                cli(alice, "stop")
                deadline = time.monotonic() + 5
                while (alice / "control.sock").exists():
                    assert time.monotonic() < deadline, "control socket not retired"
                    time.sleep(0.05)
                cli(alice, "start")
                assert cli(alice, "status")["inbox"]["gap"] is None
                replay = until(alice, "garden-message")
                assert replay["id"] == garden["id"]
                replay_dm = until(alice, "private-unread")
                assert replay_dm["id"] == unread_dm["id"] and target(replay_dm)["kind"] == "direct"
                assert not any(row["id"] == workshop["id"]
                               for row in cli(alice, "tick", "--wait", "0")["pending"])
                cli(alice, "join", "--room", "garden", "--room", "workshop")
                cli(alice, "leave", "--room", "garden")
                # Old messages keep their room context even after leaving.
                assert target(until(alice, "garden-message"))["id"] == rooms["garden"]
                cli(bob, "reply", "--room", "workshop", "--text", "still-listening")
                assert target(until(alice, "still-listening"))["id"] == rooms["workshop"]
                # One continuous consumer delivers rooms, DMs, and own echoes
                # once each, without scripts, filtering, or acknowledging them.
                output = root / "listener.jsonl"
                with output.open("wb") as sink:
                    listener = subprocess.Popen([str(FRONT), "apps", "rooms", "session", "listen", "--dir", str(alice)],
                                                stdout=sink, stderr=subprocess.PIPE, cwd="/tmp")
                    try:
                        cli(bob, "reply", "--room", "workshop", "--text", "continuous-listener")
                        deadline = time.monotonic() + 5
                        while "continuous-listener" not in output.read_text():
                            assert time.monotonic() < deadline, "listen did not emit the new event"
                            assert listener.poll() is None, "listener exited"
                            time.sleep(0.05)
                        cli(alice, "reply", "--room", "workshop", "--text", "listener-own-echo")
                        cli(bob, "reply", "--dm", "Alice", "--text", "listener-private-message")
                        deadline = time.monotonic() + 5
                        while True:
                            # The producer may be partway through a JSONL record.
                            batches = [json.loads(line) for line in output.read_text().splitlines(keepends=True)
                                       if line.endswith("\n")]
                            delivered = [event for batch in batches for event in batch["pending"]]
                            if {"listener-private-message", "listener-own-echo"} <= {line_text(event) for event in delivered}:
                                break
                            assert time.monotonic() < deadline, "listen missed a DM or own echo"
                            assert listener.poll() is None, "listener exited"
                            time.sleep(0.05)
                        ids = [event["id"] for event in delivered]
                        assert len(ids) == len(set(ids)), "listen repeated already delivered pending events"
                        private = next(event for event in delivered if line_text(event) == "listener-private-message")
                        assert target(private)["kind"] == "direct"
                    finally:
                        listener.terminate()
                        listener.wait(timeout=5)
                assert line_text(until(alice, "continuous-listener")) == "continuous-listener"
                assert target(until(alice, "listener-private-message"))["kind"] == "direct"
                cli(bob, "reply", "--room", "workshop", "--text", "after-consumer-exit")
                assert target(until(alice, "after-consumer-exit"))["id"] == rooms["workshop"]
                # One observer's disk failure must not stop the shared session.
                journal = alice / "inbox/events.jsonl"
                journal.chmod(0o400)
                try:
                    cli(bob, "reply", "--room", "workshop", "--text", "during-disk-failure")
                    deadline = time.monotonic() + 5
                    while cli(alice, "status")["inbox"]["gap"] is None:
                        assert time.monotonic() < deadline, "disk failure not reported"
                        time.sleep(0.05)
                    cli(alice, "reply", "--room", "workshop", "--text", "session-still-live")
                    until(bob, "session-still-live")
                finally:
                    journal.chmod(0o600)
                cli(alice, "resume", "--accept-gap")
                cli(bob, "reply", "--room", "workshop", "--text", "after-resume")
                resumed = until(alice, "after-resume")
                assert cli(alice, "tick", "--wait", "0")["more"], "journey must cover multiple inbox pages"
                assert resumed["id"] > cli(alice, "tick", "--wait", "0")["pending"][-1]["id"]
                # A restarted listener replays every retained page without
                # dismissing the prefix or needing a new journal mutation.
                with output.open("wb") as sink:
                    listener = subprocess.Popen([str(FRONT), "apps", "rooms", "session", "listen", "--dir", str(alice)],
                                                stdout=sink, stderr=subprocess.PIPE, cwd="/tmp")
                    try:
                        deadline = time.monotonic() + 5
                        while True:
                            batches = [json.loads(line) for line in output.read_text().splitlines(keepends=True)
                                       if line.endswith("\n")]
                            delivered = [event for batch in batches for event in batch["pending"]]
                            if any(line_text(event) == "after-resume" for event in delivered):
                                break
                            assert time.monotonic() < deadline, "restarted listener did not drain later pages"
                            assert listener.poll() is None, "listener exited during replay"
                            time.sleep(0.05)
                        ids = [event["id"] for event in delivered]
                        assert len(ids) == len(set(ids)), "replay duplicated events between pages"
                        assert any(line_text(event) == "continuous-listener" for event in delivered)
                        assert any(line_text(event) == "after-resume" for event in delivered)
                    finally:
                        listener.terminate()
                        listener.wait(timeout=5)
                cli(alice, "reply", "--id", str(resumed["id"]), "--text", "reply-to-later-page")
                until(bob, "reply-to-later-page")
                cli(team, "team-stop")
            except BaseException:
                for state in (alice, bob, carol):
                    if (state / "control.log").exists():
                        print(f"{state.name}: {(state / 'control.log').read_text()}", file=sys.stderr)
                log.seek(0)
                print(log.read(), file=sys.stderr)
                raise
            finally:
                for state in (alice, bob, carol):
                    if (state / "control.sock").exists():
                        try:
                            cli(state, "stop")
                        except Exception as error:
                            print(f"cleanup: {error}", file=sys.stderr)
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


if __name__ == "__main__":
    main()
