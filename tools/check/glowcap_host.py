#!/usr/bin/env python3
"""Host installation/deployment process proof, called by glowcap-host-test.

Uses the public CLI from a foreign cwd. Docker is a recording fixture here;
the release workflow separately runs the actual image on both Linux targets.
Damaged inventories, unrelated executables, failed builds, and a missing
database secret must fail without activating or destroying another product.
The build runs ordinary cases and --deadline separately: the latter consumes
the product's 15-second query budget and needs its own 30-second process limit.
"""
import hashlib
import fcntl
import json
import os
from pathlib import Path
import pty
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import time


def run(binary, *args, env, ok=True, detached=False):
    result = subprocess.run([str(binary), *map(str, args)], env=env,
                            capture_output=True, text=True, timeout=20,
                            start_new_session=detached)
    assert (result.returncode == 0) == ok, (args, result)
    return result


def installation(root, scratch):
    env = dict(PATH="", HOME=str(scratch))
    prefix = scratch / "installed product"
    source = root / "bin/glowcap"
    run(source, "install", "--prefix", prefix, env=env)
    link = prefix / "bin/glowcap"
    assert link.is_symlink()
    selected = link.resolve().parent.parent
    manifest = selected / "share/glowcap/installation.manifest"
    expected = {"share/glowcap/installation.manifest"}
    for row in manifest.read_text().splitlines():
        digest, mode, name = row.split(" ", 2)
        path = selected / name
        expected.add(name)
        with path.open("rb") as content:
            assert hashlib.file_digest(content, "sha256").hexdigest() == digest
        assert bool(path.stat().st_mode & 0o111) == (mode == "x")
    assert {p.relative_to(selected).as_posix() for p in selected.rglob("*") if p.is_file()} == expected
    assert hashlib.sha256(manifest.read_bytes()).hexdigest() == selected.name
    run(source, "install", "--prefix", prefix, env=env)
    assert link.resolve().parent.parent == selected
    assert not list((prefix / "bin").glob(".glowcap-*"))
    assert Path(run(link, "apps", "rooms", "skills", env=env).stdout.strip()).is_dir()

    # A tiny disposable source exercises failure/upgrade without modifying the
    # build output. Its executable is real; other product files are fixtures.
    fixture = scratch / "source fixture"
    rows = []
    for row in manifest.read_text().splitlines():
        _, mode, name = row.split(" ", 2)
        path = fixture / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if name == "bin/glowcap" or name in ("share/glowcap/release.json", "share/glowcap/deployment/rooms.Dockerfile"):
            shutil.copyfile(root / name, path)
        else:
            path.write_text("fixture\n")
        path.chmod(0o755 if mode == "x" else 0o644)
        rows.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()} {mode} {name}\n")
    receipt = fixture / "share/glowcap/installation.manifest"
    original = "".join(rows)
    executable = fixture / "bin/glowcap"
    for bad in ("", original.replace("bin/glowcap", "../escape"), original + rows[-1],
                "0" * 64 + original[64:]):
        receipt.write_text(bad)
        run(executable, "install", "--prefix", prefix, env=env, ok=False)
        assert link.resolve().parent.parent == selected
        assert not list((prefix / "lib/glowcap").glob(".install-*"))
    receipt.write_text(original)
    member = fixture / "README.md"
    held = fixture / "README.held"
    member.rename(held)
    member.symlink_to(held.name)
    run(executable, "install", "--prefix", prefix, env=env, ok=False)
    assert link.resolve().parent.parent == selected
    assert not list((prefix / "lib/glowcap").glob(".install-*"))
    member.unlink()
    held.rename(member)
    foreign = scratch / "foreign"
    (foreign / "bin").mkdir(parents=True)
    (foreign / "bin/glowcap").write_text("unrelated executable")
    run(executable, "install", "--prefix", foreign, env=env, ok=False)
    assert (foreign / "bin/glowcap").read_text() == "unrelated executable"
    run(executable, "install", "--prefix", prefix, env=env)
    assert link.resolve().parent.parent != selected
    assert (selected / "bin/glowcap").is_file(), "upgrade removed a running generation"
    # Reactivate the complete installation for the deployment proof.
    run(source, "install", "--prefix", prefix, env=env)
    return link


