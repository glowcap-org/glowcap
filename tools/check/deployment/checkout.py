"""Checkout deployment scenarios, called by glowcap-host-test.

The product CLI owns source selection and argv validation. Its preparation
request is recorded here; build-front.sh owns the real launcher and builder.
"""
import json
from pathlib import Path
import sys


def checkout_deployment(binary, product, scratch, original_env, run):
    # The operator's configuration lives in the host state directory, and both
    # checkout and installed invocations use it without extra flags. A
    # configuration left inside the checkout is never discovered.
    checkout = scratch / "checkout with spaces"
    checkout_config = checkout / "apps/rooms/web/deploy"
    checkout_config.mkdir(parents=True)
    override = b"services:\n  directory:\n    volumes:\n      - ./operator-files:/operator:ro\n"
    (checkout_config / "docker-compose.override.yml").write_bytes(override)
    (checkout / "zig-out").mkdir()
    (checkout / "zig-out/product").symlink_to(product, target_is_directory=True)
    preparation_log = scratch / "checkout preparation.jsonl"
    # The CLI validates and replays argv through the checkout launcher. The
    # build-front proof exercises its actual builder; this stand-in records
    # the request and dispatches the already prepared product without compiling.
    def prepare_front(root):
        front = root / "glowcap"
        front.write_text(f"""#!{sys.executable}
import json, os, sys
env = dict(os.environ)
root = env['GLOWCAP_CHECKOUT_ROOT']
assert env.pop('GLOWCAP_PREPARE_CHECKOUT') == root
with open({str(preparation_log)!r}, 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if env.get('FAIL_PREPARATION'): sys.exit(37)
env['GLOWCAP_CHECKOUT_PREPARED'] = root
os.execve({str(binary)!r}, [{str(binary)!r}, *sys.argv[1:]], env)
""")
        front.chmod(0o755)
    prepare_front(checkout)
    env = dict(original_env, GLOWCAP_CHECKOUT_ROOT=str(checkout), EXISTING_VOLUME="1",
               XDG_STATE_HOME=str(scratch / "host state"))
    state = Path(env["XDG_STATE_HOME"]) / "glowcap/rooms-deployment"
    log = Path(env["DOCKER_LOG"])
    def call(*args, **kwargs):
        return run(binary, "apps", "rooms", "deployment", *args, env=env, **kwargs)
    def calls_since(before):
        return [json.loads(line) for line in log.read_text()[before:].splitlines()]
    def untouched(before):
        assert not any(a[0] in ("build", "pull") or "up" in a or a[:2] == ["volume", "rm"]
                       for a in calls_since(before))
    # Read-only verbs do not create state. The CLI does not search a checkout
    # for configuration, even when one sits in the checkout's deploy directory.
    before = len(log.read_text())
    call("doctor")
    call("status", ok=False)
    assert not preparation_log.exists(), "inspection requested a source build"
    assert not state.exists()
    untouched(before)
    call("up", "--dir", scratch / "explicit config", "--image", "fixture:test")
    assert not preparation_log.exists(), "an explicit image requested a source build"
    for args_bad in (("up", "--unknown"), ("reset", "invalid-unit"), ("reset", "all", "--build", "x", "--image", "y")):
        call(*args_bad, ok=False)
    call("up", "--help")
    call("reset", "--help")
    assert not preparation_log.exists(), "help or invalid argv requested a source build"
    # Seed the state directory with an operator override.
    state.mkdir(parents=True, mode=0o700)
    (state / "docker-compose.override.yml").write_bytes(override)
    before = len(log.read_text())
    # macOS contributors select a separately prepared Linux product explicitly.
    args = () if sys.platform.startswith("linux") else ("--build", product)
    # Reset must work with only an operator override present: no successful up,
    # managed Compose file, or saved image exists yet. Preparation must not status-allow: pending state or quoted runtime label
    # start old data, and an unconfirmed reset must not stop or erase anything.
    result = call("reset", "all", *args, detached=True, ok=False)
    assert "ConfirmationRequired" in result.stderr, result.stderr
    assert any(a[0] == "build" for a in calls_since(before))
    assert not any(a[0] == "pull" or "up" in a or "down" in a or a[:2] == ["volume", "rm"] for a in calls_since(before))
    assert (state / "docker-compose.override.yml").read_bytes() == override
    assert (checkout_config / "docker-compose.override.yml").read_bytes() == override
    before = len(log.read_text())
    call("reset", "all", "--yes", *args)
    calls = calls_since(before)
    # From a checkout, reset deploys the checkout's prepared product, the same
    # rule as up: a rebuilt product never restarts behind an older image.
    assert any(a[0] == "build" for a in calls), "checkout reset kept an older image"
    assert not any(a[0] == "pull" for a in calls)
    if sys.platform.startswith("linux"):
        assert preparation_log.exists(), "checkout reset did not request preparation"
        requests = [json.loads(line) for line in preparation_log.read_text().splitlines()]
        assert requests[-1] == ["apps", "rooms", "deployment", "reset", "all", "--yes"]
        before = log.read_text()
        previous = {name: (state / name).read_bytes() for name in
                    ("image", "docker-compose.override.yml")}
        env["FAIL_PREPARATION"] = "1"
        failed = call("up", ok=False)
        assert failed.returncode == 37 and log.read_text() == before, failed
        assert all((state / name).read_bytes() == content for name, content in previous.items())
        del env["FAIL_PREPARATION"]
        run(binary, "apps", "rooms", "deployment", "up", f"--dir={state}", env=env)
        requests = [json.loads(line) for line in preparation_log.read_text().splitlines()]
        assert requests[-1] == ["apps", "rooms", "deployment", "up", f"--dir={state}"]
        before = preparation_log.read_bytes()
        call("up", "--image=fixture:test")
        call("up", "--build", product)
        call("restart")
        assert preparation_log.read_bytes() == before, "explicit sources or restart requested a source build"
    assert [a[-1] for a in calls if a[:2] == ["volume", "rm"]] == [
        "glowcap-rooms-session-state", "glowcap-rooms-directory-state"]
    assert next(i for i, a in enumerate(calls) if "down" in a) < next(i for i, a in enumerate(calls) if a[:2] == ["volume", "rm"])
    assert next(i for i, a in enumerate(calls) if "up" in a) > max(i for i, a in enumerate(calls) if a[:2] == ["volume", "rm"])
    # Host state remains authoritative across subsequent checkout invocations.
    (checkout_config / "docker-compose.override.yml").write_bytes(b"# checkout copy\n")
    (state / "docker-compose.override.yml").write_bytes(override + b"# host edit\n")
    before = len(log.read_text())
    call("up", "--image", "fixture:explicit")
    assert not any(a[0] == "build" for a in calls_since(before))
    assert (state / "docker-compose.override.yml").read_bytes().endswith(b"# host edit\n")
    # The installed product uses the same state without checkout context or
    # compiler output, and keeps its selected image across ordinary up calls.
    del env["GLOWCAP_CHECKOUT_ROOT"]
    before = len(log.read_text())
    call("up")
    call("status")
    call("down")
    assert not any(a[0] in ("build", "pull") or a[:2] == ["volume", "rm"] for a in calls_since(before))
    # A fresh HOME gets its own state path.
    fresh_checkout = scratch / "fresh checkout"
    (fresh_checkout / "zig-out").mkdir(parents=True)
    (fresh_checkout / "zig-out/product").symlink_to(product, target_is_directory=True)
    prepare_front(fresh_checkout)
    env["GLOWCAP_CHECKOUT_ROOT"] = str(fresh_checkout)
    env["HOME"] = str(scratch / "fresh home")
    del env["XDG_STATE_HOME"]
    fresh_state = Path(env["HOME"]) / ".local/state/glowcap/rooms-deployment"
    call("up", *args)
    assert (fresh_state / "compose.yml").exists()
    assert not (fresh_state / "docker-compose.override.yml").read_bytes().endswith(b"# host edit\n")
