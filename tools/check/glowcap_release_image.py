#!/usr/bin/env python3
"""Exercise a release image through Docker, without a checkout mount.

The release workflow calls this after loading the exact single-platform image
artifact it uploads. Docker is the host-side test driver; every command run in
the distroless container is a public glowcap product command. The 256 MiB filesystem
ceiling covers the measured 206 MiB ReleaseSafe product plus the 27 MiB pinned
base, while rejecting a duplicated runtime. The exact manifest inventory
separately rejects extra files and SDK content.
"""

import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import secrets
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request


# Compose the inventory export and two service journeys under one deadline.
LIMIT_SECONDS = 60
MAX_IMAGE_BYTES = 256 * 1024 * 1024
FORBIDDEN_BASE_PROGRAMS = {
    "apk", "apt", "apt-get", "ash", "bash", "busybox", "dash", "dnf",
    "dpkg", "dpkg-deb", "dpkg-query", "microdnf", "rpm", "sh", "yum",
    "zypper",
}


class Deadline:
    def __init__(self):
        self.end = time.monotonic() + LIMIT_SECONDS

    def timeout(self, cap=10):
        remaining = self.end - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"image proof exceeded {LIMIT_SECONDS} seconds")
        return max(0.1, min(cap, remaining))


def run(deadline, *args, check=True, text=True, cap=10):
    return subprocess.run(args, check=check, capture_output=True, text=text,
                          timeout=deadline.timeout(cap))


