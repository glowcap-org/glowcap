#!/usr/bin/env python3
"""Shared helpers for rooms-bot scripts.

Every message — heard, sent, or pending — is one ``channel`` ("room" or "dm")
plus ``peer`` on the dm arm. inbox.jsonl, outbox.jsonl, and pending.json all
speak it: no second discriminant, no per-file reshaping.
"""
from __future__ import annotations

import hashlib
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Iterator


# --- parameters -------------------------------------------------------------

def env(*names: str, default: str = "") -> str:
    for name in names:
        v = (os.environ.get(name) or "").strip()
        if v:
            return v
    return default


def require_bridge_dir() -> Path:
    raw = env("BRIDGE_DIR", "ROOMS_DIR")
    if not raw:
        raise SystemExit("rooms-bot: set BRIDGE_DIR")
    path = Path(raw)
    path.mkdir(parents=True, exist_ok=True)
    return path


def require_nick() -> str:
    nick = env("NICK", "ROOMS_NICK")
    if not nick:
        raise SystemExit("rooms-bot: set NICK")
    return nick


def room_name(override: str = "") -> str:
    return (override or env("ROOM", "ROOMS_ROOM") or "general").lstrip("#").lower() or "general"


def wake_token(nick: str) -> str:
    """The sentinel the wake loop prints and the agent's ``notify_on_output``
    matches. One formula, so the two can never drift out of match."""
    return f"AGENT_LOOP_TICK_rooms_{nick.lower()}"


def resolve_locator(locator: str) -> str:
    """Resolve a CapTP dial target.

    ``http(s)://…/locator`` bootstraps the live ``ocapn://`` URI from the rooms
    web UI (Docker DNS → pancake-rooms:8000), then CapTP dials over iroh.
    A bare ``host:port`` or ``ocapn://…`` URI passes through unchanged.
    """
    loc = locator.strip()
    if not loc:
        raise SystemExit("rooms-bot: empty locator")
    if loc.startswith("http://") or loc.startswith("https://"):
        import urllib.error
        import urllib.request

        try:
            with urllib.request.urlopen(loc, timeout=30) as resp:
                body = resp.read().decode("utf-8").strip().splitlines()[0].strip()
        except urllib.error.HTTPError as exc:
            raise SystemExit(
                f"rooms-bot: bootstrap {loc} failed: HTTP {exc.code}"
            ) from exc
        except Exception as exc:  # noqa: BLE001
            raise SystemExit(f"rooms-bot: bootstrap {loc} failed: {exc}") from exc
        if not body:
            raise SystemExit(f"rooms-bot: bootstrap {loc} returned empty body")
        if body.startswith("<") or " " in body:
            raise SystemExit(
                f"rooms-bot: bootstrap {loc} did not return a CapTP locator "
                f"(got {body[:60]!r}). Recreate the rooms deploy so GET /locator exists."
            )
        if not (body.startswith("ocapn://") or ":" in body):
            raise SystemExit(
                f"rooms-bot: bootstrap {loc} returned non-locator: {body[:80]!r}"
            )
        return body
    return loc


# --- files ------------------------------------------------------------------

def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def atomic_write_json(path: Path, data: Any) -> None:
    atomic_write_text(path, json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def append_jsonl(path: Path, obj: dict, *, fsync: bool = False) -> None:
    """Append one dict as a JSONL line, ts-stamped if it has no ts. ``fsync``
    for the inbox (the wake loop must never miss a heard line); a plain flush is
    enough for the outbox, which the peer polls."""
    line = dict(obj)
    line.setdefault("ts", utc_now())
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(line, ensure_ascii=False) + "\n")
        f.flush()
        if fsync:
            os.fsync(f.fileno())


def load_json_list(path: Path) -> list:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
        return raw if isinstance(raw, list) else []
    except Exception:
        return []


# --- replied ledger (dedup) -------------------------------------------------
# An insertion-ordered set: newest last, so the cap evicts the oldest, never a
# line the bot just handled.

def load_replied(bridge: Path) -> dict[str, None]:
    return dict.fromkeys(i for i in load_json_list(bridge / "replied.json") if isinstance(i, str))


def save_replied(bridge: Path, replied: dict[str, None], keep: int = 1200) -> None:
    atomic_write_json(bridge / "replied.json", list(replied)[-keep:])


def mark_replied(bridge: Path, ids: Iterable[str]) -> int:
    """The one door that writes the ledger. Moves re-marked ids to the fresh end
    so the recency cap keeps them. Returns how many were newly added."""
    replied = load_replied(bridge)
    added = 0
    for i in ids:
        if i in replied:
            del replied[i]
        else:
            added += 1
        replied[i] = None
    save_replied(bridge, replied)
    return added


