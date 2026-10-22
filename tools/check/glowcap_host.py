#!/usr/bin/env python3
"""Host installation/deployment process proof, called by glowcap-host-test.

Uses the public CLI from a foreign cwd. Docker is a recording fixture here;
the release workflow separately runs the actual image on both Linux targets.
Damaged inventories, unrelated executables, and failed builds must fail
without activating or destroying another product.
The build gives installation, each deployment scenario, and the exhausted
query budget separate process limits, so one scenario's growth never spends
another's deadline. Individual product commands also retain their deadlines.
"""
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from deployment.confirmation import reset_prompt
from deployment.checkout import checkout_deployment
from deployment.volumes import selected_volumes


def run(binary, *args, env, ok=True, detached=False):
    result = subprocess.run([str(binary), *map(str, args)], env=env,
                            capture_output=True, text=True, timeout=20,
                            start_new_session=detached)
    assert (result.returncode == 0) == ok, (args, result)
    return result


def source_fixture(root, scratch, manifest):
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
    (fixture / "share/glowcap/installation.manifest").write_text("".join(rows))
    return fixture, rows


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

    fixture, rows = source_fixture(root, scratch, manifest)
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
    print('glowcap-rooms-session-state\\nglowcap-rooms-directory-state\\noperator-extra-volume')
    if os.environ.get('CUSTOM_VOLUMES'): print('custom-session\\ncustom-directory')
if a[:1] == ['compose'] and a[-3:] == ['config', '--format', 'json']:
    prefix = 'custom-' if os.environ.get('CUSTOM_VOLUMES') else 'glowcap-rooms-'
    names = ['session', 'directory'] if os.environ.get('CUSTOM_VOLUMES') else ['session-state', 'directory-state']
    model = {'services': {}, 'volumes': {}}
    for service, source, target, name in zip(['session', 'directory'], ['session-state', 'directory-state'], ['/session-state', '/state'], names):
        model['services'][service] = {'volumes': [{'type': 'volume', 'source': source, 'target': target}]}
        model['volumes'][source] = {'name': prefix + name, 'external': bool(os.environ.get('EXTERNAL_VOLUMES'))}
    if os.environ.get('BIND_VOLUME'): model['services']['session']['volumes'][0]['type'] = 'bind'
    if os.environ.get('SHARED_VOLUME'): model['volumes']['directory-state']['name'] = model['volumes']['session-state']['name']
    print(json.dumps(model))
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
    pathlib.Path(os.environ['DOCKER_LOG'] + '.label').write_text(a[a.index('--label') + 1].split('=', 1)[1])
elif a[:2] == ['image', 'inspect'] and 'Labels' in ' '.join(a):
    label = pathlib.Path(os.environ['DOCKER_LOG'] + '.label')
    print(label.read_text() if label.exists() else '<no value>')
elif a[:2] == ['image', 'inspect']: print(image)
elif 'exec' in a:
    if a[-1] == '--print-link': print('ocapn://127.0.0.1%3A9300.tcp/s/eA?captp-websocket=ws%3A%2F%2F127.0.0.1%3A9300%2Fcaptp&trace-publish=ws%3A%2F%2F127.0.0.1%3A9300%2Fpublish')
    else: print('ocapn://management' if a[-1] == '--file=/session-state/control.sturdyref' else 'ocapn://fixture')
if a[:1] == ['compose'] and '--project-directory' in a:
    config = pathlib.Path(a[a.index('-f') + 1]).parent
    assert a[a.index('--project-directory') + 1] == str(config)
