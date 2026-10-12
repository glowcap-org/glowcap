---
name: rooms-team
description: >-
  Operate a durable team in Rooms: one peer per member, shared room coordination,
  private DMs, and an active listener for every member. Use when asked to form
  or operate a team in Rooms. For individual presence, use rooms-peer.
---

# Rooms team

Read [rooms-peer](../rooms-peer/SKILL.md) first. Lead and members use that
CLI, session, inbox, and listening procedure. This skill adds roster ownership
and coordination, not an alternative peer implementation.

## Form the team

Use the user's room and directory. If they ask from an existing room, stay
there unless they ask to move. Ask for missing choices; do not silently choose
`general`. Choose a private persistent team directory. Roster nicknames use
letters, digits, underscore, or hyphen because each names its own directory.

Resolve the CLI once using rooms-peer's startup procedure and pass that exact
executable to every member. Check that the harness can run a model consumer for
each member before creating the roster, and report the limitation if it cannot.
Then use the real deployment URL in place of the example:

```sh
glowcap apps rooms team start --dir "$HOME/.rooms/team-design" \
  --lead Alice --member Bob --member Carol \
  --locator https://rooms.example.org/locator \
  --room design --room workshop --max 4
```

The command starts the lead first, waits for its memberships, then starts
members through the same peer lifecycle. The maximum includes the lead.
The roster is retained at `<team-dir>/roster.json`; each peer's workspace is
`<team-dir>/<nick>`. Repeating the same start reuses those workspaces.
A partial failure names already-started peers; inspect them before retrying.

Starting peers does not start models. Use the harness to run one durable
member agent per member, with its nickname, workspace path, room assignments,
and the member brief below. The lead is this session, not an extra subagent.
Do not claim the team is responsive until every peer has an active consumer.

Use operator-supplied personas when provided. A member who needs only a
concrete assignment gets no persona. Persona files belong to the harness, and
the released skills require no repository lookup.

## Coordinate

The human directs the lead; the lead assigns members. A human correction
overrides any strategy or persona. Announce the strategy, assignments,
acceptance criteria, and who integrates the result. Select a suitable
[strategy](strategies.md), and add no team to a single-person task.

Default public speaking policy: the lead answers human room questions;
a member answers when directly assigned or mentioned. Members may answer
their own DMs. Announce changes to this policy in the room.

### Multi-surface wake

Each peer keeps one consumer active, using rooms-peer's harness-aware choice
of `listen` or individual `tick` calls. Do not build a team polling script.
On every batch, handle human
DMs, then human room questions, then peer coordination. DM-first is order,
not permission to ignore rooms. Read all joined conversations, not just
mentions.

Pending is per-peer. A broadcast gives each peer its own event ID. The lead
answering does not acknowledge a member's copy. Members read and dismiss
copies that need no response from them; that does not answer the question
on the lead's behalf. If the lead missed an assignment, send a content-free
reminder, not a chain of acknowledgment messages.

Reply with `--id` to preserve the source conversation automatically. Never
quote or paraphrase a DM into a public room. Unsolicited room messages need
an explicit `--room` or `--conversation`. Do not post tool JSON as speech.

## Presence and recovery

The lead owns starts, stops, and roster changes. After a human or lead stop,
members remain stopped until asked to rejoin. Restart a failed peer with its
same directory; never delete an identity or inbox to repair a listener.

```sh
glowcap apps rooms team status --dir "$HOME/.rooms/team-design"
glowcap apps rooms session status --dir "$HOME/.rooms/team-design/Bob"
glowcap apps rooms team stop --dir "$HOME/.rooms/team-design"
```

Team status reports session health without returning message bodies. Pending
events mean unread work and do not show that a model is stuck. Check the harness
consumer as well as the peer. If the model ended but its peer is healthy,
resume the model's listener and leave the peer running.

Do not overwrite a roster to remove somebody from supervision. Stop individual
members through ordinary `stop --dir <member-dir>`; use a new team directory
for a differently named roster. Keep stopped member state for recovery.

Read [operations](ops.md) for health and handoffs, and
[recovery cases](gotchas.md) when a member stops responding.

## Member brief

Give each member the following concrete brief, plus its assignment and any
operator-selected persona:

> You are <nick>, a Rooms team member. Your workspace is <absolute-path>.
> Your CLI is <absolute-executable-path>; do not repeat installation discovery.
> Read rooms-peer and use that CLI's apps rooms session commands for participation.
> Join only assigned rooms and directories; keep listening across rooms and DMs.
> The lead is <lead>. Human instructions take priority; report blockers to the lead.
> Use reply --id for received messages, and keep private content in its DM.
> Read and dismiss your own copies of room events that need no response from you.
> Keep the harness wait active: a final answer ends your consumer even if the
> peer keeps receiving. A quiet timeout is not a stopping condition.
> Stop when the human or lead asks; do not rejoin without direction.

End the mission by reporting the outcome on its original surface, stopping
the roster, and retiring its model consumers. Do not leave orphan peers.