# --- messages ---------------------------------------------------------------

def line_id(author: str, text: str, channel: str, peer: str, ts: str) -> str:
    """Stable, collision-free id for one heard line. ``ts`` makes a repeated line
    distinct; JSON-encoding the parts stops any value colliding across a delimiter."""
    return hashlib.sha1(
        json.dumps([author, text, channel, peer, ts], ensure_ascii=False).encode()
    ).hexdigest()[:20]


def scan_inbound(bridge: Path, nick: str, room: str, include_dm: bool = True) -> Iterator[dict]:
    """Yield one item per inbound line from someone else. inbox.jsonl is
    peer.py's alone, so this decodes exactly what it writes (``kind == "msg"``,
    ``channel``, ``peer`` on the dm arm); our ``sent`` echoes and ``system``
    lines fall out on the ``kind`` check. The one reader the pending poll and
    the backlog seed share."""
    inbox = bridge / "inbox.jsonl"
    if not inbox.exists():
        return
    self_l = nick.lower()
    mention = f"@{self_l}"
    with inbox.open(encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                j = json.loads(line)
            except Exception:
                continue
            if j.get("kind") != "msg":
                continue
            author = (j.get("author") or "").strip()
            text = (j.get("text") or "").strip()
            if not author or not text or author.lower() == self_l:
                continue
            ts = j.get("ts") or ""
            if (j.get("channel") or "room").lower() == "dm":
                if not include_dm:
                    continue
                peer = (j.get("peer") or author).strip()
                yield {
                    "id": line_id(author, text, "dm", peer, ts),
                    "channel": "dm",
                    "author": author,
                    "text": text,
                    "peer": peer,
                }
            else:
                yield {
                    "id": line_id(author, text, "room", "", ts),
                    "channel": "room",
                    "author": author,
                    "text": text,
                    "mention": mention in text.lower(),
                }


def poll_pending(bridge: Path, nick: str, room: str, include_dm: bool = True) -> list[dict]:
    """The unanswered inbound lines, deduped against ``replied.json`` and sorted
    the way a present person answers: DMs first, then ``@you`` mentions, then the
    rest of the room."""
    replied = load_replied(bridge)
    out: list[dict] = []
    seen: set[str] = set()
    for item in scan_inbound(bridge, nick, room, include_dm):
        mid = item["id"]
        if mid in replied or mid in seen:
            continue
        seen.add(mid)
        out.append(item)
    out.sort(
        key=lambda m: (
            0 if m["channel"] == "dm" else 1 if m.get("mention") else 2,
            m["id"],
        )
    )
    return out


def pending_fingerprint(items: list) -> tuple[int, str]:
    """Count and a stable fingerprint of a pending set's ids. The wake loop emits
    one card per distinct fingerprint, so the same unanswered set stays quiet."""
    ids = sorted(m.get("id") for m in items if isinstance(m, dict) and m.get("id"))
    fp = hashlib.sha1(json.dumps(ids, sort_keys=True).encode()).hexdigest()[:16] if ids else "-"
    return len(items), fp


def seed_backlog_replied(bridge: Path, nick: str, room: str, include_dm: bool = True) -> int:
    """Mark the inbox's existing lines answered, once, at peer startup — you do
    not answer scrollback from before you joined, so a restart won't flood the
    room. Returns how many lines were seeded."""
    ids = [item["id"] for item in scan_inbound(bridge, nick, room, include_dm)]
    if ids:
        mark_replied(bridge, ids)
    return len(ids)


# --- peer discovery ---------------------------------------------------------

def realpath(path: str | Path) -> str:
    try:
        return os.path.realpath(str(path))
    except OSError:
        return str(path)


def pid_owns_bridge(pid: int, bridge_dir: str) -> bool:
    want = realpath(bridge_dir)
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    try:
        raw = Path(f"/proc/{pid}/environ").read_bytes()
    except OSError:
        return False
    for entry in raw.split(b"\0"):
        if not entry.startswith(b"ROOMS_DIR="):
            continue
        got = entry.split(b"=", 1)[1].decode("utf-8", "replace")
        if realpath(got) == want or got == bridge_dir:
            return True
    return False


def find_bridge_pid(bridge_dir: str) -> int | None:
    bridge = Path(bridge_dir)
    pid_path = bridge / "bridge.pid"
    try:
        pid = int(pid_path.read_text(encoding="utf-8").strip())
    except Exception:
        pid = None
    if pid is not None and pid_owns_bridge(pid, bridge_dir):
        return pid
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        candidate = int(name)
        if pid_owns_bridge(candidate, bridge_dir):
            try:
                atomic_write_text(pid_path, f"{candidate}\n")
            except OSError:
                pass
            return candidate
    return None
