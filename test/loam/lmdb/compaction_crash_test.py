"""loam-lmdb-compaction-crash-test: verify process loss and an LMDB file-size limit.

The build supplies one probe executable. Each child has a deadline and is reaped;
temporary stores are removed on every outcome. No environment or repository cwd
is required. Success is silent; failures return nonzero.
"""
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile


def run(probe, mode, directory):
    subprocess.run([probe, mode, directory], cwd=directory, check=True, timeout=5)


def interrupt(probe, boundary, directory):
    child = subprocess.Popen(
        [probe, boundary, directory], cwd=directory,
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )
    try:
        ready, _, _ = select.select([child.stderr], [], [], 5)
        if not ready or os.read(child.stderr.fileno(), 4096) != b"READY\n":
            raise AssertionError(f"{boundary}: child did not reach replacement boundary")
        run(probe, "compete", directory)
        child.kill()
        if child.wait(timeout=5) != -signal.SIGKILL:
            raise AssertionError("child was not killed at the requested boundary")
    finally:
        if child.poll() is None:
            child.kill()
        child.wait(timeout=5)
        child.stderr.close()


def main():
    if len(sys.argv) != 2:
        raise ValueError("expected replacement probe executable")
    probe = str(Path(sys.argv[1]).resolve(strict=True))
    for boundary in ("before", "prepared", "installed", "synced", "capacity"):
        with tempfile.TemporaryDirectory(prefix="glowcap loam replacement ") as directory:
            run(probe, "create", directory)
            data = Path(directory) / "data.mdb"
            before = data.stat()
            lock = (Path(directory) / "loam-owner.lock").stat()
            if boundary == "capacity":
                run(probe, boundary, directory)
            else:
                interrupt(probe, boundary, directory)
            after = data.stat()
            replaced = boundary in ("installed", "synced")
            if (after.st_ino != before.st_ino) != replaced:
                raise AssertionError(f"{boundary}: unexpected data file selection")
            if replaced and after.st_size >= before.st_size:
                raise AssertionError(f"{boundary}: copy did not shrink reclaimed pages")
            if (Path(directory) / "loam-owner.lock").stat().st_ino != lock.st_ino:
                raise AssertionError("replacement changed owner lock identity")
            # A corrupt leftover must never override the installed authority.
            (Path(directory) / "loam-compact.mdb").write_bytes(b"invalid stale copy")
            run(probe, "verify", directory)
            run(probe, "changed-cwd", directory)
            run(probe, "verify", directory)
            if (Path(directory) / "loam-compact.mdb").exists():
                raise AssertionError("completed maintenance retained its temporary copy")


if __name__ == "__main__":
    main()
