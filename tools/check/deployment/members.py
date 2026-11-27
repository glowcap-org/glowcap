"""Exercise named member provisioning and isolation through the installed CLI."""

import json


def named_members(deploy):
    call, root = deploy.call, deploy.workspace / "bots"
    call("up", "--image", "fixture:rooms")
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
    status = call("bots", "status", env={"MEMBER_ROWS": statuses}).stdout
    status_calls = [json.loads(line) for line in deploy.log.read_text()[status_start:].splitlines()]
    assert len(status_calls) == 1 and status_calls[0][0] == "ps"
    assert status.index("editor") < status.index("scout")
    assert status.count("stopped") == 3 and "(unhealthy)" in status and "foreign-marker" not in status
    call("bots", "down", "editor")
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
    (root / "editor/project-id").unlink()
    before = deploy.log.read_text()
    recovery = call("bots", "up", "editor", ok=False)
    assert "restore" in recovery.stderr and "project-id" in recovery.stderr
    assert deploy.log.read_text() == before and not (root / "editor/project-id").exists()