def docker_fixture(scratch):
    fakebin = scratch / "fake tools"
    fakebin.mkdir()
    docker = fakebin / "docker"
    docker.write_text(f"#!{sys.executable}\n" + '''
import hashlib, json, os, pathlib, signal, sys, time
a = sys.argv[1:]
with open(os.environ['DOCKER_LOG'], 'a') as f:
    f.write(json.dumps(a) + '\\n')
if os.environ.get('HANG_PROBE') or (os.environ.get('HANG_BUILD') and a[:1] == ['build']):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    pathlib.Path(os.environ['DOCKER_PID']).write_text(str(os.getpid()))
    os.write(1, b'partial stdout before hang\\n')
    os.write(2, b'last stderr before hang\\n')
    os.close(1); os.close(2)
    time.sleep(60)
phase = os.environ.get('STREAM_PHASE')
if (phase == 'query' and a[:2] == ['version', '--format']) or (phase == 'action' and a == ['version']):
    # Exceed a pipe's capacity and omit newlines: forwarding must not depend
    # on line buffering or wait for the process to exit.
    os.write(1, (phase + '-stdout|').encode() * 8192)
    os.write(2, (phase + '-stderr').encode())
    release = pathlib.Path(os.environ['STREAM_RELEASE'])
    until = time.monotonic() + 10
    while not release.exists() and time.monotonic() < until: time.sleep(0.01)
    if not release.exists(): sys.exit(8)
if os.environ.get('FAIL_QUERY') and a[:2] == ['version', '--format']:
    os.write(1, b'query failure on stdout\\n')
    os.write(2, b'query failure on stderr\\n')
    sys.exit(9)
if os.environ.get('FAIL_INSPECT') and a[:2] == ['image', 'inspect'] and '--format' not in a:
    os.write(1, b'inspect failure on stdout\\n')
    os.write(2, b'inspect failure on stderr\\n')
    sys.exit(1)
image = 'sha256:' + 'a' * 64
if a[:2] == ['volume', 'ls'] and os.environ.get('EXISTING_VOLUME'):
    print('glowcap-rooms-postgres\\nglowcap-rooms-session-state\\nglowcap-rooms-directory-state\\noperator-extra-volume')
if a[:2] == ['volume', 'rm'] and os.environ.get('FAIL_VOLUME') == a[-1]:
    sys.exit(9)
if a[:1] == ['build']:
    if os.environ.get('FAIL_BUILD'):
        os.write(1, b'build failure on stdout\\n')
        os.write(2, b'build failure on stderr\\n')
        sys.exit(9)
    root = pathlib.Path(a[-1])
    receipt = 'share/glowcap/installation.manifest'
    expected = {receipt}
    for row in (root / receipt).read_text().splitlines():
        digest, mode, name = row.split(' ', 2)
        expected.add(name)
        assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
    assert {p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file()} == expected
    assert a[a.index('--platform') + 1] in ('linux/amd64', 'linux/arm64')
    assert pathlib.Path(a[a.index('--file') + 1]).is_relative_to(root)
    pathlib.Path(a[a.index('--iidfile') + 1]).write_text(image + '\\n')
elif a[:2] == ['image', 'inspect']: print(image)
elif 'exec' in a: print('ocapn://fixture')
if a[:1] == ['compose'] and '--project-directory' in a:
    config = pathlib.Path(a[a.index('-f') + 1]).parent
    assert a[a.index('--project-directory') + 1] == str(config)
''')
    docker.chmod(0o755)
    return fakebin


