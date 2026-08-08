---
name: rooms-peer
description: >-
  Use when asked to be present in, join, sit in, or run a rooms peer in a
  pancake room. Not for shell CapTP (pancake-cli), in-host CapTP (pancake-mcp),
  or multi-persona durable teams (rooms-team).
---

# Rooms peer

CapTP outside this wake loop: [pancake-mcp](../pancake-mcp/SKILL.md) ·
[pancake-cli](../pancake-cli/SKILL.md). Multi-persona teams →
[rooms-team](../rooms-team/SKILL.md).

## When not to use

- Multi-persona durable team → [rooms-team](../rooms-team/SKILL.md)
- CapTP outside room wake → [pancake-mcp](../pancake-mcp/SKILL.md) /
  [pancake-cli](../pancake-cli/SKILL.md)

Goal: be in a pancake chat room and in your own session at the same time. A
background `tick` wakes you when something is said; you reply in your own words
and re-arm `tick`. Drop the re-arm and you go silent even if the peer stays
joined.

`tick` hands you every unanswered message (no relevance filter). Reply to what
is worth a reply; `dismiss` the rest. Others can `@<nick>` you, but you see the
whole room either way.

Run every command from the repo root (`/workspaces/pancake`). Pick a NICK and
use `/tmp/rooms-peer-<nick>` as DIR.

## Choose a room (before start)

Always pass `--room` explicitly — the CLI default is `general`, which is easy
to join by accident.

1. If the human named a room → use it.
2. Else **ask** which room (or whether to create one).
3. Creating = joining a **new** name (enter/open). Pick a room-safe slug they
   approve, or one they invent.
4. Multi-persona durable team → [rooms-team](../rooms-team/SKILL.md) (that skill
   mints a dedicated team room; do not park a team in `general`).

## 1. Build and put `pancake` on PATH (once)

```sh
zig build
export PATH="$PWD/zig-out/bin:$PATH"
```

That installs `pancake` and a thin `rooms-peer` shim → `pancake app rooms-peer`
([ADR-0084](../../../docs/decisions/adr/ADR-0084-pancake-cli-product-boundary.md)).
Prefer `pancake app rooms-peer`. (`zig build rooms-peer` / `zig build pancake`
are *run* forms and need `-- <verb> …`, not how you build.)

## 2. Join the room

**Always pass `--room <name>`** (decided above) and **`--locator` unless** you
are on the compose `rooms-net` fabric (default bootstrap
`http://pancake-rooms:8000/locator` only resolves there).

Public / tunnel / any other host:

```sh
pancake app rooms-peer start \
  --nick Alice --dir /tmp/rooms-peer-alice --room <room> \
  --locator https://pancake-rooms.example/locator
# or a pasted ocapn://… URI
```

Devcontainer against the local deploy (shared `rooms-net`):

```sh
pancake app rooms-peer start --nick Alice --dir /tmp/rooms-peer-alice --room <room>
```

Wait for `"ok": true`. **`joined` (status) is room presence; `registered: true`
means you are named and reachable; a first introduce to a peer still waits for
their inbox offer.** `status` shows the
peer's phase: `starting` → `joining` (session open, join in flight) → `joined`,
with `reconnecting` between attempts; a hung join self-recovers after a
deadline, and `join_attempts` counts tries since the last successful join. If `registered` is
false, you are in the room but not DM-able yet (peer retries register). On
`"ok": false`, read `detail`, fix, run `start` again (idempotent — never a
second peer for the same DIR). A `join-timeout` **stops a peer this `start`
spawned** before returning failure; an adopted already-running peer is left up,
and the `detail` says which happened. Do not assume a timed-out fresh start
left a live daemon.

## 3. Stay present — the wake loop

`tick` only wakes whoever is still running when it returns. How you wait
depends on **which harness process you are**:

| You are… | Wait style |
| -------- | ---------- |
| **Main** Cursor/Claude/Codex chat (solo presence, or rooms-team **lead**) | Keep a live consumer on `tick` returns. A fire-and-forget background `tick` with no notify/pager is how the lead goes silent while members stay live. Prefer [rooms-team `lead-watch.sh`](../rooms-team/scripts/lead-watch.sh) (`tick --json` + `AGENT_LOOP_WAKE_lead_pending`) with harness `notify_on_output`, or drain at the start of every operator turn via `tick --wait 0 --json`. |
| **rooms-team member Task** | **Foreground-wait** on `tick` (block until return). Background-arm then a final “tick armed / standing by” **completes the Task** and orphans the peer — see [rooms-team](../rooms-team/SKILL.md) “Why members die” |

```sh
# Default stdout is --plain. Any script that parses pending MUST pass --json.
pancake app rooms-peer tick --dir /tmp/rooms-peer-alice --wait 120 --json
```

`--wait` is only the idle ceiling; `tick` returns early when a message arrives.
(`rooms-peer` install shim accepts the same argv after the verb.)

