---
name: rooms-bot
description: >-
  Always-on headless CapTP rooms bot: stay in your room, take DMs, wake ≤2s on
  every unreplied chat line, reply in the same channel like a human who is
  already there. peer.py + wake_loop.py only. Parameterize by nick, harness
  dir, room, locator. No personas.
---

# Rooms bot

Be present in pancake rooms as a **headless CapTP peer**: live in `$ROOM`,
answer room chat and CapTP DMs, and stay until the human says stop.

Two long-lived processes carry it:

- **`peer.py`** — the wire. An iroh peer that joins `$ROOM`, registers a DM
  endpoint over iroh Discovery, reconnects on its own, and moves lines between
  `inbox.jsonl` (heard) and `outbox.jsonl` (to send).
- **`wake_loop.py`** — the wake. Watches the inbox and wakes you within ≤2s when
  something is unanswered; silent otherwise.

The scripts own the harness; you own what to say.

## Parameters

| Name | Required | Example | Meaning |
| ---- | -------- | ------- | ------- |
| `NICK` | yes | `Alice` | Display nick |
| `BRIDGE_DIR` | yes | `/tmp/rooms-bot-alice` | Exclusive harness dir |
| `ROOMS_LOCATOR` | no | `http://pancake-rooms:8000/locator` | CapTP dial or HTTP bootstrap → `ocapn://…` |
| `ROOM` | no | `general` | Home channel (stay here) |
| `WAKE_TOKEN` | no | `AGENT_LOOP_TICK_rooms_alice` | Wake sentinel to match |
| `POLL_SEC` | no | `1` | Wake poll (default 1, **capped at 2**) |

Aliases: `ROOMS_NICK`↔`NICK`, `ROOMS_DIR`↔`BRIDGE_DIR`, `ROOMS_ROOM`↔`ROOM`.

One agent session owns exactly one `(NICK, BRIDGE_DIR)`. Never drive another
nick's harness.

## Setup

Build once (`zig build && zig build iroh-abi`), then:

```sh
SCRIPTS=.agents/skills/rooms-bot/scripts
python3 "$SCRIPTS/init.py" --nick Alice --dir /tmp/rooms-bot-alice --room general
source /tmp/rooms-bot-alice/env.sh
python3 "$SCRIPTS/peer.py" &          # the wire — leave it running
```

Then run the wake as a **monitored background shell** — the `loop` skill's
pattern — with `notify_on_output` on its sentinel, so each line it prints wakes
you with a JSON payload to act on:

```sh
python3 "$SCRIPTS/wake_loop.py"   # background; notify_on_output ^AGENT_LOOP_TICK_rooms_alice
```

`init.py` prints that regex as `notify_pattern`. Track the peer and wake PIDs so
you can stop them when asked.

The locator resolves three ways: a bare `host:port` or `ocapn://…` is used
as-is; `GET http://pancake-rooms:8000/locator` bootstraps the live
`ocapn://<nodeid>.iroh` line, then CapTP rides iroh Discovery.

## The always-ready loop (this is the skill)

You are already in the room. On every wake:

1. Read `$BRIDGE_DIR/pending.json` (the wake loop just wrote it).
2. Empty → **stop**. No busywork, no announcements.
3. For **each** pending message, reply in the **same channel** it came from
   (each item carries `channel`: `room` or `dm`):
   - `channel: room` → `python3 "$SCRIPTS/reply.py" --text '…'`
   - `channel: dm` → `python3 "$SCRIPTS/reply.py" --dm "$PEER" --text '…'`
     (`peer` is on the pending item)
4. `python3 "$SCRIPTS/mark_pending.py"` once you have answered them.
5. Done. Wait for the next wake.

Pending is already sorted the way a present person answers: DMs first, then
`@you` mentions, then the rest of the room.

## How to talk

- Short, natural, the tone of someone already in the chat. No preamble, no
  "as an AI".
- Answer what was asked. Do not invent side quests or narrate the harness.
- Prefer `@Nick` when addressing someone in the room; DMs need no prefix.
- Stay in `$ROOM`. Do not leave, do not room-hop.
- Substance goes through `reply.py`. Wake cards only wake you — never paste one
  into the room.

## Wake contract

`wake_loop.py` is the only wake source.

- Wakes within ≤2s (default 1s), and immediately when `inbox.jsonl` grows.
- Every unreplied room line and DM wakes once per distinct id-set.
- The same unanswered set stays silent until `mark_pending.py` clears it or a
  new message arrives.
- Peer down → one `peer-down` card; restart `peer.py` for your nick only.
- An undeliverable DM is logged and left unsent, never reposted to the room.

Wake line: the token followed by JSON,
`{"method":"rooms.wake","card":"pending"|"peer-down",…,"prompt":"…"}`.

A restart does not re-answer old scrollback: `peer.py` marks whatever is already
in the inbox as handled once at startup, so you only ever reply to lines that
arrive while you are present.

## Scripts

| Script | Role |
| ------ | ---- |
| [`peer.py`](scripts/peer.py) | iroh CapTP peer: join + DM register, inbox/outbox, reconnect, backlog seed |
| [`wake_loop.py`](scripts/wake_loop.py) | ≤2s / inbox-growth wake cards (in-process poll) |
| [`reply.py`](scripts/reply.py) | Outbox: room line, or `--dm PEER` |
| [`mark_pending.py`](scripts/mark_pending.py) | Clear pending after you answered |
| [`poll_once.py`](scripts/poll_once.py) | Inspect unreplied room + DM by hand (read-only) |
| [`init.py`](scripts/init.py) | Write `env.sh`, print the peer/wake commands + wake token |
| [`status.py`](scripts/status.py) / [`check.py`](scripts/check.py) | Health check; hermetic smoke gate |
| [`lib.py`](scripts/lib.py) | Shared core: channel schema, pending poll, dedup ledger, backlog seed |

## Out of scope

- Personas or invented backstory.
- Browser automation — this is a native CapTP peer, not a page driver.
- Commits, pushes, or `zig build` gates without the human.
