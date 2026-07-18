# rooms-team — ops: infra, health, status, thread locality

Lead owns bot infra. Members keep their own wake loop alive; the lead detects
dead/busy peers, kicks when needed, and posts status on the right surface.

## Thread locality (human moves threads; agents do not)

Two coordination surfaces exist:

| Surface | What it is | Who may move work here |
| ------- | ---------- | ---------------------- |
| **Room** | pancake chat (this team’s room / DMs) | Human only (to/from harness) |
| **Harness** | Cursor/Claude session outside the room | Human only (to/from room) |

**Rule:** wherever a thread of work is already happening, **keep it there**.

- Work started in the room → status, @-assigns, peer chatter, and outcomes stay
  in the room.
- Work started in the harness (lead’s Cursor turn, a Task UI thread) → stay in
  that harness thread; do not dump the same thread into the room unprompted.
- **Only the human** may relocate a thread (“continue this in the room” /
  “bring that discussion here”). Agents never move a conversation to the other
  surface to “keep everyone in sync.”
- Cross-agent orchestration chatter **must** be in the room (see below) — that
  is not relocating a harness thread; it is the dedicated peer channel.

## Peer chatter (encouraged, room-only)

Agents **should** talk to each other to coordinate (handoffs, blockers, merge
asks, strategy nits). All of that cross-talk goes **in the room** (public or
DM when private). Do not open side channels in the harness between member
subagents for orchestration — the room is the audit trail the human can see.

Harness talk is for human↔lead (or a single agent’s private tool use), not for
member↔member plot.

## Health model

Probe with `rooms-peer status --dir /tmp/rooms-peer-<nick>` or:

```sh
.agents/skills/rooms-team/scripts/team.sh health NICK [NICK...]
```

`team.sh health` prints `class` from a single probe: `idle` | `busy` | `down` |
`missing`. **Stuck** and **zombie** are lead judgments across sweeps (keep a
scratch note: nick → last class + time) — the script does not store history.

| Class | Signals | Lead action |
| ----- | ------- | ----------- |
| **idle** | `peer: up`, `pending: 0` | Healthy |
| **busy** | `peer: up`, `pending > 0`, or member said mid-task | Do not kick yet; wait or soft-ping. If `pending` stays >0 across ≥2 sweeps with no room line, treat as **stuck wake** (not productive busy) |
| **stuck** | `busy` (or silent) across ≥2 sweeps (~2–4 min) with no progress | Soft kick → hard kick |
| **down** / **missing** | peer down / no DIR | Hard kick |
| **zombie** | peer up, subagent gone, and **no** re-arm across ≥2 sweeps | Hard kick; respawn subagent. A single harness-aborted `tick` shell is **not** zombie — members re-arm on abort ([rooms-peer](../rooms-peer/SKILL.md)) |
| **squatter** | `start` fails (DIR/nick conflict) | Fix conflict; never double-start |

**Busy ≠ dead.** Do not restart for slowness alone.

### Room posts (solicited and not)

```sh
# answer a pending line (marks it done)
pancake app rooms-peer reply --dir DIR --id ID --text '…'
# unsolicited room line (no --id) — strategy announce, kick notice, soft ping
pancake app rooms-peer reply --dir DIR --text '@nick still on X?'
```

Both append `outbox.jsonl`; the peer drains them (`outbox.offset` cursor;
`status.outbox_backlog` for stuck sends). Never paste health JSON.

### Soft kick

1. Unsolicited `@nick` ping in the room (reply without `--id`).
2. Wait one health interval.
3. If still silent → hard kick.

### Hard kick

1. Unsolicited announce: kicking `<nick>` (reason).
2. `team.sh stop <nick>` (or rooms-peer `stop`).
3. Respawn that member subagent (same nick/DIR) + fresh background `tick`.
4. Re-state their open assignment in the room (brief).

Only the **lead** hard-kicks, unless the human orders a member to self-restart.

## Health cadence

| When | What |
| ---- | ---- |
| After spawn | One `health` over full roster; fix downs before assigning work |
| During active mission | Lead sweeps ~**every 2–3 minutes** of wall time *or* whenever an @-assign goes unanswered past one tick wait (~120s) |
| Idle harness / quiet room | Sweep ~**every 5–10 minutes**; idle timeouts alone are not failures |
| Before tear-down | Final `health` + `stop` all nicks |

Sweeps are lead-harness work (run `team.sh health`); **results** that affect
the team get a short line in the room only if something changed (down, kick,
reassign). Do not spam the room with green health JSON.

## Status updates — what, cadence, where

### What to say

Short natural language via `reply` (with or without `--id`). Never paste
`tick` / `status` / `health` JSON into the room.

### Cadence (by task depth)

**Quiet room while work happens is a failure mode.** Lead owns a mission
heartbeat in the team room while work is active; members checkpoint on findings
and landings. Depth is the lead’s call (announce when it changes).

| Depth | Shape | Heartbeat |
| ----- | ----- | --------- |
| **Shallow** | one file / quick dig / single assign | every **~2–3 min** or each natural checkpoint |
| **Medium** | multi-file / dual review / fix+gate | every **~3–5 min** |
| **Deep** | architecture, long root-cause, multi-pass | every **~5 min**, plus a line at each major checkpoint |
| **Idle / HITL wait** | waiting on human or parked | no spam — but if the human is in-room and asking for presence (“Bueller”, “status?”, “no updates”), post immediately; do not hide behind idle |

Also post **immediately** on: strategy/roster change, assign created/done,
blocker, kick, reassign. All-green health sweeps stay harness-only. Human asks
“status?” → answer on the **same surface** they asked.

### Where (follow the thread)

| Ask / work lives… | Status goes… |
| ----------------- | ------------ |
| Room (human or peer asked there) | Room |
| Harness (human asked the lead in Cursor) | That harness thread **and** a one-line room heartbeat if the mission is room-visible |
| Peer coordination / orchestration | Room always |
| Human relocates (“post that in the room”) | Follow the human |

Do not mirror private harness tool noise into the room. Do post short progress
when the assignment itself is room-scoped (the usual rooms-team case).

## Infra checklist (lead)

1. `zig build` + `PATH` once per environment.
2. **Team room** minted or human-named (never silent `general`); same `--room`
   for every nick.
3. Roster of nicks ↔ slugs ↔ DIRs (mental or scratch; not required in git).
4. Locator correct for the fabric.
5. `team.sh health` after spawn and on the cadence above.
6. Orphan peers after mission → `team.sh stop` entire roster.
7. Subagent process death with peer still up → hard kick that nick.

## Member duties (ops-relevant)

- Re-arm `tick` every wake — you are your own liveness probe.
- On an assigned dig: keep the **room heartbeat** cadence above; harness progress
  alone is invisible to the human in-room.
- If overloaded: say so **in the room** (`@lead` or lead nick); do not go dark.
- Coordinate with peers **in the room**; do not open harness side chats for that.
- Do not relocate harness threads into the room (or the reverse).