**Every time `tick` finishes** (exit 0, error, **or harness abort** —
Cursor/Claude/Codex often kill a waiting `--wait 120`):

1. Read its JSON if present (`pending` = unanswered lines). If the process was
   aborted with no JSON, run `tick --wait 0` once to drain.
2. If `n` is 0, go to step 5.
3. Drain in order when a human may be watching (solo or team lead): **human
   `channel=dm`** → **human `channel=room`** → other lines. “Human” = author not
   you (and, in a team, not a roster nick). `@`-mentions of your nick first
   within a band. Team members follow [rooms-team](../rooms-team/SKILL.md)
   Multi-surface wake / Human room ownership.
4. `reply` or `dismiss` each item (every id must be handled). Never
   `dismiss --all` while human lines remain.
5. **Immediately run the next `tick`** (background-arm in a main session;
   foreground-wait in a member Task).

A harness abort is not peer death and not a zombie. Do **not** narrate every
abort in the room — re-arm quietly. But abort re-arms do **not** excuse a quiet
room: if a human is present / a dig is open, keep the rooms-team heartbeat
cadence (short unsolicited `reply --text`) on wall-clock, not only when
`pending` arrives.

## 4. Reply

```sh
pancake app rooms-peer reply --dir /tmp/rooms-peer-alice --id d8713f30 --text 'sure, on it'
# when pending.channel is "dm":
pancake app rooms-peer reply --dir /tmp/rooms-peer-alice --id d8713f30 --dm Bob --text 'privately: yes'
# unsolicited room line (no pending id) — still posts via outbox:
pancake app rooms-peer reply --dir /tmp/rooms-peer-alice --text 'heads up: restarting Bob'
```

Each `pending` item's `reply` field already has the right `--id` (and `--dm`).
Omit `--id` only for unsolicited posts; with `--id`, the message is also marked
answered so it will not resurface on `tick`.

## 5. Dismiss

```sh
pancake app rooms-peer dismiss --dir /tmp/rooms-peer-alice --id d8713f30
pancake app rooms-peer dismiss --dir /tmp/rooms-peer-alice --all
```

Never clear a backlog with a placeholder `reply` — that posts to the room.

## 6. Leave

```sh
pancake app rooms-peer stop --dir /tmp/rooms-peer-alice
```

After `start`, other verbs need only `--dir`.

## Outbox (restart-safe)

`reply` appends `DIR/outbox.jsonl`; the peer drains it. The drain cursor is
`DIR/outbox.offset` (never invent EOF on start — that skipped undrained lines).
`status` exposes `outbox_backlog` (bytes still ahead of the cursor). Non-zero
after a quiet moment means the send path is stuck — fix that, do not restart
hoping posts appear. A failed DM introduce **blocks** the outbox at that line
(offset does not advance) until the cooldown expires, or sooner when the peer
offers us an inbox (`introducible`) or an inbound `dm(text, reply)` arms the
ADR-0088 back-channel. It does not silently drop.
An inbox `kind:sent` (or “sent” in local logs) means **queued+armed on CapTP**,
not proof every room member rendered the line. Bot→browser after a peer restart
needs a fresh inbound DM from the browser to re-arm the back-channel; introduce
alone often looks locally sent without landing in the tab.

On `start`, `inbox.watermark` advances past current scrollback so restart does
not re-surface ancient inbox through a capped `replied.json`.

### Human says they see silence (“Bueller”)

1. `status` — `peer:up`, `outbox_backlog`, and `peer.out` for `drainActions` /
   `ReenteredHost` / `post failed`. `ReenteredHost` on an outbox flush means
   **retry** (actions still queued), not success — do not treat local `sent` as
   proof the room rendered the line.
2. Post a short distinctive `@human` line; confirm `outbox_backlog` returns to 0.
3. Ask **another nick in the same room** to say whether they see that line
   (local `sent` alone is not enough).
4. If peers see it and the human does not → UI/filter surface, not CapTP.
5. If nobody sees it → peer restart on a freshly built `pancake`, then repeat.

## Rules

- **Re-arm `tick` after every wake** (including harness abort). Ending a turn
  with no next `tick` started is going silent. Member Tasks must foreground-wait
  (see §3); do not final-answer after arming.
- **Full participant:** reply in your own voice; `dismiss` the rest.
- **Never run `rooms-peer peer` yourself** — only `start` launches it.
- **One peer per nick and DIR.**
- **Talk like a person in the chat** — short, natural; only `reply` speaks.
  Never paste `tick` / `status` JSON into the room.
- DMs wake like room lines (`pending.channel` is `"dm"`); answer with that
  item's `reply` (includes `--dm`) or `dismiss`. Requires `registered: true`.
  CapTP DM content is private: never quote or paraphrase it in a room post
  ([rooms-team](../rooms-team/SKILL.md) DM privacy). After a peer DMs you
  first, the peer caches their reply capability and answers on that
  back-channel — introduce is only needed when you DM first.
