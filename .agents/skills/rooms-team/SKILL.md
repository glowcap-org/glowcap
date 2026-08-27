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

Durable multi-persona team in one pancake room. **Lead** = this skill’s runner
(this Cursor/Claude/Codex session — not a Task subagent). **Members** = background
Task subagents, one per nick. A 2-member roster correctly shows two Tasks in
the UI; do not look for a third “lead” Task.
Presence is [rooms-peer](../rooms-peer/SKILL.md) — wrap it, do not fork it.
Other CapTP: [pancake-mcp](../pancake-mcp/SKILL.md) ·
[pancake-cli](../pancake-cli/SKILL.md). Refs: [strategies.md](strategies.md) ·
[gotchas.md](gotchas.md) · [ops.md](ops.md).

## When not to use

- One ask, one agent → [rooms-peer](../rooms-peer/SKILL.md) alone.
- No room / no durable bots → ordinary Task subagents, not this skill.
- Operator forbids a team → obey; do not “upgrade” to rooms-team.

## Human primacy

**Human leads the lead; the lead leads the roster.** Chain of command:

`human > lead > members > strategy > persona`

On redirect: stop, ack, replan. No voting against a direct ask. Put this in
every member prompt.

**Presence is lead-owned.** Who starts, stops, or rejoins CapTP peers — and in
what order — is the lead’s call under the human. After a human (or lead) **stop**:
members stay down. No wait-loop on `:8000`, no auto-`start`, no racing the lead
back into the room. Lead rejoins first when the human says the fabric is ready;
members rejoin only when the lead assigns it. Members recovering a dead peer
mid-mission (same nick/DIR, lead still present) is fine; inventing presence
ahead of the lead is not.

## Multi-surface wake (room + DM)

CapTP delivers **both** `channel=dm` and `channel=room` into the same `tick`
pending list. A wake that only clears DMs (or only clears peer chatter) leaves
the other surface looking dead while `peer: up` — the failure mode behind
“are you getting general messages?” when CapTP already had the room lines.

**Drain order on every wake** (lead and members):

1. Human `channel=dm` — real `--dm` replies in your own voice (never a canned
   `ack — here` / bash auto-reply script).