''')
    docker.chmod(0o755)
    return fakebin


class Deployment:
    """One scenario's Docker fixture, environment, and deployment workspace."""

    def __init__(self, binary, scratch):
        self.binary = binary
        self.scratch = scratch
        self.log = scratch / "docker.log"
        self.env = dict(PATH=f"{docker_fixture(scratch)}:/usr/bin:/bin", HOME=str(scratch),
                        DOCKER_LOG=str(self.log))
        self.workspace = scratch / "deployment config"

    def call(self, *args, **kwargs):
        return run(self.binary, "apps", "rooms", "deployment", *args,
                   "--dir", self.workspace, env=self.env, **kwargs)

    def select(self, revision):
        """Select the fixture image as if a product at `revision` built it."""
        self.call("up", "--image", "example/rooms:test")
        Path(f"{self.log}.label").write_text(revision)
        return revision


def lifecycle(deploy, root):
    log, env, workspace, call = deploy.log, deploy.env, deploy.workspace, deploy.call
    call("doctor")
    assert not workspace.exists(), "doctor created state"
    before_up = log.read_text()
    started = call("up", "--image", "example/rooms:test")
    assert "Shared-session workspace capability:\nocapn://fixture" in started.stdout, started.stdout
    assert "Shared-session management capability:\nocapn://management" in started.stdout, started.stdout
    assert "ROOMS-TRACE-LISTENING ocapn://127.0.0.1%3A9300.tcp/s/" in started.stdout, started.stdout
    before_trace = len(log.read_text())
    call("trace", "--json")
    call("trace")
    trace_calls = [json.loads(line) for line in log.read_text()[before_trace:].splitlines()]
    viewers = [a[a.index("run"):] for a in trace_calls if "run" in a]
    viewer = ["run", "--rm", "--no-deps", "-T", "--entrypoint", "/runtime/bin/glowcap",
              "directory", "apps", "rooms", "trace", "--state=/state", "--url=http://directory:8080"]
    assert viewers == [viewer + ["--json"], viewer], trace_calls
    # Saved capabilities print as complete recipes only with the locator the
    # directory advertises, which up has just read from it.
    capabilities = next(json.loads(line) for line in log.read_text()[len(before_up):].splitlines()
                        if json.loads(line)[-2:] == ["directory", "capabilities"])
    assert "GLOWCAP_ROOMS_LOCATOR=ocapn://fixture" in capabilities, capabilities
    assert any(value.startswith("GLOWCAP_ROOMS_TRACE_LOCATOR=ocapn://127.0.0.1%3A9300.tcp") for value in capabilities), capabilities
    selection = (workspace / "image").read_text()
    assert selection == "sha256:" + "a" * 64 + "\n"
    override = workspace / "docker-compose.override.yml"
    override.write_text(override.read_text() + "\n# operator choice\n")
    before = override.read_bytes()
    before_up = len(log.read_text())
    call("up")
    up_calls = [json.loads(line) for line in log.read_text()[before_up:].splitlines()]
    assert not any("--force-recreate" in args for args in up_calls), "unchanged up forcibly replaced healthy services"
    assert override.read_bytes() == before
    assert not (workspace / ".operation-lock").exists()
    assert not list(workspace.glob(".image-build-*"))
    before_restart = len(log.read_text())
    call("restart")
    restart_calls = [json.loads(line) for line in log.read_text()[before_restart:].splitlines()]
    assert not any(args[0] in ("build", "pull") or args[:2] == ["volume", "rm"] or "down" in args
                   for args in restart_calls), "restart selected an image or destroyed deployment data"
    restarted = next(i for i, args in enumerate(restart_calls) if "restart" in args)
    waited = next(i for i, args in enumerate(restart_calls) if "up" in args and "--wait" in args)
    assert restarted < waited, "restart returned before checking service health"
    assert (workspace / "image").read_text() == selection
    assert override.read_bytes() == before
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


def builds(deploy, scratch):
    log, env, workspace, call = deploy.log, deploy.env, deploy.workspace, deploy.call
    call("up", "--image", "example/rooms:test")
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
    built = call("up", "--build", fixture)
    assert not list(workspace.glob(".image-build-*"))
    # The image carries the revision its product recorded, and the operator is
    # told which image was built and from where.
    recorded = json.loads(metadata.read_text())
    revision = recorded["revision"] + ("-dirty" if recorded.get("dirty") else "")
    build_call = next(json.loads(line) for line in reversed(log.read_text().splitlines()) if json.loads(line)[0] == "build")
    assert build_call[build_call.index("--label") + 1] == f"org.opencontainers.image.revision={revision}", build_call
    assert f"Built and selected image sha256:{'a' * 12} from {fixture} at revision {revision}" in built.stderr, built.stderr
    checkout_deployment(deploy.binary, fixture, scratch, env, run)
    before_calls = log.read_text()
    (fixture / "README.md").write_text("changed beneath the recorded inventory")
    call("up", "--build", fixture, ok=False)
    new_calls = [json.loads(line) for line in log.read_text()[len(before_calls):].splitlines()]
    assert not any(a[0] == "build" for a in new_calls)
    assert not list(workspace.glob(".image-build-*"))


def reset(deploy):
    log, env, workspace, call = deploy.log, deploy.env, deploy.workspace, deploy.call
    revision = deploy.select("fixture-revision")
    before_calls = log.read_text()
    call("status")
    call("down")
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
    volumes = {"session": "glowcap-rooms-session-state", "state": "glowcap-rooms-directory-state"}
    for unit in (*volumes, "all"):
        before_calls = log.read_text()
        reset = call("reset", unit, "--yes")
        # Reset keeps the selection, and says so with its revision, so fresh
        # data on an older image is never a silent surprise.
        assert f"Keeping the selected image sha256:{'a' * 12} at revision {revision}" in reset.stderr, reset.stderr
        new_calls = [json.loads(line) for line in log.read_text()[len(before_calls):].splitlines()]
        removed = [a[-1] for a in new_calls if a[:2] == ["volume", "rm"]]
        assert removed == (list(volumes.values()) if unit == "all" else [volumes[unit]])
        assert next(i for i, a in enumerate(new_calls) if "down" in a) < next(i for i, a in enumerate(new_calls) if a[:2] == ["volume", "rm"])
        assert next(i for i, a in enumerate(new_calls) if "up" in a) > max(i for i, a in enumerate(new_calls) if a[:2] == ["volume", "rm"])
    env["FAIL_VOLUME"] = volumes["state"]
    before_calls = log.read_text()
    failure = call("reset", "all", "--yes", ok=False)
    assert "stack remains stopped" in failure.stderr and volumes["state"] in failure.stderr
    new_calls = [json.loads(line) for line in log.read_text()[len(before_calls):].splitlines()]
    assert [a[-1] for a in new_calls if a[:2] == ["volume", "rm"]] == list(volumes.values())
    assert not any("up" in a for a in new_calls), "partial reset silently restarted"
    del env["FAIL_VOLUME"]
    selected_volumes(call, env, log)


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
    modes = ("--installation", "--deployment", "--deployment-builds", "--deployment-reset", "--deadline")
    if len(sys.argv) != 3 or sys.argv[2] not in modes:
        raise SystemExit(f"usage: glowcap_host.py PRODUCT {'|'.join(modes)}")
    root = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="glowcap-host-") as temporary:
        scratch = Path(temporary)
        os.chdir(scratch)
        mode = sys.argv[2]
        if mode == "--deadline":
            docker_fixture(scratch)
            deadline(root / "bin/glowcap", scratch)
            print("glowcap-host-test: timed-out Docker child diagnostics and retirement passed")
            return
        if mode == "--installation":
            installation(root, scratch)
            print("glowcap-host-test: verified installation, atomic selection and damaged-inventory refusal passed")
            return
        source_fixture(root, scratch, root / "share/glowcap/installation.manifest")
        if mode == "--deployment":
            # The lifecycle runs the installed product. The build and reset
            # scenarios exercise the same commands from the build output.
            prefix = scratch / "installed product"
            run(root / "bin/glowcap", "install", "--prefix", prefix, env=dict(PATH="", HOME=str(scratch)))
            binary = prefix / "bin/glowcap"
            lifecycle(Deployment(binary, scratch), root)
            child_output(binary, scratch)
            print("glowcap-host-test: installed Docker command lifecycle and live output passed")
        elif mode == "--deployment-builds":
            deploy = Deployment(root / "bin/glowcap", scratch)
            builds(deploy, scratch)
            interruption(deploy.binary, scratch)
            print("glowcap-host-test: image builds, checkout deployment, inventory refusal and interruption passed")
        else:
            deploy = Deployment(root / "bin/glowcap", scratch)
            reset(deploy)
            reset_prompt(deploy.binary, scratch)
            print("glowcap-host-test: status, down, reset and volume selection passed")


if __name__ == "__main__":
    main()