def cleanup_run(*args):
    try:
        return subprocess.run(args, check=False, capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired as error:
        return subprocess.CompletedProcess(
            args, 124, error.stdout or "", error.stderr or "cleanup command timed out"
        )


def container_name(role):
    # The proof only ever removes names it minted. Randomness also prevents a
    # stale container from an interrupted earlier run becoming our cleanup status-allow: event or source ordering
    # target when process IDs are reused.
    return f"glowcap-image-{role}-{secrets.token_hex(12)}"


def remove_container(name, require_clean):
    removed = cleanup_run("docker", "container", "rm", "--force", name)
    if removed.returncode == 0:
        return
    message = f"could not remove owned container {name}: {removed.stderr}"
    if require_clean:
        raise AssertionError(message)
    sys.stderr.write(message + "\n")


def inspect_image(deadline, image, expected_arch):
    report = json.loads(run(deadline, "docker", "image", "inspect", image).stdout)
    assert len(report) == 1, "Docker resolved more than one image"
    image_data = report[0]
    assert image_data["Architecture"] == expected_arch, image_data["Architecture"]
    assert image_data["Os"] == "linux", image_data["Os"]
    assert not image_data["Config"].get("Volumes"), "image declares mutable volumes"
    assert image_data["Config"]["Entrypoint"] == [
        "/runtime/bin/glowcap", "apps", "rooms", "serve"
    ], image_data["Config"]["Entrypoint"]


def normalized_path(name):
    while name.startswith("./"):
        name = name[2:]
    return PurePosixPath(name)


def inspect_tar(rootfs):
    members = rootfs.getmembers()
    # Docker's Size differs between classic and containerd image stores.
    # Exported regular-file bytes describe the same filesystem on both.
    size = sum(member.size for member in members if member.isfile())
    assert size <= MAX_IMAGE_BYTES, f"image filesystem is {size} bytes; budget is {MAX_IMAGE_BYTES}"
    forbidden = sorted({
        normalized_path(member.name).as_posix()
        for member in members
        if not member.isdir() and normalized_path(member.name).name in FORBIDDEN_BASE_PROGRAMS
    })
    assert not forbidden, f"image base contains a shell or package manager: {forbidden}"

    runtime = {}
    runtime_root = PurePosixPath("runtime")
    for member in members:
        path = normalized_path(member.name)
        if path == runtime_root:
            assert member.isdir(), "image /runtime is not a directory"
            continue
        if not path.is_relative_to(runtime_root):
            continue
        relative = path.relative_to(runtime_root).as_posix()
        if member.isdir():
            continue
        assert member.isfile(), f"image /runtime contains a link or special file: {relative}"
        assert relative not in runtime, f"image /runtime repeats a member: {relative}"
        assert not member.mode & 0o7000, f"image /runtime has privileged mode bits: {relative}"
        runtime[relative] = member

    manifest_name = "share/glowcap/installation.manifest"
    manifest_member = runtime.get(manifest_name)
    assert manifest_member is not None, "image has no product installation manifest"
    assert not manifest_member.mode & 0o111, "product installation manifest is executable"
    manifest = rootfs.extractfile(manifest_member).read().decode()
    expected = {manifest_name: None}
    previous = ""
    for line in manifest.splitlines():
        fields = line.split(" ", 2)
        assert len(fields) == 3, f"malformed product manifest row: {line}"
        digest, mode, path = fields
        assert re.fullmatch(r"[0-9a-f]{64}", digest), line
        assert mode in ("x", "-"), line
        parsed = PurePosixPath(path)
        assert path and parsed.parts and not parsed.is_absolute(), path
        assert all(part not in ("", ".", "..") for part in path.split("/")), path
        assert path > previous and path != manifest_name, path
        expected[path] = (digest, mode == "x")
        previous = path
    assert "bin/glowcap" in expected and expected["bin/glowcap"][1], (
        "product manifest has no executable bin/glowcap"
    )

    assert set(runtime) == set(expected), (
        "image /runtime differs from the verified product manifest",
        sorted(set(runtime) - set(expected)),
        sorted(set(expected) - set(runtime)),
    )
    for path, contract in expected.items():
        if contract is None:
            continue
        digest, executable = contract
        member = runtime[path]
        content = rootfs.extractfile(member).read()
        assert hashlib.sha256(content).hexdigest() == digest, f"image checksum mismatch: {path}"
        assert bool(member.mode & 0o111) == executable, f"image mode mismatch: {path}"

        parts = PurePosixPath(path).parts
        assert parts[0] not in {"src", "test", "tools", ".git"}, path
        assert not path.startswith("include/"), f"image contains SDK header: {path}"
        assert not path.endswith(".a"), f"image contains SDK archive: {path}"
        assert PurePosixPath(path).name not in {"zig", "cargo", "rustc"}, (
            f"image contains a build tool: {path}"
        )


def inspect_runtime_inventory(deadline, image, scratch):
    name = container_name("inventory")
    exported = scratch / "rootfs.tar"
    exported_cleanly = False
    try:
        run(deadline, "docker", "container", "create", "--name", name,
            "--entrypoint", "/runtime/bin/glowcap", image, "--help")
        run(deadline, "docker", "container", "export", "--output", str(exported), name, cap=30)
        exported_cleanly = True
    finally:
        remove_container(name, exported_cleanly)

    with tarfile.open(exported) as rootfs:
        inspect_tar(rootfs)


def wait_for(deadline, description, probe, container):
    last = None
    while time.monotonic() < deadline.end:
        last = probe()
        if last.returncode == 0:
            return last
        state = run(deadline, "docker", "container", "inspect", "--format",
                    "{{.State.Running}}", container, check=False)
        if state.returncode != 0 or state.stdout.strip() != "true":
            break
        time.sleep(0.1)
    detail = "" if last is None else f"\nstdout:\n{last.stdout}\nstderr:\n{last.stderr}"
    raise AssertionError(f"{description} did not become ready{detail}")


def stop(name, require_clean):
    stopped = cleanup_run("docker", "container", "stop", "--time", "5", name)
    logs = cleanup_run("docker", "container", "logs", name)
    state = cleanup_run("docker", "container", "inspect", "--format",
                        "{{.State.ExitCode}}", name)
    removed = cleanup_run("docker", "container", "rm", "--force", name)
    if require_clean and (
        stopped.returncode != 0 or state.returncode != 0 or
        state.stdout.strip() != "0" or removed.returncode != 0
    ):
        raise AssertionError(
            f"{name} did not retire cleanly\nstdout:\n{logs.stdout}\nstderr:\n{logs.stderr}"
        )
    if not require_clean and removed.returncode != 0:
        sys.stderr.write(f"could not remove failed container {name}: {removed.stderr}\n")


def check_web_and_directory(deadline, image):
    name = container_name("web")
    passed = False
    try:
        started = run(
            deadline, "docker", "run", "--detach", "--name", name,
            "--publish", "127.0.0.1::8080", image,
            "--http-bind=0.0.0.0", "--http-port=8080", "--transport=tcp",
            "--reachability=direct", "--state=/state",
        )
        assert started.stdout.strip(), "Docker did not return a browser container ID"

        def status():
            return run(
                deadline, "docker", "exec", name, "/runtime/bin/glowcap",
                "apps", "rooms", "status", "--url=http://127.0.0.1:8080",
                check=False,
            )

        wait_for(deadline, "Rooms browser and directory", status, name)
        locator = run(
            deadline, "docker", "exec", name, "/runtime/bin/glowcap",
            "apps", "rooms", "locator", "--url=http://127.0.0.1:8080",
        ).stdout.strip()
        assert locator.startswith("ocapn://"), locator

        published = run(deadline, "docker", "port", name, "8080/tcp").stdout.splitlines()
        address = next(line for line in published if line.startswith("127.0.0.1:"))
        url = f"http://{address}"
        with urllib.request.urlopen(url, timeout=deadline.timeout(5)) as response:
            html = response.read().decode()
            assert response.status == 200 and "<html" in html
        assets = re.findall(r'(?:src|href)\s*=\s*"([^"#]+)"', html)
        assert any(".js" in asset for asset in assets), "page has no application script"
        for asset in assets:
            target = urllib.parse.urljoin(url + "/", asset)
            assert target.startswith(url + "/"), "page depends on an external asset"
            with urllib.request.urlopen(target, timeout=deadline.timeout(5)) as response:
                assert response.status == 200 and response.read(), asset
        passed = True
    except Exception:
        logs = cleanup_run("docker", "container", "logs", name)
        sys.stderr.write(f"browser container logs:\n{logs.stdout}{logs.stderr}")
        raise
    finally:
        stop(name, passed)


def check_session(deadline, image):
    name = container_name("session")
    volume = container_name("session-state")
    ready = "/run/rooms-session/admin.sturdyref"
    passed = False
    try:
        run(deadline, "docker", "volume", "create", volume)

        def start():
            started = run(
                deadline, "docker", "run", "--detach", "--name", name,
                "--mount", f"type=volume,source={volume},target=/session-state",
                "--tmpfs", "/run/rooms-session:mode=0700",
                "--entrypoint", "/runtime/bin/glowcap", image,
                "apps", "rooms", "session", "serve", "--dir=/session-state",
                "--transport=iroh", "--reachability=discovery", f"--readiness-file={ready}",
            )
            assert started.stdout.strip(), "Docker did not return a session container ID"

        def readiness():
            return run(
                deadline, "docker", "exec", name, "/runtime/bin/glowcap",
                "apps", "rooms", "session", "ready", f"--file={ready}",
                check=False,
            )

        def management():
            return run(deadline, "docker", "exec", name, "/runtime/bin/glowcap",
                       "apps", "rooms", "session", "ready",
                       "--file=/session-state/control.sturdyref").stdout.strip()

        start()
        capability = wait_for(deadline, "Rooms session", readiness, name).stdout.strip()
        assert capability.startswith("ocapn://"), capability
        control = management()
        assert control != capability, "management shares the workspace publication"
        run(deadline, "docker", "restart", "--time", "5", name)
        assert wait_for(deadline, "restarted Rooms session", readiness, name).stdout.strip() == capability, (
            "container restart changed the session locator or workspace publication"
        )
        assert management() == control, "container restart changed session management"
        stop(name, True)
        start()
        assert wait_for(deadline, "recreated Rooms session", readiness, name).stdout.strip() == capability, (
            "container recreation changed the session locator or workspace publication"
        )
        assert management() == control, "container recreation changed session management"
        passed = True
    except Exception:
        logs = cleanup_run("docker", "container", "logs", name)
        sys.stderr.write(f"session container logs:\n{logs.stdout}{logs.stderr}")
        raise
    finally:
        try:
            stop(name, passed)
        finally:
            removed = cleanup_run("docker", "volume", "rm", volume)
            if removed.returncode != 0:
                message = f"could not remove owned session volume {volume}: {removed.stderr}"
                if passed:
                    raise AssertionError(message)
                sys.stderr.write(message + "\n")


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in ("amd64", "arm64"):
        raise SystemExit("usage: glowcap_release_image.py IMAGE amd64|arm64")
    image, expected_arch = sys.argv[1:]
    deadline = Deadline()
    with tempfile.TemporaryDirectory(prefix="glowcap-image-") as temporary:
        inspect_image(deadline, image, expected_arch)
        inspect_runtime_inventory(deadline, image, Path(temporary))
        check_web_and_directory(deadline, image)
        check_session(deadline, image)
    print("glowcap-image: bounded image, exact product inventory, browser, directory and durable session restart passed")


if __name__ == "__main__":
    main()
