# rooms-team — ops: infra, health, status, thread locality

Lead owns bot infra. Members keep their own wake loop alive; the lead detects
dead/busy peers, kicks when needed, **calls in / dismisses seats under the
bot cap**, and posts status on the right surface.

## Roster capacity (call-in / dismiss)

Default **`GLOWCAP_ROOMS_TEAM_MAX_BOTS=4`**, **including the lead** → at most 3 member
Tasks+peers concurrent. Override via env or human ask; announce non-default caps
in the room.

```sh
.agents/skills/rooms-team/scripts/team.sh capacity [member-nick...]
# → {"max":4,"lead":1,"members":N,"used":1+N,"free":…}
```

| Move | Steps |
| ---- | ----- |
| **Call in** | Under cap? If not, dismiss first. Prefer `team.sh spin` for a fresh roster onto a running fabric (lead-first start + prompt blobs). Or: room announce → spawn Task (member prompt) → `start` same room/locator → member foreground-waits `tick` |
| **Dismiss** | Room announce stand-down → interrupt Task (`STOP` / exit; no auto-rejoin) → `team.sh stop <nick>` |
| **Swap** | Dismiss then call in; one seat turns over |
| **Hard kick** | Still available for stuck/zombie (below); a planned dismiss is not a kick |

Lead never dismisses themselves to free a seat. Human may raise the cap instead
of forcing a swap. After a human **stop**, capacity rules do not authorize
members to self-call-in — lead owns rejoin order.

## Thread locality (human moves threads; agents do not)

Two coordination surfaces exist:

| Surface | What it is | Who may move work here |
| ------- | ---------- | ---------------------- |
| **Room** | glowcap chat (this team’s room / DMs) | Human only (to/from harness) |
| **Harness** | Cursor/Claude/Codex session outside the room | Human only (to/from room) |

**Rule:** wherever a thread of work is already happening, **keep it there**.

- Work started in the room → status, @-assigns, peer chatter, and outcomes stay
  in the room.
- Work started in the harness (lead’s Cursor/Claude/Codex turn, a Task UI
  thread) → stay in that harness thread; do not dump the same thread into the
  room unprompted.
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
| **busy** | `peer: up`, `pending > 0` (DM-only or dig), or member said mid-task | Do not kick yet; wait or soft-ping. If `pending` stays >0 across ≥2 sweeps with no room line, treat as **stuck wake** (not productive busy) |
| **stuck_human_room** | `status.human_room_pending: true` — room lines from authors **not** listed in DIR/`roster.json` `nicks` (requires roster; without it the flag stays false). `room_pending` is the honest all-room flag | Soft-ping then clear: lead drains human room; members dismiss lead-owned copies. Do not treat peer chatter as this class |
| **stuck** | `busy` / `stuck_human_room` (or silent) across ≥2 sweeps (~2–4 min) with no progress | Soft kick → hard kick |
| **down** / **missing** | peer down / no DIR | Hard kick |
| **zombie** | peer up, member Task gone (UI shows completed / no owner), and **no** re-arm across ≥2 sweeps | Hard kick optional; **respawn** same nick/DIR with **foreground-wait** `tick` (see [SKILL](SKILL.md) “Why members die”). Usual cause: Task final-answered after background-arming tick. A single harness-aborted wait is **not** zombie — member must wait on `tick` again |
| **squatter** | `start` fails (DIR/nick conflict) | Fix conflict; never double-start |

**Busy ≠ dead.** Do not restart for slowness alone.

### Room posts (solicited and not)

```sh
# answer a pending line (marks it done)
glowcap app rooms-peer reply --dir DIR --id ID --text '…'
# unsolicited room line (no --id) — strategy announce, kick notice, soft ping
glowcap app rooms-peer reply --dir DIR --text '@nick still on X?'
```

Both append `outbox.jsonl`; the peer drains them (`outbox.offset` cursor;
`status.outbox_backlog` for stuck sends). Never paste health JSON.

### Soft kick

1. Unsolicited `@nick` ping in the room (reply without `--id`).
2. Wait one health interval.
3. If still silent → hard kick.

### Hard kick

1. Unsolicited announce: kicking `<nick>` (reason).
2. `team.sh stop <nick>` (or rooms-peer `stop`) when the peer itself must die.
3. Respawn that member **Task** (same nick/DIR) with **foreground-wait** `tick`
   — for Task-exit zombies, often skip stop: peer is already up; only the Task
   is gone.
4. Re-state their open assignment in the room (brief).

Only the **lead** hard-kicks, unless the human orders a member to self-restart.
Lead is this session, not a Task — do not spawn a third “lead” subagent.

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
| Harness (human asked the lead in Cursor/Claude/Codex) | That harness thread **and** a one-line room heartbeat if the mission is room-visible |
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

## Multi-surface drain (lead + members)

Same CapTP pending list holds DMs and room lines. Drain order every wake —
see [SKILL](SKILL.md) Multi-surface wake:

1. Human DM → 2. Human room → 3. Peer chatter.

**Lead-specific:** the lead is the operator session, not a forever-Task. Arm
[`scripts/lead-watch.sh`](scripts/lead-watch.sh) (or equivalent) so `tick --json`
returns emit `AGENT_LOOP_WAKE_lead_pending` and the harness notifies this
session — a plain/`--plain` pager that `json.load`s stdout **never wakes**.
Each wake must still clear **human room** ids, not only DMs. A lead that
answers DMs and leaves human room pending reproduces “CapTP delivered / room
silent.” Health `busy` with `pending > 0` across ≥2 sweeps and no room line →
treat as **stuck wake** (table above), not productive dig.

**Human-room SLA:** a human `channel=room` id must not sit unanswered past **one
tick wait (~120s)** on the owning peer. If lead owns the reply and has not
cleared it by then → soft-ping `@lead` in-room (content-free); after a second
miss → hard-kick / respawn lead wake per zombie path. Members do not “finish”
the id by dismiss+handoff.

**@-assign exception:** if the human `@member`s a nick on a room line, that
member may answer that line without waiting for lead (speak policy assigned
them). Un-@’d human room stays lead-owned.

**Member-specific:** no bash/`tick.sh` canned replies. For lead-owned human
room lines: optional content-free `@lead human-room` if lead may have missed,
then **dismiss your copy** (pending is per-peer — see [SKILL](SKILL.md) Human
room ownership). Never `dismiss --all` while human lines remain. Handoff does
not finish the lead’s job — lead must answer on the lead DIR.

Pending human lines beat harness digs. Re-arm tick immediately after the drain.

### Announce speak policy (team start)

At spawn / strategy announce, post one room line naming: who answers human
room, who may DM humans, and the @member exception. Silence defaults to
lead-owns-human-room.

## Member duties (ops-relevant)

- **Foreground-wait** on `tick` every wake — you are your own liveness probe.
  Do not background-arm then final-answer (that completes the Task).
- **Do not outrank the lead on presence.** After stop: stay down until lead
  assigns rejoin. Lead enters first.
- Drain human DM then human room then peers every wake ([SKILL](SKILL.md));
  never auto-dismiss human room or script-ack DMs.
- On an assigned dig: keep the **room heartbeat** cadence above; harness progress
  alone is invisible to the human in-room — but pending human lines still beat
  the dig.
- If overloaded: say so **in the room** (`@lead` or lead nick); do not go dark.
- Coordinate with peers **in the room**; do not open harness side chats for that.
- Do not relocate harness threads into the room (or the reverse).
