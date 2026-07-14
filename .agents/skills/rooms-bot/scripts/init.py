#!/usr/bin/env python3
"""Initialize a rooms-bot CapTP harness directory + print the run commands."""
from __future__ import annotations

import argparse
import json
import os
import stat
import sys
from pathlib import Path

from lib import atomic_write_json, atomic_write_text, env, wake_token


def main() -> None:
    p = argparse.ArgumentParser(description="rooms-bot init (CapTP peer)")
    p.add_argument("--nick", default=env("NICK", "ROOMS_NICK"))
    p.add_argument("--dir", default=env("BRIDGE_DIR", "ROOMS_DIR"))
    p.add_argument("--room", default=env("ROOM", "ROOMS_ROOM") or "general")
    p.add_argument(
        "--locator",
        default=env("ROOMS_LOCATOR") or "http://pancake-rooms:8000/locator",
        help=(
            "CapTP dial target or HTTP bootstrap URL. "
            "Default: http://pancake-rooms:8000/locator (iroh Discovery)."
        ),
    )
    args = p.parse_args()
    if not args.nick or not args.dir:
        print("rooms-bot init: need --nick and --dir (or NICK + BRIDGE_DIR)", file=sys.stderr)
        sys.exit(2)
    locator = (args.locator or "").strip()
    if not locator:
        print("rooms-bot init: need --locator (or ROOMS_LOCATOR)", file=sys.stderr)
        sys.exit(2)

    bridge = Path(args.dir)
    bridge.mkdir(parents=True, exist_ok=True)
    room = args.room.lstrip("#") or "general"
    token = wake_token(args.nick)

    for name in ("replied.json", "pending.json"):
        path = bridge / name
        if not path.exists():
            atomic_write_json(path, [])
    for name in ("inbox.jsonl", "outbox.jsonl"):
        path = bridge / name
        if not path.exists():
            atomic_write_text(path, "")

    # The ROOMS_* spellings are the upstream rooms client's env contract (and the
    # name pid discovery greps for); the plain spellings are what these scripts
    # read. env.sh exports both from one place.
    exports = {
        "NICK": args.nick,
        "ROOMS_NICK": args.nick,
        "ROOM": room,
        "ROOMS_ROOM": room,
        "BRIDGE_DIR": str(bridge),
        "ROOMS_DIR": str(bridge),
        "ROOMS_LOCATOR": locator,
        "WAKE_TOKEN": token,
        "POLL_SEC": "1",
        "OUTBOX_POLL_SEC": "0.25",
    }
    env_lines = ["#!/usr/bin/env bash"] + [f"export {k}={v!r}" for k, v in exports.items()] + [""]
    env_path = bridge / "env.sh"
    atomic_write_text(env_path, "\n".join(env_lines))
    os.chmod(env_path, os.stat(env_path).st_mode | stat.S_IXUSR)

    scripts = Path(__file__).resolve().parent
    peer = f"source {env_path} && python3 {scripts / 'peer.py'}"
    wake = f"source {env_path} && python3 {scripts / 'wake_loop.py'}"
    print(
        json.dumps(
            {
                "ok": True,
                "bridge_dir": str(bridge),
                "nick": args.nick,
                "room": room,
                "locator": locator,
                "wake_token": token,
                "notify_pattern": f"^{token}",
                "env_file": str(env_path),
                "peer_cmd": peer,
                "wake_cmd": wake,
                "next": [
                    f"source {env_path}",
                    f"{peer} &",
                    f"{wake}  # background; notify_on_output on notify_pattern",
                ],
            },
            indent=2,
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
