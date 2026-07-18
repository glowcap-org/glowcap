---
name: rooms-team
description: >-
  Use when operating a multi-persona durable team in a pancake chat room, or
  when asked for rooms-team, room team orchestration, or durable persona bots
  coordinating in-chat. When a human already present in a room asks you to spin
  up, add, or fan out agents or helpers, they mean durable bots in that room —
  reach here, not ephemeral Task subagents the room cannot see. Not for
  single-agent room presence (rooms-peer) or ordinary Task subagents without a
  room team.
---

# Rooms team

Durable multi-persona team in one pancake room. **Lead** = this skill’s runner.
Presence is [rooms-peer](../rooms-peer/SKILL.md) — wrap it, do not fork it.
Other CapTP: [pancake-mcp](../pancake-mcp/SKILL.md) ·
[pancake-cli](../pancake-cli/SKILL.md). Refs: [strategies.md](strategies.md) ·
[gotchas.md](gotchas.md) · [ops.md](ops.md).

## When not to use

- One ask, one agent → [rooms-peer](../rooms-peer/SKILL.md) alone.
- No room / no durable bots → ordinary Task subagents, not this skill.
- Operator forbids a team → obey; do not “upgrade” to rooms-team.

## Human primacy

Human (harness or room) > lead > strategy > persona. On redirect: stop, ack,
replan. No voting against a direct ask. Put this in every member prompt.

## Strategy (announce, then work)

Pick with this tree; full catalog in [strategies.md](strategies.md):

1. Single agent enough? → do not form a team.
2. Independent subtasks? → `concurrent` / `fan_out_fan_in` / `map_reduce`.
3. Fixed sequence? → `pipeline`.
4. Mixed known deps? → `dag`.
5. Specialist emerges mid-flight? → `handoff`.
6. Path unknown? → `adaptive` (+ stall caps).
7. Real tradeoffs? → `debate` / `council`.
8. Clear quality bar? → `critic`.
9. Risky side effects? → `plan_then_execute` + `hitl`.
10. Always-on across missions? → `harness` wrapping the above.

Announce in the room: strategy id, why, speak/merge rules, caps. Switch in the
open when the mission shape changes. Hybrids OK if named.

## Personas

Resolve slugs per [`.agents/personas/README.md`](../../personas/README.md).
Default **lead:** `agentic-lead`. Need ≥2 **member** slugs. Missing slug → stop.
Nick = room-safe `title` or slug; DIR = `/tmp/rooms-peer-<nick>`.

## Team room (required)

The team works in a **dedicated room**, never `general`.

1. **Ask the human** for a room name, or mint one if they say to create it.
2. Mint pattern (room-safe letters/digits/`_`/`-`): `team-<topic>-<yyyymmdd>` or
   `team-<leadnick>-<hhmmss>` when topic is unclear.
3. Pass the **same** `--room <name>` to lead and every member. Joining a new
   name creates the room (rooms-peer enter/open); an existing name joins it.
4. Announce the room name in the harness before spawn. Do not reuse `general`
   or another mission’s room unless the human explicitly says so.

## Run (repo root)

```sh
zig build && export PATH="$PWD/zig-out/bin:$PATH"
```

1. Resolve **team room** (above). Lead: rooms-peer `start --room <team-room>` →
   background `tick` → reply/dismiss → re-arm. `--locator` unless compose
   `rooms-net`.
2. Spawn each member as a **background** subagent with the prompt skeleton
   below (same `--room`, persona body inlined).
3. Orchestrate per strategy; peer chatter in the team room; health per
   [ops.md](ops.md).
4. Tear down: `team.sh stop` on the full roster.

```sh
.agents/skills/rooms-team/scripts/team.sh health NICK [NICK...]
.agents/skills/rooms-team/scripts/team.sh stop NICK [NICK...]
```

**Room speech:** `reply --dir DIR --text '…'` posts (outbox). With `--id`, also
marks that pending item answered. Unsolicited lines omit `--id`. Never paste
tick/status/health JSON.

## Ops

Infra, health, kicks, depth-scaled **room heartbeat**, thread locality:
[ops.md](ops.md). Quiet room during active work is a failure mode.

## Member prompt

```
Durable rooms-team member. Slug [slug]. Nick [nick]. DIR /tmp/rooms-peer-[nick].
Room [team-room] (must match lead; never general). Locator [locator|"compose default"].
HUMAN PRIMACY: human > strategy/persona/peers; on redirect follow immediately.
Follow .agents/skills/rooms-peer/SKILL.md (start --room [team-room], tick, reply/dismiss, re-arm).
Never run rooms-peer peer. Strategy [id]; role [role]. Read rooms-team ops.md + gotchas.md.
On assigned digs: keep ops.md room-heartbeat cadence (short unsolicited reply).
Peer chatter in the team room only; do not relocate harness↔room threads.
Persona:
---
[file body]
---
```

## Pressure cases (must not regress)

| Failure | Correct behavior |
| ------- | ---------------- |
| Description-only shortcut | Read this body + linked files; do not invent a thinner loop |
| Join `general` by habit | Mint or ask for a team room; refuse `general` unless human insists |
| Tick not re-armed | Member goes silent → lead treats as zombie, hard kick |
| Harness aborts waiting tick | Drain if needed + re-arm; not zombie; quiet about abort, still heartbeat if human/dig active |
| Bueller / peer up but no room lines | Wedged pending or abort storms; soft-ping then kick; heartbeat wins over harness silence |
| Quiet room during dig | Depth-scaled heartbeat in ops.md; lead fills gaps |
| Kick on `busy` | Wait/ping; kick only when stuck/down |
| Harness member↔member plot | Move coordination to the team room |
| Agent relocates thread | Refuse; only human moves surfaces |
| Team for a one-liner | Decline; use rooms-peer alone |
| Human in-room says "spin up agents" | They mean durable bots in that room; form the team here, not hidden Task subagents. Confirm the room first |
