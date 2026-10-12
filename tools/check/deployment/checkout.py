"""Checkout deployment scenarios, called by glowcap-host-test.

The product CLI owns source selection and argv validation. Its preparation
request is recorded here; build-front.sh owns the real launcher and builder.
"""
import json
from pathlib import Path
import sys


def checkout_deployment(binary, product, scratch, original_env, run):
    # Existing deployment configuration is moved once by its operator. Both
    # checkout and installed invocations then use it without extra flags.
    checkout = scratch / "checkout with spaces"
    legacy = checkout / "apps/rooms/web/deploy"
    (legacy / "secrets").mkdir(parents=True)
    password = b"original-database-password\n"
    secret = legacy / "secrets/storage-db-password"
    secret.write_bytes(password)
    secret.chmod(0o600)
    override = b"services:\n  directory:\n    volumes:\n      - ./operator-files:/operator:ro\n"
    (legacy / "docker-compose.override.yml").write_bytes(override)
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
    # for credentials, even when an old deployment directory exists there.
    before = len(log.read_text())
    call("doctor")
    call("status", ok=False)
    assert not preparation_log.exists(), "inspection requested a source build"
    assert not state.exists()
    untouched(before)
    result = call("up", "--image", "fixture:test", ok=False)
    assert "MissingDatabaseSecret" in result.stderr and str(state) in result.stderr
    assert not (state / "secrets/storage-db-password").exists()
    untouched(before)
    call("up", "--dir", scratch / "explicit config", "--image", "fixture:test", ok=False)
    assert not preparation_log.exists(), "an explicit image requested a source build"
    for args_bad in (("up", "--unknown"), ("reset", "invalid-unit"), ("reset", "all", "--build", "x", "--image", "y")):
        call(*args_bad, ok=False)
    call("up", "--help")
    call("reset", "--help")
    assert not preparation_log.exists(), "help or invalid argv requested a source build"
    # Model the manual configuration move without changing real host files.
    (state / "secrets").mkdir(mode=0o700)
    (state / "secrets/storage-db-password").write_bytes(password)
    (state / "secrets/storage-db-password").chmod(0o600)
    (state / "docker-compose.override.yml").write_bytes(override)
    before = len(log.read_text())
    # macOS contributors select a separately prepared Linux product explicitly.
    args = () if sys.platform.startswith("linux") else ("--build", product)
    # Reset must work directly after the configuration move: no successful up,
    # managed Compose file, or saved image exists yet. Preparation must not
    # start old data, and an unconfirmed reset must not stop or erase anything.
    result = call("reset", "all", *args, detached=True, ok=False)
    assert "ConfirmationRequired" in result.stderr, result.stderr
    assert password.decode().strip() not in result.stdout + result.stderr
    assert any(a[0] == "build" for a in calls_since(before))
    assert not any(a[0] == "pull" or "up" in a or "down" in a or a[:2] == ["volume", "rm"] for a in calls_since(before))
    assert (state / "secrets/storage-db-password").read_bytes() == password
    assert (state / "secrets/storage-db-password").stat().st_mode & 0o777 == 0o600
    assert (state / "secrets").stat().st_mode & 0o777 == 0o700
    assert (state / "docker-compose.override.yml").read_bytes() == override
    assert "file: ./secrets/storage-db-password" in (state / "compose.yml").read_text()
    assert secret.read_bytes() == password
    assert (legacy / "docker-compose.override.yml").read_bytes() == override
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
                    ("image", "secrets/storage-db-password", "docker-compose.override.yml")}
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
        "glowcap-rooms-session-state", "glowcap-rooms-directory-state", "glowcap-rooms-postgres"]
    assert next(i for i, a in enumerate(calls) if "down" in a) < next(i for i, a in enumerate(calls) if a[:2] == ["volume", "rm"])
    assert next(i for i, a in enumerate(calls) if "up" in a) > max(i for i, a in enumerate(calls) if a[:2] == ["volume", "rm"])
    # Host state remains authoritative across subsequent checkout invocations.
    secret.write_bytes(b"stale-password\n")
    (state / "docker-compose.override.yml").write_bytes(override + b"# host edit\n")
    before = len(log.read_text())
    call("up", "--image", "fixture:explicit")
    assert not any(a[0] == "build" for a in calls_since(before))
    assert (state / "secrets/storage-db-password").read_bytes() == password
    assert (state / "docker-compose.override.yml").read_bytes().endswith(b"# host edit\n")
    # The installed product uses the same state without checkout context or
    # compiler output, and keeps its selected image across ordinary up calls.
    del env["GLOWCAP_CHECKOUT_ROOT"]
    before = len(log.read_text())
    call("up")
    call("status")
    call("down")
    assert not any(a[0] in ("build", "pull") or a[:2] == ["volume", "rm"] for a in calls_since(before))
    # No legacy credential remains a hard refusal for an existing database.
    # A fresh deployment instead mints a private secret in HOME's state path.
    fresh_checkout = scratch / "fresh checkout"
    (fresh_checkout / "zig-out").mkdir(parents=True)
    (fresh_checkout / "zig-out/product").symlink_to(product, target_is_directory=True)
    prepare_front(fresh_checkout)
    env["GLOWCAP_CHECKOUT_ROOT"] = str(fresh_checkout)
    env["HOME"] = str(scratch / "fresh home")
    del env["XDG_STATE_HOME"]
    fresh_state = Path(env["HOME"]) / ".local/state/glowcap/rooms-deployment"
    before = len(log.read_text())
    result = call("up", *args, ok=False)
    assert "MissingDatabaseSecret" in result.stderr
    assert not (fresh_state / "secrets/storage-db-password").exists()
    untouched(before)
    del env["EXISTING_VOLUME"]
    call("up", *args)
    assert len((fresh_state / "secrets/storage-db-password").read_bytes().strip()) == 64
