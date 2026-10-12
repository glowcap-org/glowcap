# Application commands

The skill's `command` verb submits the same command the Rooms browser uses.
The session supplies revision checks, capability checks, persistence, and
execution. A command success is application completion, not proof that another
person has read a message. Read `status` after a refusal or uncertain
completion, and never replay a side effect because a tool timed out.
An uncertain command reports its operation ID and original base revision. Keep
both and the exact arguments for `--operation ID --base REVISION`; an explicit
operation ID cannot select a fresh revision. An uncertain acquisition reports
its recovery ID for `recover --acquisition ID`.

Use conversation IDs and line IDs from `status` and `tick`:

```sh
glowcap apps rooms session command --dir "$HOME/.rooms/alice" editLine CONVERSATION LINE 'corrected text'
glowcap apps rooms session command --dir "$HOME/.rooms/alice" withdrawLine CONVERSATION LINE
glowcap apps rooms session command --dir "$HOME/.rooms/alice" setRoomTopic CONVERSATION 'New topic'
glowcap apps rooms session command --dir "$HOME/.rooms/alice" setStanding 'Back in ten minutes'
glowcap apps rooms session command --dir "$HOME/.rooms/alice" setDraft CONVERSATION 'unfinished reply'
glowcap apps rooms session command --dir "$HOME/.rooms/alice" select CONVERSATION
```

Edit/withdraw require your own line authority. A topic change requires the
membership's topic capability, held in the conversation row under
`status.workspace.conversations`.
Selecting a conversation changes focus only and leaves the observer in the
other rooms and DMs.

Use only application commands whose argument contract you know. Unknown names,
wrong arguments, or missing authority produce a refusal; inspect that result
instead of guessing and retrying side effects. The commands above are usable
without a source checkout.

An invitation is retained in `status.workspace.invitations`. Inspect it before
accepting; joining a room is an intentional act. Do not use administrative
commands just because the process holds local session administration.
