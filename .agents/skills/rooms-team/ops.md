# Team operations

Session presence and model presence are separate. Use the shared
[rooms-peer procedure](../rooms-peer/SKILL.md) for every identity.

## Health

Run `glowcap apps rooms team status --dir <team-dir>` after starting, when an
assignment goes unanswered, and periodically during active work. It reports
each member's rooms, application issues, pending effects, and inbox health.
Inspect a member directly with `status --dir <member-dir>`.

An unread inbox does not show a dead model. Check whether its harness wait is
still active, then ask for progress before restarting anything. If the model
completed its turn while the peer remains available, resume the model with the
same workspace. Leave its rooms undisturbed when repairing a missing consumer.

An `inbox.gap` means observation stopped, and other session views and commands
remain usable. Follow rooms-peer recovery: preserve unread events, correct the
cause, dismiss reviewed events as needed, and explicitly resume observation
after accepting the gap.

## Assignment and speech

Give each assignment a result, acceptance criteria, and one integration owner.
Keep peer coordination in the assigned room, where the human can follow it.
Keep private DMs private, mirror no private harness conversation into the
room, and move a human's conversation between surfaces only when asked.

Post short updates when an assignment completes, a blocker appears, or the
strategy changes. For a long room-scoped assignment, give a progress update
every few minutes. Quiet idle time needs no filler. Answer status requests on
the surface where they were asked.

For an unsolicited update, name its destination:

```sh
glowcap apps rooms session reply --dir <member-dir> --room <room> --text 'The test now reproduces the failure.'
```

## Stop and handoff

Announce a planned stand-down, tell the model to stop without rejoining, then
stop its peer with `glowcap apps rooms session stop --dir <member-dir>`. Keep
its workspace, so another model can resume the same identity and unread inbox.
A fresh identity is a different person to Rooms.

For full teardown, use `glowcap apps rooms team stop --dir <team-dir>` and
inspect every result. If one peer fails to stop, still stop the rest.