def deployment(binary, root, scratch):
    fakebin = docker_fixture(scratch)
    log = scratch / "docker.log"
    env = dict(PATH=f"{fakebin}:/usr/bin:/bin", HOME=str(scratch), DOCKER_LOG=str(log))
    workspace = scratch / "deployment config"
    def call(*args, **kwargs):
        return run(binary, "apps", "rooms", "deployment", *args,
                   "--dir", workspace, env=env, **kwargs)
    call("doctor")
    assert not workspace.exists(), "doctor created state"
    env["EXISTING_VOLUME"] = "1"
    call("up", "--image", "example/rooms:test", ok=False)
    assert not (workspace / "secrets/storage-db-password").exists()
    # A failed first up leaves a directory, not a configured deployment.
    # Reset must protect an existing database before selecting a missing image.
    before_calls = log.read_text()
    incomplete = call("reset", "all", "--yes", ok=False)
    assert "MissingDatabaseSecret" in incomplete.stderr and str(workspace) in incomplete.stderr, incomplete.stderr
    new_calls = [json.loads(line) for line in log.read_text()[len(before_calls):].splitlines()]
    assert not any("up" in a or "down" in a or a[:2] == ["volume", "rm"] for a in new_calls)
    diagnosis = call("doctor")
    assert "selected image: none" in diagnosis.stdout and "database secret: missing" in diagnosis.stdout
    del env["EXISTING_VOLUME"]
    call("up", "--image", "example/rooms:test")
    secret = workspace / "secrets/storage-db-password"
    password = secret.read_bytes()
    assert len(password.strip()) == 64 and secret.stat().st_mode & 0o777 == 0o600
    diagnosis = call("doctor")
    assert "database secret: present (not authenticated)" in diagnosis.stdout
    assert password.decode().strip() not in diagnosis.stdout + diagnosis.stderr
    # A selected image alone does not make reset safe to restart.
    env["EXISTING_VOLUME"] = "1"
    secret.unlink()
    before_calls = log.read_text()
    incomplete = call("reset", "all", "--yes", ok=False)
    assert "MissingDatabaseSecret" in incomplete.stderr and str(workspace) in incomplete.stderr
    new_calls = [json.loads(line) for line in log.read_text()[len(before_calls):].splitlines()]
    assert not any("up" in a or "down" in a or a[:2] == ["volume", "rm"] for a in new_calls)
    secret.write_bytes(b"\n")
    diagnosis = call("doctor")
    assert "database secret: empty" in diagnosis.stdout
    before_calls = log.read_text()
    incomplete = call("reset", "all", "--yes", ok=False)
    assert "EmptyDatabaseSecret" in incomplete.stderr and str(workspace) in incomplete.stderr
    new_calls = [json.loads(line) for line in log.read_text()[len(before_calls):].splitlines()]
    assert not any("up" in a or "down" in a or a[:2] == ["volume", "rm"] for a in new_calls)
    secret.write_bytes(password)
    secret.chmod(0o600)
    del env["EXISTING_VOLUME"]
    selection = (workspace / "image").read_text()
    assert selection == "sha256:" + "a" * 64 + "\n"
    override = workspace / "docker-compose.override.yml"
    override.write_text(override.read_text() + "\n# operator choice\n")
    before = override.read_bytes()
    call("up")
    assert override.read_bytes() == before and secret.read_bytes() == password
    assert not (workspace / ".operation-lock").exists()
    assert not list(workspace.glob(".image-build-*"))
    # A recoverable probe may trigger a pull, but its diagnostics still belong
    # to the operator rather than disappearing into the presence check.
    env["FAIL_INSPECT"] = "1"
    recovered = call("up", "--image", "example/rooms:not-present")
    assert "inspect failure on stdout" in recovered.stderr and "inspect failure on stderr" in recovered.stderr
    assert "inspect failure" not in recovered.stdout
    del env["FAIL_INSPECT"]
    # Bad argv must not reach Docker at all.
    before_calls = log.read_text()
    call("up", "--image", "x", "--build", root, ok=False)
    assert log.read_text() == before_calls
    linux = json.loads((root / "share/glowcap/release.json").read_text())["target"].endswith("-linux")
    env["FAIL_BUILD"] = "1"
    failed_build = call("up", "--build", root, ok=False)
    assert (workspace / "image").read_text() == selection
    assert not (workspace / ".operation-lock").exists()
    if linux:
        assert any(json.loads(line)[0] == "build" for line in log.read_text().splitlines())
        assert "build failure on stdout" in failed_build.stdout
        assert "build failure on stderr" in failed_build.stderr
        assert 'docker "build"' in failed_build.stderr and "exited with code 9" in failed_build.stderr
    else:
        assert log.read_text() == before_calls
    del env["FAIL_BUILD"]
    fixture = scratch / "source fixture"
    metadata = fixture / "share/glowcap/release.json"
    value = json.loads(metadata.read_text())
    value["target"] = "aarch64-linux"
    metadata.write_text(json.dumps(value))
    receipt = fixture / "share/glowcap/installation.manifest"
    rows = []
    for row in receipt.read_text().splitlines():
        _, mode, name = row.split(" ", 2)
        rows.append(f"{hashlib.sha256((fixture / name).read_bytes()).hexdigest()} {mode} {name}\n")
    receipt.write_text("".join(rows))
    (fixture / "unlisted-build-cruft").write_text("not part of the product")
    call("up", "--build", fixture)
    assert not list(workspace.glob(".image-build-*"))
    checkout_deployment(binary, fixture, scratch, env)
    before_calls = log.read_text()
    (fixture / "README.md").write_text("changed beneath the recorded inventory")
    call("up", "--build", fixture, ok=False)
    new_calls = [json.loads(line) for line in log.read_text()[len(before_calls):].splitlines()]
    assert not any(a[0] == "build" for a in new_calls)
    assert not list(workspace.glob(".image-build-*"))
    before_calls = log.read_text()
    call("status")
    call("down")
    assert secret.read_bytes() == password
    assert not any(json.loads(line)[:2] == ["volume", "rm"] for line in log.read_text()[len(before_calls):].splitlines())
    compose = "\n".join(line.split("#", 1)[0] for line in (workspace / "compose.yml").read_text().splitlines())
    assert "zig-out" not in compose and ":/runtime" not in compose, "deployment mounts mutable build output"
    env["EXISTING_VOLUME"] = "1"
    before_calls = log.read_text()
    call("reset", "unknown", "--yes", ok=False)
    assert log.read_text() == before_calls
    refusal = call("reset", "all", detached=True, ok=False)
    assert "ConfirmationRequired" in refusal.stderr
    new_calls = [json.loads(line) for line in log.read_text()[len(before_calls):].splitlines()]
    assert not any(a[:2] == ["volume", "rm"] or "down" in a for a in new_calls)
    volumes = {"session": "glowcap-rooms-session-state", "state": "glowcap-rooms-directory-state",
               "storage": "glowcap-rooms-postgres"}
    for unit in (*volumes, "all"):
        before_calls = log.read_text()
        call("reset", unit, "--yes")
        new_calls = [json.loads(line) for line in log.read_text()[len(before_calls):].splitlines()]
        removed = [a[-1] for a in new_calls if a[:2] == ["volume", "rm"]]
        assert removed == (list(volumes.values()) if unit == "all" else [volumes[unit]])
        assert next(i for i, a in enumerate(new_calls) if "down" in a) < next(i for i, a in enumerate(new_calls) if a[:2] == ["volume", "rm"])
        assert next(i for i, a in enumerate(new_calls) if "up" in a) > max(i for i, a in enumerate(new_calls) if a[:2] == ["volume", "rm"])
        assert secret.read_bytes() == password
    env["FAIL_VOLUME"] = volumes["storage"]
    before_calls = log.read_text()
    failure = call("reset", "all", "--yes", ok=False)
    assert "stack remains stopped" in failure.stderr and volumes["storage"] in failure.stderr
    new_calls = [json.loads(line) for line in log.read_text()[len(before_calls):].splitlines()]
    assert [a[-1] for a in new_calls if a[:2] == ["volume", "rm"]] == list(volumes.values())
    assert not any("up" in a for a in new_calls), "partial reset silently restarted"
    print("glowcap-host-test: verified install, atomic selection, refusal and Docker command lifecycle passed")


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
                assert removed == ["glowcap-rooms-session-state", "glowcap-rooms-directory-state", "glowcap-rooms-postgres"]
                assert any("up" in a for a in calls)
            else:
                assert not removed and not any("down" in a or "up" in a for a in calls)
            assert not (workspace / ".operation-lock").exists()
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)
            os.close(master)


