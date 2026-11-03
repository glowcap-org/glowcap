"""The compiled state a CI build job hands to the test jobs of its group.

Called by check-group.yml on the runner host, outside the devcontainer,
from any directory.

    ci/state.py stores                    print each store, one per line
    ci/state.py stamp                     set every tracked file's mtime to the commit time
    ci/state.py bound LIMIT_GB FLOOR_GB   empty the stores when they outgrow the limit
                                          or leave less than the floor free
    ci/state.py pack ARCHIVE              write the stores and zig-out to a zstd tar
    ci/state.py restore DIR SHARDS BUILD  unpack every shard's archive found in DIR

Zig keys its cache by content, but Cargo calls an output stale when a source
is newer than it. Two jobs check the same commit out at different times, so
both stamp the checkout to the commit time first: the build job's outputs
are then newer than every source in the test job too. zig-out travels with
the stores because the installer leaves an archive with unchanged bytes in
place, and Cargo's build scripts watch those archives' mtimes.

The archive keeps absolute paths, so pack and restore run as the same user
with the same home and checkout path, as every hosted runner does. Restore
overwrites files at the recorded paths and removes nothing. The running
container mounts the stores, so `bound` empties each in place: a removed
directory would leave its mount on a deleted inode.

`restore` takes the shards as a JSON array and the build job's result. The
first shard, which ran every Cargo build, lands last so Cargo's recorded
times win. Every shard of a successful build packed, so a missing archive is
a handoff defect and exits 1. A shard whose build failed hands over nothing,
and the test job compiles its share. A malformed call exits 2 with the usage.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path.home() / ".cache/glowcap"
CARGO_BUILD = CACHE / "ci/cargo-build"
STORES = (
    CACHE / "tool/zig",
    CACHE / "ci/zig-local",
    CARGO_BUILD,
    CACHE / "tool/deno/gen",
    CACHE / "tool/deno/check_cache_v2",
    CACHE / "tool/deno/dep_analysis_cache_v2",
)
# Deno's V8 code cache (`tool/deno/v8_code_cache_v2`) stays behind. V8 reads
# a cached script with no checksum (`verify_snapshot_checksum` is off in
# release builds), so a torn copy of that SQLite file is a fatal V8 error in
# the next `deno check` instead of a cache miss. Every other store's reader
# keys its entries by their inputs and recompiles on a mismatch.
GIB = 1 << 30


def say(message):
    print(f"ci/state.py: {message}", file=sys.stderr, flush=True)


def size(path):
    """Bytes a tree occupies on disk, as `du` counts them."""
    total = 0
    for directory, _, names in os.walk(path):
        for name in names:
            try:
                total += os.lstat(os.path.join(directory, name)).st_blocks * 512
            except OSError:
                pass  # tolerant: a file removed under the walk occupies nothing
    return total


def present():
    return [store for store in STORES if store.exists()]


def stamp():
    when = int(
        subprocess.run(
            ["git", "-C", ROOT, "log", "-1", "--format=%ct", "HEAD"], capture_output=True, text=True, check=True
        ).stdout
    )
    listing = subprocess.run(
        ["git", "-C", ROOT, "ls-files", "-z", "--recurse-submodules"], capture_output=True, check=True
    ).stdout
    for name in listing.decode("utf-8", "surrogateescape").split("\0"):
        path = ROOT / name
        # The index may name a file the checkout lacks, which stays absent.
        if name and (path.is_symlink() or path.exists()):
            os.utime(path, (when, when), follow_symlinks=False)


def bound(limit_gb, floor_gb):
    stores = present()
    used = sum(size(store) for store in stores)
    for store in stores:
        print(f"{size(store) / GIB:.2f} GiB  {store}")
    free = shutil.disk_usage("/").free
    print(f"Restored build state: {used / GIB:.2f} GiB of {limit_gb:.2f} GiB, {free / GIB:.2f} GiB free")
    if used > limit_gb * GIB or free < floor_gb * GIB:
        for store in stores:
            for child in store.iterdir():
                shutil.rmtree(child) if child.is_dir() and not child.is_symlink() else child.unlink()
        print("Dropped it; this run builds cold.")


def pack(archive):
    paths = present()
    if (ROOT / "zig-out").exists():
        paths.append(ROOT / "zig-out")
    if not paths:
        say("nothing to pack")
        return 1
    for path in paths:
        print(f"{size(path) / GIB:.2f} GiB  {path}")
    # Cargo keys each workspace's build directory by a hash of its path, and
    # `cargo metadata` run in that workspace names the directory. Size each
    # profile so the listing shows which build fills the store.
    for profile in sorted(CARGO_BUILD.glob("*/*/*/")):
        print(f"{size(profile) / GIB:.1f}G\t{profile.relative_to(CARGO_BUILD)}")
    subprocess.run(["tar", "-P", "--use-compress-program=zstd -T0 -3", "-cf", archive, *map(str, paths)], check=True)
    print(f"{Path(archive).stat().st_size} bytes  {archive}")
    return 0


def restore(directory, shards, build):
    archives = []
    for shard in sorted(json.loads(shards), reverse=True):
        archive = Path(directory) / f"state-{shard}.tar.zst"
        if archive.exists():
            archives.append(archive)
        elif build == "success":
            print(f"::error::Shard {shard} built but its state is not at {archive}.")
            return 1
        else:
            print(f"::warning::Shard {shard} handed over no state; this job compiles its share.")
    for archive in archives:
        subprocess.run(["tar", "-P", "--use-compress-program=zstd -d -T0", "-xf", archive], check=True)
        archive.unlink()
    return 0


def main(argv):
    parser = argparse.ArgumentParser(
        prog="ci/state.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    verbs = parser.add_subparsers(dest="verb", required=True)
    verbs.add_parser("stores")
    verbs.add_parser("stamp")
    bounding = verbs.add_parser("bound")
    bounding.add_argument("limit_gb", type=float)
    bounding.add_argument("floor_gb", type=float)
    verbs.add_parser("pack").add_argument("archive")
    restoring = verbs.add_parser("restore")
    for name in ("directory", "shards", "build"):
        restoring.add_argument(name)
    args = parser.parse_args(argv)
    if args.verb == "stores":
        print("\n".join(map(str, STORES)))
    elif args.verb == "stamp":
        stamp()
    elif args.verb == "bound":
        bound(args.limit_gb, args.floor_gb)
    elif args.verb == "pack":
        return pack(args.archive)
    else:
        return restore(args.directory, args.shards, args.build)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