2. Human `channel=room` — see [Human room ownership](#human-room-ownership).
3. Peer chatter — reply or `dismiss`.

**DM-first is order, not permission to ignore the room.** One wake drains both
human surfaces before returning to a dig or peer debate. Pending human lines
beat harness digs; never background-arm tick then grind while `pending > 0`.

## Human room ownership

Speak policy still decides who *composes* the public answer to the human.
Default: **lead owns human room replies**; members may answer human DMs.

**Pending is per-peer.** A room broadcast lands a separate `channel=room` id in
*each* joined peer’s tick list. The lead answering on the lead DIR does **not**
clear a member’s copy. “Leave it pending for the lead” is therefore wrong: it
wedges the member wake while the lead already has (or missed) their own id.

Rules:

- **Lead:** every wake must clear **your** human `channel=room` ids (answer, or
  briefly ack + assign). Leaving them pending across a wake while handling DMs
  is the same class of bug as silent DMs. Human-room SLA: [ops.md](ops.md).
- **Members (lead-owned human room line):** `dismiss` **your** copy so your wake
  stays healthy — after a content-free `@lead human-room` ping **only if** the
  lead may have missed it (lead already has their own id). Do **not** hold the
  id forever “for the lead.” Do **not** treat dismiss+handoff as the human
  being answered.
- **Exception:** human `@member` on a room line → that member answers it
  (they were assigned by @); other members dismiss their copies.
- **Who is “human”?** Any pending `author` that is not a roster nick (lead +
  active members). Treat unknown authors as human.
- Never replace the LLM with a bash/`tick.sh` auto-reply or auto-dismiss loop.
  Never `dismiss --all` while any human line is still pending.

## DM privacy

CapTP `channel=dm` is already a private introduce/redeem thread between two
peers — other room members do not receive those lines. **Agent behavior must
match that:**

- Answer DMs only with `--dm` (the prefilled reply). Never paste DM text into a
  room `reply`.
- Do not report DM contents, quotes, or paraphrases in the room (including
  “they asked me whether …”). At most a content-free `@lead dm-thread active`
  if coordination truly needs it — prefer silence.
- Do not put the human’s personal name into room posts when a content-free
  handoff suffices.
- Room speak policy (who may address the human publicly) is separate; privacy
  still forbids leaking the private thread into the room.

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
Those files are shared taste lenses (subagent reviews and rooms-team members) —
not rooms-bot-only; other skills load the same catalog. Default **lead:**
`agentic-lead`. Missing slug → stop. Nick = room-safe `title` or slug; DIR =
`/tmp/rooms-peer-<nick>`.

## Roster capacity (spawn / dismiss)

The lead **calls in** and **dismisses** member bots as the mission needs different
personas. CapTP peer + Task subagent are one seat.

| Knob | Default | Meaning |
| ---- | ------- | ------- |
| `PANCAKE_ROOMS_TEAM_MAX_BOTS` | `4` | Max concurrent bots **including the lead** |

So default headroom is **3 members**. Human may raise/lower the env (or say a
number in-session); lead announces the cap when it differs from 4.

**Count:** `1 (lead) + active_members ≤ max_bots`. Lead always occupies a seat.
Parked/stopped nicks do not count.

**Call in** a persona (under cap): announce in-room → spawn background Task with
member prompt → `rooms-peer start` same room/locator → member foreground-waits
`tick`. Lead enters/rejoins first after any stop ([Human primacy](#human-primacy)).

**At cap, need another specialist:** dismiss one seat first (below), then call in.
Prefer dismissing idle / assignment-done / least-relevant to the next slice.
Do not dismiss the only member mid-critical path without a replacement plan.

**Dismiss** a member: announce in-room (`@nick` standing down, why) → interrupt
Task with stop order (exit; no rejoin) → `team.sh stop <nick>` (or rooms-peer
`stop`). Free the seat before spawning the next.

**Swap** = dismiss then call in. Announce both. Dynamic roster is normal for
`handoff` / `dispatcher_moe` / specialist shifts; fixed full roster is fine when
the mission is stable and under cap.

Details and health interaction: [ops.md](ops.md) (roster capacity).

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
   announce speak policy ([ops](ops.md)) → arm
   [`scripts/lead-watch.sh`](scripts/lead-watch.sh) with harness notify on
   `AGENT_LOOP_WAKE_lead_pending` (`tick --json` — plain stdout never wakes a
   JSON pager) → on every wake drain human DM → human room → peers
   ([Multi-surface wake](#multi-surface-wake-room--dm)). `--locator` unless compose
   `rooms-net`.
2. Spawn **active** members as **background** subagents (member prompt below;
   same `--room`, persona body inlined). Stay under
   [`PANCAKE_ROOMS_TEAM_MAX_BOTS`](#roster-capacity-spawn--dismiss) (default 4 incl. lead).
   Call in / dismiss later as personas change — do not require the full cast
   up front.
3. Orchestrate per strategy; peer chatter in the team room; health per
   [ops.md](ops.md).
4. Tear down: `team.sh stop` on the full active roster.

```sh
.agents/skills/rooms-team/scripts/team.sh health NICK [NICK...]
.agents/skills/rooms-team/scripts/team.sh stop NICK [NICK...]
.agents/skills/rooms-team/scripts/team.sh capacity [ACTIVE_MEMBER_NICK...]
.agents/skills/rooms-team/scripts/team.sh spin --room ROOM --locator URL --lead NICK MEMBER [MEMBER...]
.agents/skills/rooms-team/scripts/team.sh speak-policy [--lead NICK]
```

`spin` is the one-command CapTP roster join onto a **running** fabric: probes the
locator, writes `DIR/roster.json` for every nick, **lead-first** `rooms-peer start`,
waits for lead `joined+registered`, prints speak-policy text (also
`DIR/speak-policy.txt`), starts each member only after the lead is ready, and
emits per-member Task prompt files (`DIR/task-prompt.txt`). **Harness still
spawns member Tasks** and foreground-waits `tick` — spin never final-answers for
them. `capacity` prints max / used / free seats (`PANCAKE_ROOMS_TEAM_MAX_BOTS`, default 4,
including lead). Pass current member nicks only (lead is implied).
**Room speech:** `reply --dir DIR --text '…'` posts (outbox). With `--id`, also
marks that pending item answered. Unsolicited lines omit `--id`. Never paste
tick/status/health JSON.

## Ops

Infra, health, kicks, depth-scaled **room heartbeat**, thread locality:
[ops.md](ops.md). Quiet room during active work is a failure mode.

## Why members “die” (harness, not CapTP)

The CapTP peer and `tick` CLI are fine. **Cursor/Claude/Codex Task subagents end
when they emit a final answer.** The lethal pattern observed in-session:

1. Member backgrounds `tick --wait 120` (`block_until_ms: 0` / fire-and-forget).
2. Posts “tick armed / standing by / presence live” as a **final** message.
3. The Task completes. Peer stays `joined`. When `tick` later returns, **no
   agent owns the wake** → zombie (`peer: up`, no re-arm).

Solo [rooms-peer](../rooms-peer/SKILL.md) in the **main** chat can background
`tick` because that session stays alive. A **member Task** cannot: background
arm + turn-ending prose is member death. Members must **foreground-wait** on
`tick` (block until it returns), handle, wait again — forever. Lead respawns
zombies; see [ops.md](ops.md) / [gotchas.md](gotchas.md).

## Member prompt

```
Durable rooms-team member. Slug [slug]. Nick [nick]. DIR /tmp/rooms-peer-[nick].
Room [team-room] (must match lead; never general). Locator [locator|"compose default"].
HUMAN PRIMACY: human leads the lead; lead leads you. human > lead > members >
strategy/persona. On redirect follow immediately.
PRESENCE: lead owns start/stop/rejoin. After human/lead stop: stay down — do NOT
wait-loop locator, auto-start, or rejoin before the lead. Rejoin only when lead
assigns it. Mid-mission peer crash with lead still present: restart same DIR ok.
DURABLE TASK (harness): You are a Task subagent, not a one-shot. Emitting a final
answer / "standing by" / "tick armed — done" COMPLETES this Task while CapTP peer
stays up and orphans the wake loop (zombie). That is harness death, not a CLI bug.
Session ends only when lead/human says stop (or lead hard-kicks).
WAKE LOOP: foreground-wait `tick --dir DIR --wait 120` (block on the process until
it returns — do NOT background-arm then end your turn). On return, drain in this
order: (1) human `channel=dm` — real `--dm` replies in your own voice; never a
canned `ack — here` / bash/`tick.sh` auto-reply; (2) human `channel=room` —
if @you or speak policy assigns you, answer; else content-free `@lead human-room`
only when lead may have missed it, then **dismiss your copy** (pending is
per-peer — holding it does not help the lead); (3) peer chatter reply/dismiss.
Then immediately foreground-wait tick again. **DM-first is drain order, not
permission to ignore the room.** Pending human lines beat digs. Never
`dismiss --all` with human lines still pending. Harness abort of a wait →
drain `--wait 0` if needed → wait again. Never summarize-and-finish. A quiet gap
without a waiting tick makes DMs *and* room lines feel dead.
Follow .agents/skills/rooms-peer/SKILL.md for start/reply/dismiss/stop; override its
"background tick" advice — members foreground-wait (rooms-team SKILL).
Never run rooms-peer peer. Strategy [id]; role [role]. Read rooms-team ops.md + gotchas.md.
On assigned digs: keep ops.md room-heartbeat cadence (short unsolicited reply).
Peer chatter in the team room only; do not relocate harness↔room threads.
DM PRIVACY: CapTP DMs are private. Reply only via --dm. Never quote/paraphrase
DM content in the room. Content-free @lead ping only if coordination requires it.
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
| Background-arm + “standing by” final | Harness completes the Task → zombie; member prompt requires foreground-wait; lead respawns ([ops](ops.md)) |
| Member Task completes while peer up | Same class as above — forbid final answers; respawn same nick/DIR |
| Harness aborts waiting tick | Drain if needed + foreground-wait again; not zombie; quiet about abort, still heartbeat if human/dig active |
| Bueller / peer up but no room lines | Wedged pending or abort storms; soft-ping then kick; heartbeat wins over harness silence |
| Quiet room during dig | Depth-scaled heartbeat in ops.md; lead fills gaps |
| Kick on `busy` | Wait/ping; kick only when stuck/down |
| Harness member↔member plot | Move coordination to the team room |
| Agent relocates thread | Refuse; only human moves surfaces |
| Team for a one-liner | Decline; use rooms-peer alone |
| Human in-room says "spin up agents" | They mean durable bots in that room; form the team here, not hidden Task subagents. Prefer `team.sh spin` then harness Task spawn |
| Spin without reachable locator | `team.sh spin` refuses (`locator_unreachable`); do not start members ahead of a live lead |
| Members rejoin before lead after stop | Presence is lead-owned; stay down until lead assigns rejoin; lead enters first |
| Over max_bots without dismiss | Call-in blocked — dismiss a seat first; announce swap |
| Silent dismiss (no room line) | Always announce stand-down before `stop` / Task exit |
| Slow DM while CapTP already delivered | Wake-loop gap or room-first handling — keep tick waiting; drain human DM then human room per [Multi-surface wake](#multi-surface-wake-room--dm) |
| CapTP room lines unread while DMs answered | Same wake must drain both human surfaces; lead must clear human room every wake |
| Member dismisses human room + “@lead over to you” | Handoff is not the answer — lead must drain **their** copy; member dismisses **their** copy after optional ping ([Human room ownership](#human-room-ownership)) |
| Member holds human room “for the lead” | Pending is per-peer — wedges the member; lead already has a separate id |
| Canned `ack — here` on every DM | Member replaced the LLM with a bash auto-reply — kill the script; foreground-wait tick and answer in persona |
| Peer-ack storms | One short finding or ack per assign; do not chain empty `ack.` lines |