def child_output(binary, scratch):
    env = dict(PATH=f"{scratch / 'fake tools'}:/usr/bin:/bin", HOME=str(scratch),
               DOCKER_LOG=str(scratch / "docker.log"))
    workspace = scratch / "deployment config"
    args = [str(binary), "apps", "rooms", "deployment"]
    # A held-open child proves output arrives before completion. Successful
    # query stdout is private data; action stdout and all stderr remain live.
    for phase, verb in (("query", "status"), ("action", "doctor")):
        release = scratch / f"release-{phase}"
        child = subprocess.Popen([*args, verb, "--dir", str(workspace)],
                                 env=dict(env, STREAM_PHASE=phase, STREAM_RELEASE=str(release)),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        output = [bytearray(), bytearray()]
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(child.stdout, selectors.EVENT_READ, 0)
                selector.register(child.stderr, selectors.EVENT_READ, 1)
                expires = time.monotonic() + 5
                marker = f"{phase}-stderr".encode()
                while marker not in output[1] and time.monotonic() < expires:
                    for key, _ in selector.select(max(0, expires - time.monotonic())):
                        chunk = os.read(key.fileobj.fileno(), 16384)
                        if chunk:
                            output[key.data].extend(chunk)
                        else:
                            selector.unregister(key.fileobj)
                    if child.poll() is not None:
                        break
            assert marker in output[1], f"{phase} stderr was not forwarded while the child was running"
            assert child.poll() is None, "test child exited instead of waiting for its release"
            if phase == "action":
                assert b"action-stdout|" in output[0], "action stdout was buffered until completion"
            release.touch()
            stdout, stderr = child.communicate(timeout=5)
            output[0].extend(stdout)
            output[1].extend(stderr)
            assert child.returncode == 0, bytes(output[1])
            assert bytes(output[1]).count(marker) == 1, "stderr was replayed or duplicated"
            if phase == "query":
                assert b"query-stdout" not in output[0] + output[1], "query data leaked into product output"
            else:
                assert bytes(output[0]).count(b"action-stdout|") == 8192
                assert b"action-stdout" not in output[1] and marker not in output[0]
        finally:
            release.touch()
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=5)
    failed = run(binary, "apps", "rooms", "deployment", "status", "--dir", workspace,
                 env=dict(env, FAIL_QUERY="1"), ok=False)
    assert failed.stdout == ""
    assert "query failure on stdout" in failed.stderr and "query failure on stderr" in failed.stderr
    assert 'docker "version" "--format"' in failed.stderr and "exited with code 9" in failed.stderr


