"""Exercise named member provisioning and isolation through the installed CLI."""

import json
import time
from concurrent.futures import ThreadPoolExecutor


def named_members(deploy):
    call, root = deploy.call, deploy.workspace / "bots"
    deploy.env["EXPECT_SESSION_ENV_FILE"] = "/dev/null"
    # A shell setting cannot redirect a deployment to another project's file.
    deploy.env["GLOWCAP_ROOMS_SESSION_ENV_FILE"] = "/some/other/deployment/session.env"
    call("up", "--image", "fixture:rooms")
    shared = deploy.workspace / "session.env"
    shared.write_text("GLOWCAP_ROOMS_SESSION_RELAY_ALIAS_URL=wss://rooms.example/relay\n")
    deploy.env["EXPECT_SESSION_ENV_FILE"] = str(shared)
    call("up")
    call("bots", "init", "scout", "../escape", ok=False)
    assert not root.exists()
    call("bots", "init", "scout", "scout", ok=False)
    assert not root.exists()
    before = deploy.log.read_text()
    call("bots", "init", "scout")
    assert deploy.log.read_text() == before
    call("bots", "init", "--room", "workshop", "scout", "editor")
    original = {}
    for nick in ("scout", "editor"):
        member = root / nick
        project = (member / "project-id").read_text()
        link = member / "bot-link"
        assert link.read_text() == "ocapn://fixture/s/fixture-bearer"
        assert link.stat().st_mode & 0o077 == 0
        assert (member / "agent-home").is_dir() and (member / "instructions/role.md").is_file()
        original[nick] = (project, link.stat().st_ino)
    assert original["scout"][0] != original["editor"][0]
    role = root / "scout/instructions/role.md"
    role.write_text("Look up sources.")
    assert (root / "editor/instructions/role.md").read_text() == ""
    before = len(deploy.log.read_text())
    call("bots", "up", "scout", "editor")
    scout = "glowcap-member-scout-" + original["scout"][0]
    statuses = f"{scout}\tbot\tUp 2 hours (unhealthy)\nforeign\tbot\tforeign-marker"
    status_start = len(deploy.log.read_text())
    oneoff = f"{scout}\tbot\tExited (0) 1 hour ago"
    status = call("bots", "status", env={"MEMBER_ROWS": statuses, "MEMBER_ONEOFF_ROW": oneoff}).stdout
    status_calls = [json.loads(line) for line in deploy.log.read_text()[status_start:].splitlines()]
    assert len(status_calls) == 1 and status_calls[0][0] == "ps"
    assert status.index("editor") < status.index("scout")
    assert "bot: Up 2 hours (unhealthy)" in status and "Exited" not in status, status
    assert status.count("stopped") == 3 and "foreign-marker" not in status
    call("bots", "down", "editor")
    inspect_start = len(deploy.log.read_text())
    report = json.loads(call("bots", "inspect", "scout").stdout)
    assert report["status"]["unanswered"]["kind"] == "sign-in"
    stopped_env = {"MEMBER_BOT_STOPPED": "1", "MEMBER_CONTAINER": "a" * 64}
    stopped = call("bots", "inspect", "editor", env=stopped_env, ok=False)
    assert 'service "bot" is not running' in stopped.stderr
    assert f"docker cp {'a' * 64}:/bot-state/bot.log -" in stopped.stderr
    inspected = [json.loads(line) for line in deploy.log.read_text()[inspect_start:].splitlines()]
    assert len(inspected) == 3
    for nick, operands in zip(("scout", "editor"), inspected[:2], strict=True):
        assert operands[operands.index("--project-name") + 1] == f"glowcap-member-{nick}-{original[nick][0]}"
        assert operands[operands.index("exec") :] == [
            "exec",
            "-T",
            "bot",
            "/runtime/bin/glowcap",
            "apps",
            "rooms",
            "bot",
            "status",
            "--dir=/bot-state",
        ]
    lookup = inspected[-1]
    assert lookup[:4] == ["ps", "--all", "--quiet", "--no-trunc"]
    assert f"label=com.docker.compose.project=glowcap-member-editor-{original['editor'][0]}" in lookup
    assert "label=com.docker.compose.service=bot" in lookup and "label=com.docker.compose.oneoff=False" in lookup
    for container in ("", "x" * 64, "a" * 64 + "\n" + "b" * 64):
        logs = call("bots", "logs", "editor", env={"MEMBER_CONTAINER": container})
        assert "backup-plan" in logs.stderr and "docker cp" not in logs.stderr
    calls = [json.loads(line) for line in deploy.log.read_text()[before:].splitlines()]
    assert all("issue" not in args and "--volumes" not in args for args in calls)
    assert [args[args.index("--project-name") + 1] for args in calls if "down" in args] == [
        "glowcap-member-editor-" + original["editor"][0]
    ]
    assert role.read_text() == "Look up sources."
    assert all((root / nick / "bot-link").stat().st_ino == seen[1] for nick, seen in original.items())
    broken = call("bots", "up", "--room", "workshop", "juniper", env={"FAIL_MEMBER_ISSUE": "1"}, ok=False)
    assert "fixture-bearer" not in broken.stdout + broken.stderr
    assert not (root / "juniper/bot-link").exists()
    before = len(deploy.log.read_text())
    call("bots", "up", "direct-only")
    calls = [json.loads(line) for line in deploy.log.read_text()[before:].splitlines()]
    register = next(args for args in calls if "--exact-nick" in args)
    assert "join" in register and "--home-locator=http://directory:8080/locator" in register
    assert all("status" not in args and "start" not in args for args in calls)
    assert all(not arg.startswith("--room") for arg in register)
    before = len(deploy.log.read_text())
    call("bots", "up", "--room", "garden", "scout")
    calls = [json.loads(line) for line in deploy.log.read_text()[before:].splitlines()]
    register = next(args for args in calls if "--exact-nick" in args)
    assert "join" in register and "--room=garden" in register
    assert all(not arg.startswith(("--locator", "--home-locator")) for arg in register)
    before = len(deploy.log.read_text())
    call("bots", "init", "--room", "garden", "recovered")
    calls = [json.loads(line) for line in deploy.log.read_text()[before:].splitlines()]
    register = next(args for args in calls if "--exact-nick" in args)
    assert (
        "join" in register
        and "--room=garden" in register
        and "--home-locator=http://directory:8080/locator" in register
    )
    assert all("status" not in args and "start" not in args for args in calls)
    before = len(deploy.log.read_text())
    call("bots", "init", "--locator", "http://custom/locator", "custom")
    calls = [json.loads(line) for line in deploy.log.read_text()[before:].splitlines()]
    register = next(args for args in calls if "--exact-nick" in args)
    assert "join" in register and "--locator=http://custom/locator" in register
    assert all(not arg.startswith("--home-locator") for arg in register)
    call("bots", "session", "scout", "--", "access", "list")
    multiple_rooms(deploy)
    independent_member_changes(deploy)
    (root / "editor/project-id").unlink()
    before = deploy.log.read_text()
    recovery = call("bots", "up", "editor", ok=False)
    assert "restore" in recovery.stderr and "project-id" in recovery.stderr
    assert deploy.log.read_text() == before and not (root / "editor/project-id").exists()