def checkout_deployment(binary, product, scratch, original_env):
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
    assert not state.exists()
    untouched(before)
    result = call("up", "--image", "fixture:test", ok=False)
    assert "MissingDatabaseSecret" in result.stderr and str(state) in result.stderr
    assert not (state / "secrets/storage-db-password").exists()
    untouched(before)
    call("up", "--dir", scratch / "explicit config", "--image", "fixture:test", ok=False)
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
    call("reset", "all", "--yes")
    calls = calls_since(before)
    assert not any(a[0] in ("build", "pull") for a in calls), "reset replaced its selected image"
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


def deadline(binary, scratch):
    # Even a child that closes its pipes and then hangs must be reaped. This
    # runs only in the focused host test; archive proofs reuse the quick cases.
    pid = scratch / "hung-docker.pid"
    env = dict(PATH=f"{scratch / 'fake tools'}:/usr/bin:/bin", HOME=str(scratch),
               DOCKER_LOG=str(scratch / "docker.log"), DOCKER_PID=str(pid), HANG_PROBE="1")
    result = run(binary, "apps", "rooms", "deployment", "status", env=env, ok=False)
    assert "DockerTimedOut" in result.stderr, result.stderr
    assert "last stderr before hang" in result.stderr and "partial stdout before hang" in result.stderr
    assert result.stdout == ""
    try:
        os.kill(int(pid.read_text()), 0)
    except ProcessLookupError:
        pass
    else:
        # This is a disposable child of the just-completed CLI; contain the
        # injected failure even when the product's retirement regression fires.
        os.kill(int(pid.read_text()), 9)
        raise AssertionError("timed-out Docker child survived")


def interruption(binary, scratch):
    workspace = scratch / "deployment config"
    fixture = scratch / "source fixture"
    (fixture / "README.md").write_text("fixture\n")
    selection = (workspace / "image").read_bytes()
    for sig in (signal.SIGINT, signal.SIGTERM):
        pid = scratch / f"interrupted-docker-{sig}.pid"
        env = dict(PATH=f"{scratch / 'fake tools'}:/usr/bin:/bin", HOME=str(scratch),
                   DOCKER_LOG=str(scratch / "docker.log"), DOCKER_PID=str(pid), HANG_BUILD="1")
        child = subprocess.Popen([str(binary), "apps", "rooms", "deployment", "up",
                                  "--dir", str(workspace), "--build", str(fixture)],
                                 env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            expires = time.monotonic() + 8
            while not pid.exists() and time.monotonic() < expires and child.poll() is None:
                time.sleep(0.02)
            assert pid.exists(), child.communicate(timeout=1)
            child.send_signal(sig)
            _, stderr = child.communicate(timeout=5)
            assert child.returncode != 0, stderr
            assert not list(workspace.glob(".image-build-*")), "interrupted build left product copies"
            assert (workspace / "image").read_bytes() == selection
            try:
                os.kill(int(pid.read_text()), 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError("interrupted Docker child survived")
        finally:
            if pid.exists():
                try:
                    os.kill(int(pid.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=5)


def main():
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != "--deadline"):
        raise SystemExit("usage: glowcap_host.py PRODUCT [--deadline]")
    root = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="glowcap-host-") as temporary:
        scratch = Path(temporary)
        os.chdir(scratch)
        if len(sys.argv) == 3:
            docker_fixture(scratch)
            deadline(root / "bin/glowcap", scratch)
            print("glowcap-host-test: timed-out Docker child diagnostics and retirement passed")
            return
        binary = installation(root, scratch)
        deployment(binary, root, scratch)
        reset_prompt(binary, scratch)
        child_output(binary, scratch)
        interruption(binary, scratch)


if __name__ == "__main__":
    main()