def independent_member_changes(deploy):
    """A suspended rollout excludes that member and the base, while another member can stop."""
    marker = deploy.scratch / "member-waiting"
    with ThreadPoolExecutor(max_workers=1) as executor:
        started = executor.submit(deploy.call, "bots", "up", "scout", env={"MEMBER_WAIT": str(marker)})
        try:
            deadline = time.monotonic() + 5
            while not marker.exists():
                assert time.monotonic() < deadline and not started.done(), "rollout did not reach Docker"
                time.sleep(0.01)
            deploy.call("bots", "down", "editor")
            assert "Busy" in deploy.call("bots", "down", "scout", ok=False).stderr
            assert "Busy" in deploy.call("down", ok=False).stderr
        finally:
            marker.unlink(missing_ok=True)
        started.result()


def multiple_rooms(deploy):
    rooms = ["one", "two", "three", "four", "five"]
    room_options = [arg for room in rooms for arg in ("--room", room)]
    args = ("bots", "init", "--locator", "http://custom/locator", *room_options, "planner")
    before = len(deploy.log.read_text())
    failed = deploy.call(*args, env={"SLOW_MEMBER_JOIN": "1", "REFUSED_ROOM": "--room=four"}, ok=False)
    assert "confirmed room 3 of 5" in failed.stdout and "confirmed room 4" not in failed.stdout
    assert "no-such-room" in failed.stderr and "issue" not in deploy.log.read_text()[before:]
    assert not (deploy.workspace / "bots/planner/bot-link").exists()

    before = len(deploy.log.read_text())
    finished = deploy.call(*args, env={"SLOW_MEMBER_JOIN": "1"})
    calls = [json.loads(line) for line in deploy.log.read_text()[before:].splitlines()]
    joins = [parts for parts in calls if "join" in parts]
    assert [[arg for arg in parts if arg.startswith("--room=")] for parts in joins] == [
        [f"--room={room}"] for room in rooms
    ]
    assert all("--locator=http://custom/locator" in parts and "--exact-nick" in parts for parts in joins)
    assert "confirmed room 5 of 5" in finished.stdout and "issue" in calls[-1]
    assert (deploy.workspace / "bots/planner/bot-link").is_file()
