---
type: static
description: How to run a Rooms bot, a member whose replies come from Claude Code, Codex, or Pi, what it may do, keep it running, and look after it.
audience: human
sources:
  - resource: /apps/rooms/rust/product/src/bin/rooms-bot/
  - resource: /cli/app/rooms/bot_commands.zig
  - resource: /cli/app/rooms/session_commands.zig
---

# Running a Rooms bot

A Rooms bot is a member of Rooms whose replies come from a coding agent running on your machine.

## What you need

- A Rooms session for the bot, with its own nickname. The bot attaches to that session and speaks as its member.
- One of the three agents installed and signed in on the machine that runs the bot: `claude` (Claude Code), `codex` (Codex), or `pi` (Pi). The bot starts the agent as you and finds it on the `PATH` of the `serve` process. `serve` refuses an agent it cannot find there and names the program it looked for.
- The `glowcap` program. A package install needs nothing more. From a checkout, pass `--glowcap <path>` with the path of an existing executable file.

## First run

The commands below start the bot's session, issue it an access with the right to post, and serve the bot with that access. The session directory is private to the bot's session, and the bot directory is where `serve` keeps the bot's settings and state. Replace the nickname, the directory locator, and the room with your own.

```sh
glowcap apps rooms session start \
  --dir "$HOME/.rooms/helper" --nick helper \
  --locator https://rooms.example/locator --room workshop

glowcap apps rooms session access issue \
  --dir "$HOME/.rooms/helper" --label bot --rights collaborator \
  | glowcap apps rooms bot serve \
      --dir "$HOME/.rooms/helper-bot" --harness claude --link -
```

For a Rooms server on your own machine, run it as [Operating Rooms](../../apps/rooms/operating.md#the-session-service) describes and use its `/locator` URL as the locator. The session flags there, such as `--transport tcp` and `--dial-transports tcp`, are the same ones `session start` takes here. Plain TCP carries the link unencrypted, so the bot uses it only to reach a session on this machine's loopback address and refuses a `tcp` link to any other host.

The access link is a secret, because whoever holds it holds the access. `issue` prints it once as a line of JSON, and `--link -` reads that line from standard input, so the link never appears on a command line. A file works too: `--link <path>` names a file that holds the link or the JSON line. `serve` refuses a link given as the value itself and asks you to revoke it.

`serve` checks the agent, its permission, and the `glowcap` path first, and stores the settings and the link only once the session has answered. A first run whose link the session refuses or has revoked exits with the cause and the next step. It stores neither the settings nor the link, and leaves the bot directory with its `lock` file, which marks the directory as served.

Run `serve` again with a corrected link. The access `issue` made still exists, so revoke it with `session access list` and `revoke` when you give up on it.

`serve` stays in the foreground and prints `ROOMS-BOT-SERVING claude` once the session has answered it. It starts at the newest activity, so lines written before the bot existed are never answered. Stop it with Ctrl-C. The next `serve` for the same directory needs only `--dir`, because the settings and the link are stored.

## Talking to it

Send the bot a direct message to its nickname and it answers every line you send. In a room, mention it with `@helper` in a line and it answers that line. A room-wide mention such as `@room` or `@here` does not wake it.

A direct message that is exactly `/reset`, or in a room a line that is `/reset` and your mention of the bot, as in `@helper /reset`, starts a new conversation with the agent, which forgets what was said there before. The bot answers it with one line that says so. A direct message that also names someone, such as `@bob /reset`, is an ordinary line for the agent.

The bot reads the lines around a mention too. It keeps the last <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/context.rs MAX_LINES -->40<!-- /value --> lines of each conversation that did not address it, so a mention arrives with what was said just before. It answers one line at a time per conversation and shows as typing there while its agent works. Mentions that arrive while it works are answered together in its next reply. At most <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/engine.rs MAX_TURNS -->2<!-- /value --> conversations are answered at once.

The agent remembers each conversation. It works in its own directory for that conversation, and files sent to the bot are saved there for it.

## The bot's home

The bot's home is the `home` directory inside the bot directory, the one place the agent keeps across every conversation and restart. `serve` creates it, and the agent saves there what will help it later: notes, scripts, procedures it worked out, and its memories.

A memory is one small file in `home/memory/` whose first line is a one-line summary. For every reply, the agent is shown a list of its memories, newest first, by file name and summary, so it knows what it saved and opens a file when its summary matters. The list names at most <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/home.rs MAX_LISTED -->64<!-- /value --> memories and <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/home.rs MAX_LISTING_BYTES -->8,192<!-- /value --> bytes of names and summaries, and says how many more there are. A summary is cut after <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/home.rs MAX_SUMMARY_BYTES -->200<!-- /value --> bytes. A file that is not text, and any symbolic link, is listed by name only, and a `home` or `home/memory/` that is itself a link lists nothing. Files whose names cannot be shown are counted, and the agent is told to list the directory to see them.

The agent is asked to save what would help it next time, and to rewrite a memory that turns out to be wrong, or delete it when it can. A `safe` Claude agent can rewrite a memory but not delete one.

Every conversation shares the same memories, rooms and direct messages alike. So the agent is asked to save only what is fine to repeat anywhere: nothing from a direct message that its sender would not want said in a room, and no secrets. That is an instruction the agent follows, not a rule the bot enforces, so look through the home now and then.

The home belongs to you as much as to the agent. Read it, edit it, back it up, or move it to another bot directory while no `serve` runs. The bot writes nothing in it after creating it.

| What happens | What becomes of the home |
| --- | --- |
| `/reset` | Kept. Only the agent's conversation starts over. |
| The bot lets a conversation go to stay within its conversation bound | Kept. Only that conversation's own state goes. |
| `serve` restarts, or takes a new link with `--replace-link` | Kept. |
| You remove the bot directory | Removed with it. Keep a copy of `home` first. |

## What the bot may do

The bot has exactly the rights of its access. In a turn, which is one run of the agent for one reply, it posts and acts as a person holding the same access would, and nothing more. It answers everyone who can reach it, in the rooms it joined and in direct conversations, and it has no per-person limit.

Rights limit what the bot does. Where you place it decides who can reach it, so to limit who it answers, place it only in the rooms and the directory you want.

| Rights | What the bot can do |
| --- | --- |
| `observer` | Read only. It cannot post, so it cannot answer. |
| `collaborator` | Also post, join, and act, including sending files. This is the right for a bot. |
| `administrator` | Everything a collaborator can, and manage the workspace. |

One limit guards against cost rather than rights. `--conversation-limit` caps the messages in one conversation the bot answers in any window of <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/gate.rs WINDOW seconds -->3600 seconds<!-- /value -->, <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/config.rs DEFAULT_CONVERSATION_LIMIT -->60<!-- /value --> unless set and at most <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/config.rs MAX_LIMIT -->100,000<!-- /value -->. A message past it gets no reply, starts no turn, and writes one line in the bot's log. It is kept as context for the bot's next reply there. The count lives in memory, so a restart starts it over.

Two agents that answer each other in one conversation are held to this same limit. To stop such an exchange sooner, lower `--conversation-limit` or remove one of them from the room.

## What it can do in Rooms

Each reply is the agent's final message. During a turn the agent can also use these commands, all as the bot's member:

| Command | What the agent can do with it |
| --- | --- |
| `say` | Post a line in the turn's conversation, in another with `--conversation <id>`, or with `--dm <nickname>` privately to a member. |
| `send` | Send files from its working directory, up to <!-- value ../../apps/rooms/rust/application/src/room/line.rs MAX_MESSAGE_FILES -->8<!-- /value --> at a time, to the same places as `say`. It waits for the room to hold the files and prints how they ended, as the paragraph below says. |
| `workspace` | List the conversations the bot can post to, the people in them, and its own nickname. |
| `command` | Run any other session command the access's rights allow, such as editing or withdrawing a line, or closing a direct message. |
| `actions` | List what this turn's `say`, `send`, and `command` calls did and how each ended, from the bot's own record. It takes no place and does not call the session. |

These commands act for the turn that runs them: the bot tells them its directory and the turn's conversation, so they take no `--dir`, and they work only while the turn runs. One turn may run `say`, `send`, and `command` at most <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/actions.rs MAX_ACTIONS_PER_TURN -->12<!-- /value --> times in all, and past that they are refused with a message naming the bound, while a look at an earlier `command` with `--operation` and `--base` does not count. The bot keeps that count in its own directory, outside the agent's working directory and home, so a `safe` Claude agent's file tools cannot reach it. A `full` agent can change it, as [Choosing the agent and its permission](#choosing-the-agent-and-its-permission) says. The bot's log records each line posted to another conversation and each new `command` before it is sent and again with its outcome. When the line before cannot be written, the verb refuses and sends nothing.

Every verb runs on one budget, counted from its own start: reading `--text -`, dialing the session, a `--dm` open, sending, waiting for the room, and keeping the line all draw from it. The budget is the smaller of <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/act.rs VERB_BUDGET_MS milliseconds -->100 seconds<!-- /value --> and what is left of the turn's deadline less <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/act.rs SEND_RESERVE_MS milliseconds -->30 seconds<!-- /value -->, so the agent reads the answer and still finishes its reply. Every step but the last look stops <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/act.rs SETTLE_TAIL_MS milliseconds -->10 seconds<!-- /value --> before the budget ends. A verb that finds no room for that tail refuses before it takes a place or sends anything. Once a verb has taken its place, a refusal or an attach that runs out of budget still spends that place, as every refusal after it does.

The budget is below <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/act.rs CLAUDE_BASH_DEFAULT_MS milliseconds -->120 seconds<!-- /value -->, the default timeout the bot sets for a foreground command in Claude Code. The harnesses differ in what happens to a verb that outlasts its own limit:

| Harness | A command that runs long |
| --- | --- |
| Claude Code | The harness ends the command at its tool timeout, and the verb prints nothing. If you set `BASH_MAX_TIMEOUT_MS`, allow at least the bot's default timeout. |
| Codex | The call returns early with a session id while the command keeps running, and the agent reads the result later with `write_stdin`. Only a legacy one-shot mode, when managed requirements disable unified exec, ends the command. |
| Pi | The bot sets no command timeout and Pi has none. |

Each of the three harnesses runs the agent's tool commands in a session of its own (Claude Code and Codex measured, Pi read from its source and not run). Ending a turn, which ends the harness's own group, therefore ends no command the agent started. A verb ends by its own budget, at most <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/act.rs VERB_BUDGET_MS milliseconds -->100 seconds<!-- /value -->, and any other command the agent started ends by nothing the bot does.

A verb the harness ended at its tool timeout, or one that crashed, printed nothing and may have acted. The agent runs `actions`, which lists this turn's `say`, `send`, and `command` calls and how each stands, from the bot's own record and with no call to the session, so it answers when the session does not.

Each entry's `outcome` is one of the words in the table below, with a sentence that says whether to repeat the action. An action refused before it was sent, and one that committed nothing, has no entry, so `actions` lists only actions that reached or may have reached the session. A verb that ran out of its budget hands its action to the serving bot, which settles it from the session's list while the turn runs, and the list then shows how it ended.

A claim names the verb process that wrote it. When that process is gone and the turn still runs, the serving bot settles the action from the session's list, and the list shows `unknown` when the session never saw it. A verb whose process the bot cannot judge keeps its claim, and `status.last_error` says why. The session reports no finer phase of a post than pending until the post and its files settle, so a verb says only what it knows: the line may or may not be posted.

The verbs and `actions` use these words, each for one fact:

| Word | Where it appears | What it says |
| --- | --- | --- |
| `committed` | a verb's `status` | The session applied the request. |
| `pending` | a verb's `status` | The session answered that it still runs the request. A call that got no answer prints no `status`. |
| `unknown` | a verb's `status`, an `outcome` in a verb's output when it gave the receipt back, and an `outcome` in `actions` | The session cannot say whether the request committed. |
| `conflict`, `unsent` | the `class` of a refused verb | The session applied nothing. |
| `settling` | an `outcome` in `actions`, and `"settling": "bot"` in a verb's output, also when a look found the action committed and the bot holds its receipt | The bot does not know yet how the action ended, or holds its receipt, and is settling it from the session's list. |
| `posted` | an `outcome` in `actions` | The action committed. |
| `nothing` | an `outcome` in `actions` | The session's list showed the action committed nothing. A verb that is refused or finds a conflict prints that as its own answer and leaves no entry. |

When `send` prints, the line is posted and `files` says how the files stand: `"complete"`, or `"incomplete"` with a `reason`, the room's own words, when the room stopped taking them, and the line stays. If the budget ends first, the verb prints no `status`, `"files": "unfinished"`, and `"settling": "bot"`. The session had not reported the post, so the line may or may not be posted. The files stop when the verb exits, because the bot's verb is what lends them, and the agent should not send them again. A restarted bot keeps a posted line.

`--dm` reaches only members of the turn's directory, and only those that the session lets the bot reach, looked up by nickname as Rooms compares nicknames. The session decides which direct conversation with that member the post goes to: the open one, or else it reopens the last closed one or opens a new one. `workspace` lists every directory the workspace holds, and `command` can open a direct message in any of them, as a person holding the same access can. Run `workspace` in a turn to see who it can reach.

The session refuses a nickname nobody holds in the directory now and the bot's own, and the bot shows a refusal before anything is sent. The log names the member and the direct message before each post `--dm` makes.

### Receipts and direct-message opens

A *receipt* is the session's record of one request this access sent, such as a reply line or a `--dm` open. While the session holds a receipt, the request is not repeated, and only the access that sent it can keep it or give it back. The session holds at most <!-- value ../../apps/rooms/rust/application/src/content/session/custody.rs MAX_EFFECTS -->8<!-- /value --> receipts for all its accesses, so the bot keeps or gives back each one it is done with. A line's *echo* is the line coming back in the session's activity, which is how the bot learns that it posted. The bot's own record of a reply line, open, or agent's action is in `turns.json`, `opens/`, or `turn-actions/`.

The session and the bot treat receipts this way:

- A request the session is still running keeps its receipt. The bot asks again later. Each run of a request settles, pauses, or stops within <!-- value ../../apps/rooms/rust/application/src/content/session/effects.rs RUNNING_BOUND_MS milliseconds -->120 seconds<!-- /value -->, archive shares and bridges included. The one longer run is a room upload filling its files after its post, which settles when its fill ends, and no path of the bot gives such a receipt back while it runs. Only the access that sent a paused request can run it again, and the bot never does. So the bot treats a receipt still running after that as one the session will not take back.
- A request whose result the session stopped waiting for is *stalled*. The bot gives its receipt back, and the session ends the stalled request, so its place is free again. The session still answers for that request until newer receipts push it out, and the bot never sends it again. A stalled reply line counts in `status.unconfirmed` when activity cannot show that it posted.
- A receipt the session will not take back stays with the session until the access that sent it is revoked. Revoking that access makes the session give back every receipt of it that no longer runs. A reply line's receipt counts in `status.unreleased_lines` when a look finds it committed, still running, or unknown, because a paused request reads unknown and holds its place. An open's counts in `status.unsettled_opens`, and an agent's action's in `status.unsettled_actions`.
- A line or open is *replaced* when another link sent it. Only the access behind that link holds its receipt, so the serving access settles it by its echo alone, as [Replacing the link](#replacing-the-link) says.

A `--dm` open keeps its receipt until the open settles. A turn that ends with an open unsettled leaves it to the bot, which asks the session again while serving and across restarts. When the session cannot say whether the open committed, or refuses it, the bot marks the note `.giving`, gives the receipt back, and drops the note once the session takes it. A `.giving` note is never sent again, and it counts toward the limit until it drops.

An open the session would not take back, or one whose access the session no longer holds, stays `.unsettled` and counts toward the limit until the bot serves under a new link, as [Replacing the link](#replacing-the-link) says. The new link marks it `.replaced`, and revoking the old access then frees its place. The bot keeps at most <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/opens.rs MAX_OPENS -->4<!-- /value --> opens at once and refuses a `--dm` past that. A direct message opened through `command` is an agent's action instead, so the claim bound below holds it and not this one. The session's own bound on receipts holds both.

Each `say`, `send`, and `command` the agent runs writes a claim in `turn-actions/` before it is sent, and a claim that cannot be written sends nothing. A claim names the operation, the turn, what the action was (the verb, the conversation or command it named, and a file count), and, once known, how it ended. It holds no line text, file, or link. A rerun of a turn whose run did not answer is told, from these claims, what each earlier action did and whether to repeat it.

While its turn's agent runs, only that turn's verbs settle the action, so a `command --operation --base` check from a later turn only reads.

The one keeper is the verb while its process runs and the serving loop once it does not, and never both: a process that is gone never runs again, so the loop's settling cannot meet a live verb. The bot tells a gone process from a running one by its number and its start time, which a later process cannot share, and only a definite answer that the process is gone counts. A claim whose process is in another process-number namespace, or whose process cannot be read, stays with its verb and is shown in `status.last_error`. The bot and its verbs share a namespace unless the harness runs tools elsewhere, and then every claim stays held and none is cut.

Once the agent stops, the serving loop settles what its actions and notes left, even while the turn's reply is still going out, so an action never holds back the reply that follows it. An action that settles before its verb returns records how it ended in its claim, and one still running makes the verb print `"settling": "bot"`. A turn's claims go when the turn is no longer running. The bot holds at most <!-- value ../../apps/rooms/rust/application/src/content/session/custody.rs MAX_EFFECTS -->8<!-- /value --> claims at once, as many as the session keeps receipts, and refuses an action past that.

`command` refuses, before sending it, a command whose result carries a capability the bot does not keep, such as `ensureRoomLink`. It prints a failure with class `unkeepable` and no operation. A command that committed but whose result the bot did not keep prints `"status": "committed"`, `"kept": false`, and a `reason`, and `receipt` says whether the bot gave its receipt back (`released`) or the session still holds it (`held`).

The bot gives the receipt back only for a result it can never keep, such as a conversation that is gone or authority that changed.

When keeping fails for a reason that clears with time, such as a lost connection or a failed read, the bot holds the receipt (`held`). The line keeps its edit and withdraw authority, and `"settling": "bot"` marks it for the serving loop to keep once it can. A reply line waits for its keep before the next turn in that conversation. A lost connection or repeated workspace changes can keep it waiting.

An action whose own answer was lost and that a look then found committed prints `"looked": true`, with `base` when the answer was uncertain. When the bot could not keep what the look found, it also prints `"kept": false` and the `receipt` state, as for a `command` result it did not keep.

The session lists receipts held by the access. The bot recognizes the action IDs it minted using the identity saved in its directory. Every client must choose a fresh ID for each new request. If someone reuses one of the bot's IDs after the session forgets the original receipt, the ID alone cannot tell who sent the later request. Give each independent bot or person its own access with `session access issue`, as in [First run](#first-run).

The bot checks its receipts at each start, when a turn's agent stops, and on its backoff while an action is still running. Otherwise it checks every <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/opens.rs SWEEP seconds -->60 seconds<!-- /value -->. It keeps what an action returned when it commits and gives the receipt back when the session cannot say. A request that reaches the session after its verb dies is found the same way.

Keep `peer.json` with the rest of the bot directory when moving or restoring it. On upgrade, the bot saves the older action IDs named in its local claims, direct-message open notes, and reply records in `legacy-action-ids.json`. An older receipt with no surviving ownership record stays with the access. Its holder can settle it, and an operator can revoke the access when it is no longer needed.

## Choosing the agent and its permission

`--harness` picks the agent and `--permission` picks what it may do. The default permission is `safe`.

- `safe` keeps the agent to its own working directory, its home, and the bot's own actions.
- `full` lets the agent do anything you can do on this machine. That includes reading the bot's link and your sessions' files, so the rights you issued no longer limit a full agent that runs as you. The operating system user is the boundary. Run a full bot in a container, as the [deployment guide](../../apps/rooms/web/deploy/README.md#run-a-bot) does, or as a separate user. A command a full agent starts, in a session of its own as every harness's tool commands are, can outlive the bot.

The bot refuses a combination it cannot enforce before it serves, so no agent runs with less confinement than you asked for.

| Agent | `safe` | `full` |
| --- | --- | --- |
| `claude` | Allowed. The agent may read, write, and edit files under its working directory and its home, and run only the bot's own commands. It gets no other tool. | Allowed. Every permission check is skipped. |
| `codex` | Refused. Codex's sandbox limits where it writes but not what it reads, so it could read the bot's session link. | Allowed. It needs a Codex sign-in the bot can find through `HOME` or `CODEX_HOME`. |
| `pi` | Refused. Pi has no sandbox or approval mode. | Allowed. |

So a first run with `--harness codex` or `--harness pi` also needs `--permission full`. Claude Code runs with its safe mode on, which drops your hooks, MCP servers, plugins, and instruction files and keeps your sign-in. It reads settings only from your user settings, and a safe run may not write a `.claude` directory in its working directory, so the agent cannot change what a later run allows. A safe Claude bot also refuses a `glowcap` path or a bot directory that holds any of `()*?[]{}\!#`, because a permission rule reads those as pattern syntax and would reach past the path.

For a `safe` Claude agent, the bot's flags set these limits, and Claude Code refuses without asking whatever they do not allow:

- The agent has four tools: reading, writing, and editing files, and a shell.
- The file tools work only under its working directory and its home.
- The shell runs only a command that starts with the bot's `glowcap` and one of the bot's own commands.

The shell limit matches only how a command starts, so what else the command may carry is up to Claude Code. The Claude Code version this project tests with, `CLAUDE_CODE_VERSION` in [`.devcontainer/pins.sh`](../../.devcontainer/pins.sh), denied a bot command with an environment prefix, a redirection, or a command substitution, and a read outside the working directory and home. That is how that version behaved, and another version may differ.

`--model` selects the provider and model in the agent's own syntax, and the agent's own default is used when it is left out. `--deadline` sets how many seconds one reply may take, from 1 up to <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/config.rs MAX_DEADLINE_SECS seconds -->86400 seconds<!-- /value -->, and the default is <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/config.rs DEFAULT_DEADLINE_SECS -->600<!-- /value -->.

`--instructions <file>` adds your own instructions to the bot's, such as a language to answer in or a topic to stay on. The bot reads the file for every reply, so an edit applies to the next one. The file holds UTF-8 text of at most <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/config.rs MAX_INSTRUCTIONS_BYTES -->16,384<!-- /value --> bytes. If it cannot be read when a reply starts, the bot answers with a line that says so. `--no-instructions` drops the stored file.

## Settings as variables

Every `serve` setting except `--replace-link` and `--no-instructions` is stored in the bot directory, so later runs keep it until you pass a new value. Each of those is also read from a variable named `GLOWCAP_ROOMS_BOT_` and the flag's name in capitals with dashes as underscores. `--conversation-limit` is `GLOWCAP_ROOMS_BOT_CONVERSATION_LIMIT`. A flag wins over its variable. `GLOWCAP_ROOMS_BOT_LINK` names the file or `-` that holds the link, never the link itself.

A variable never raises a bot stored as `safe` to `full`. `serve` refuses `GLOWCAP_ROOMS_BOT_PERMISSION=full` for such a bot and asks for `--permission full` on the command line.

## Keeping it running

A Rooms deployment under Docker Compose keeps a bot running as one of its services. [Run a bot](../../apps/rooms/web/deploy/README.md#run-a-bot) shows how. Any other supervisor, such as a systemd unit, can run `glowcap apps rooms bot serve --dir <bot directory>` once a first `serve` has stored the settings and the link.

## Looking after it

`bot status` reports whether a `serve` is running and what it last did:

```sh
glowcap apps rooms bot status --dir "$HOME/.rooms/helper-bot"
```

The cursor, the turn counts, and the counts kept in `turns.json` show only what that file holds. When a write of it may not have landed, they keep their last written values until a write lands.

| Field | Meaning |
| --- | --- |
| `ok` | `true` for every report. A failed `status` prints the failure shape below. |
| `configured` | Whether the bot directory holds the link and settings a first `serve` stores. |
| `running` | Whether a `serve` holds the directory now, including a first start still reaching its session. |
| `status` | What `serve` last wrote, or `null` when no `serve` has written it. |
| `status.pid` | The process id of the `serve` that wrote it. |
| `status.harness` | The agent it serves with: `claude`, `codex`, or `pi`. |
| `status.cursor` | The bot's position in the session's activity, as `turns.json` holds it. |
| `status.access` | `active`, `paused`, or `revoked`, as the session reported the bot's access, where `revoked` also covers an access the session dropped or no longer scopes to the bot, and `unknown` until the session first answers. No turn starts unless it is `active`. |
| `status.queued` | Lines read but not yet given a turn, because <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/ledger.rs MAX_OPEN -->16<!-- /value --> turns are already open. The bot reads them again after a restart. |
| `status.open_turns` | Turns not finished, whether waiting, running, or sending. |
| `status.sending` | Turns whose reply is written and waiting for the session to take it. |
| `status.turns_finished` | Turns finished since the bot was first served. |
| `status.gaps` | Times the session reported events the bot missed. |
| `status.unavailable` | Times the session could not show some events. |
| `status.unreadable` | Events skipped since this `serve` started because the session could not decode them. |
| `status.unconfirmed` | Reply lines given up on since this `serve` started, because the session could no longer say whether they posted. |
| `status.unsettled_opens` | How many `--dm` opens this access sent that the session has not settled, each held in `opens/` as a `.unsettled` note or, while the bot gives its receipt back, a `.giving` note. Each counts toward this access's `--dm` limit. A `.giving` note drops by itself once the session takes the receipt. To clear the rest, give the bot a new link and then revoke this access, as [Replacing the link](#replacing-the-link) says. |
| `status.unsettled_actions` | How many of the agent's actions the session lists as held by this access that the bot gave up on and the session would not take back. Each holds one of the session's places. The bot tries each again at its next start, and an action leaves the count once the session stops listing it. To clear them, give the bot a new link and then revoke this access, as [Replacing the link](#replacing-the-link) says. |
| `status.replaced_opens` | How many `--dm` opens another access sent, held in `opens/` as `.replaced` notes. The bot never looks at them, and they do not count toward this access's `--dm` limit. [Replacing the link](#replacing-the-link) says how they drop. |
| `status.replaced_actions` | How many of the agent's actions the old access still held when the bot moved to a new link, recorded in `turns.json`. They do not count toward the claims this access holds. Each can hold one of the session's places until the old access is revoked. [Replacing the link](#replacing-the-link) says how they drop. |
| `status.replaced_unlisted` | `paused` or `denied` when the old access of the last replacement was paused or no longer held by the session, so the bot could not list the agent's actions it held, and `null` otherwise. Those actions are not in `replaced_actions`, and each can hold one of the session's places until that access is revoked. The bot cannot see that revocation, so the field stays until the next replacement. |
| `status.replaced_lines` | How many reply lines the serving access finished by their echo while another access held their receipts. `turns.json` keeps one record for each. [Replacing the link](#replacing-the-link) says how they drop. |
| `status.unreleased_lines` | How many reply lines have receipts the session would not take back and still lists as held by this access, unknown ones included. `turns.json` records each one, so the count survives a restart, and a record drops once the session stops listing it. To free them, give the bot a new link and then revoke this access, as [Replacing the link](#replacing-the-link) says, because a revoked access serves nothing. |
| `status.last_error` | The last failure of reading the session, running a turn, sending a line, or saving the bot's own state, and which of these it was in `during`: `receiving`, `thinking`, `sending`, or `saving`. It stays until that activity next succeeds. A failure to settle a `--dm` open or an agent's action, or to list the receipts the access holds, shows here as `sending` when the session failed and `saving` when the bot's own files did, and it clears when a later list answers. A line the session is slow to take shows here, and so does a line given up on, until a later line posts. An agent's action whose line the bot could not keep yet, because its workspace was moving or the session did not answer, shows here as `sending` with the action's operation and the cause, and clears when the bot keeps the line. |
| `status.unanswered` | The last turn the agent could not answer, with its next step, in fixed words that never quote the agent. `bot.log` holds what the agent printed. The `kind` is `sign-in`, `usage-limit`, `declined`, `outage`, `crash`, or `null`. It clears when a later turn is answered or the bot restarts. |
| `home.path` | The bot's home. |
| `home.memories` | How many memories `home/memory/` holds now. |

`bot ready --dir <bot directory>` exits 0 only while a `serve` holds the directory, has written its status, reports `status.access` as `active`, and has neither a `status.last_error` from reading the session (`during` is `receiving`) nor a `status.unanswered` of kind `sign-in`. Otherwise it prints why and exits nonzero, so a container health check can use it. After a sign-in refusal, sign the agent in again as the user that runs `serve`, then send the bot a message or restart it: the agent starts fresh each turn, and the next answered turn clears the failure. A health check can run at any time, including while `serve` is starting, and it never stops a `serve` from starting or mistakes another check for one. A `serve` still starting reports its own `pid` and a `status.access` of `unknown`, or `paused` when that access is paused, so `ready` fails until it serves.

After a session restart, `bot ready` can pass while the session is still rejoining a room. Wait until the bot’s session nickname appears in that room’s member list before sending it a mention. If the session is still acquiring its seat when the bot tries to post a reply, the session answers `room-joining` before sending anything. The bot keeps the reply and retries.

Codex reports a failure only as text, so the bot knows a Codex sign-in refusal by the HTTP status 401 or 403 that the text names. A refusal worded without that status counts as a crash, so `ready` still exits 0 while every turn fails. For a Codex bot, a `status.unanswered` of kind `crash` that comes back turn after turn can mean a lost sign-in.

The session holds at most <!-- value ../../apps/rooms/rust/application/src/content/session/custody.rs MAX_EFFECTS -->8<!-- /value --> receipts for all its accesses. When every one of them still holds a place, the session refuses a reply before sending it. The bot keeps the line and tries again: `status.sending` counts the turn, and `status.last_error` shows the `receipts-full` refusal with `during` set to `sending`.

Waiting alone does not clear it when another access holds the places. A place the bot's own actions or opens hold frees without help, because the serving loop settles them once the turn's agent stops. A place frees when the access that sent one of those requests finishes it or gives it back, or when that access is revoked, as [Receipts and direct-message opens](#receipts-and-direct-message-opens) says. The agent sees a `--dm` open the full session refused with class `receipts-full`, and nothing was sent. `bot ready` does not look at sending, so it stays ready while a reply waits.

The log is `bot.log` in the bot directory. Each line starts with its UTC time. A turn logs when it starts and when it finishes, with its conversation, duration, and outcome, and the log never holds message text. An access state such as `paused` or `revoked` is logged once when it changes. What the agent prints to its error output is logged with control characters escaped, and each logged line is cut at <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/store.rs MAX_LOG_LINE_BYTES -->4,096<!-- /value --> bytes. The log rotates to `bot.log.1` after <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/store.rs LOG_LIMIT bytes -->1 MiB<!-- /value -->.

You manage the access from the bot's session directory:

```sh
glowcap apps rooms session access list --dir "$HOME/.rooms/helper"
glowcap apps rooms session access pause --dir "$HOME/.rooms/helper" --id <id>
glowcap apps rooms session access resume --dir "$HOME/.rooms/helper" --id <id>
glowcap apps rooms session access revoke --dir "$HOME/.rooms/helper" --id <id>
glowcap apps rooms session access forget --dir "$HOME/.rooms/helper" --id <id>
glowcap apps rooms session access share-management --dir "$HOME/.rooms/helper" --id <id>
```

`list` shows each access with its id, rights, and whether it is active, paused, or revoked. A paused access stops working until you resume it, and a revoked one is over for good. `forget` drops a revoked access from the list and refuses one that still works. A failed command prints `{"ok":false,"error":{"class":...,"retry":...,"message":...}}`, the same shape the `bot` commands print.

`share-management` prints a management link for one access as `{"ok":true,"id":...,"link":...}`. In a browser attached to the session, open **Session access**, press **Add…** beside **A management link someone gave you**, and paste the link. That browser can then pause, resume, and revoke the access, and cannot change its rights. Anyone who holds the link can do the same until the access is revoked, so treat it as a secret. Running the command again prints the same link.

### Replacing the link

To give the bot a new link, stop the bot, issue a new access, and run `serve` with the link and `--replace-link`:

```sh
glowcap apps rooms session access issue \
  --dir "$HOME/.rooms/helper" --label bot --rights collaborator \
  | glowcap apps rooms bot serve \
      --dir "$HOME/.rooms/helper-bot" --link - --replace-link
```

Without the flag, `serve` refuses a link other than the stored one, because the bot's saved position belongs to the session the old link reached. With it, a link to a different session is still refused, and you use a new `--dir` to serve that one. A link to the same session is taken in this order:

1. `serve` waits up to <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/serve/replace.rs REPLACE_LIMIT seconds -->60 seconds<!-- /value --> in all for the replies going out under the old link to settle, and the old access decides whether each posted. A bot stopped during that wait keeps the old link.
2. The session says which access sent each reply and `--dm` open still unsettled. The old access settles the ones it sent and gives back the receipt of an open the bot had given up on, and one it cannot settle stays as it is. If the old access already stopped working, the log says `the old access stopped working` with the session's reason, and the new link asks the session again about what is left.
3. The old access lists the agent's actions it holds, even past the time limit, and settles each one it can. `turns.json` records the rest. Only the old access can make that list, so a list that fails makes `serve` exit without storing the new link or the list's record, and what the old access settled before stays settled. Run the same replacement again, or revoke the old access first. A revoked old access holds nothing, and a paused one or one the session no longer holds cannot list, so the bot goes on and `status.replaced_unlisted` says `paused` or `denied`.
4. The bot stores the new link once the session has answered it. A stop before that leaves the old link stored, and running the same replacement again finishes it. A stop after it leaves the new link stored.

The bot does not revoke the old access, and that access holds its receipts until it is revoked. Revoke it once the bot serves under the new link. At each start, the bot asks the session which access holds the receipt of each replaced line, open, and action. A record drops when the session answers that none does, because newer receipts pushed it out, or that the serving access does, because the link is back to the access that sent it. A receipt the session gave back still answers for its access until newer receipts push it out, so on a quiet session `replaced_opens`, `replaced_actions`, and `replaced_lines` can stay through many starts. None of them affects `bot ready`.

The bot looks for a replaced reply line by its echo, never sends it again, and records it in `turns.json`, which `status` counts as `replaced_lines`. A replaced `--dm` open is marked `.replaced` in `opens/`, which `status` counts as `replaced_opens`, and an action the old access could not settle is recorded in `turns.json`, which `status` counts as `replaced_actions`. Revoking the old access frees the places those actions hold. A link back to the access that sent them, whether the same access in another form or an earlier link that was never revoked, keeps what that access sent.

A link the session refuses or revokes makes `serve` exit with a failure that says so, and the old link stays stored. Run `serve` again without `--replace-link` to keep using it while its access still works. If the old access was revoked too, the error gives the command that issues a new one.

A first start finds no link to replace, so it refuses a bot directory whose `opens/` holds notes, with the same way out as a missing `config.json`: restore the file, or start fresh. Claims in `turn-actions/` never stop a start: the serving loop settles each claim whose verb's process is gone from the session's list and records how it ended, and a verb that survived the restart keeps its claim until it ends.

## When something goes wrong

Every line the bot answers ends with a reply, either the agent's answer or one line that says why there is none. It gets no reply when the bot gives up on a reply line, below, or when the session refuses the line that says why. No reply line posts twice.

| What happens | What the bot does |
| --- | --- |
| The agent crashes or ends without an answer | An agent that exits without an answer counts as crashed within <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/runner.rs EXIT_GRACE seconds -->5 seconds<!-- /value -->, even when a process it started still holds its output open, and `bot.log` names its exit status. The bot starts the agent again with what is left of the deadline, resuming its saved conversation, and a start counts as a try. After <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/ledger.rs MAX_RUNS -->2<!-- /value --> tries it posts `I could not answer that: the agent stopped unexpectedly, after <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/ledger.rs MAX_RUNS -->2<!-- /value --> tries.` The line never carries the agent's own words, which go to `bot.log` alone. |
| The agent takes longer than the deadline | The deadline covers every start of the agent for one reply, and a pause of the bot's access, which ends the agent, gives the run after the resume a whole deadline. When it passes, the bot ends the agent and the processes in its group, and posts a line saying the agent did not finish in that many seconds. It does not start the agent again. The commands the agent started run in sessions of their own, so a verb ends by its own budget and any other command by nothing the bot does. |
| The agent's sign-in is refused, it hit a usage limit, or it declined the request | It posts one line naming that reason and does not retry. The line never quotes the agent, and a sign-in refusal's words reach no log either. For a sign-in refusal, sign the agent in again as the user that runs `serve`, then restart the bot or send it a message, because `ready` fails until then. |
| The agent's service is unavailable | It starts the agent again as for a crash, and after <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/ledger.rs MAX_RUNS -->2<!-- /value --> tries posts a line that says the service was unavailable. `status.unanswered` has the kind `outage`. |
| The bot itself stops or is killed during a turn | The next `serve` finishes the turn. A run the bot's own stop ended, by `SIGTERM` or a shutdown, is not a try, and a run a kill or crash ended is. With a try left, the agent runs again with a full deadline, so its side effects can repeat, and otherwise the bot posts the failure line. A reply already written is posted, never twice. |
| The answer is long | A line holds at most <!-- value ../../apps/rooms/rust/application/src/room/line.rs MAX_LINE_BYTES -->8,192<!-- /value --> bytes. A longer answer is posted as several lines, split at paragraph breaks, and cut after <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/reply.rs MAX_PARTS -->8<!-- /value --> lines with a notice. |
| The bot's access is paused | It ends any agent still working, holds every reply, and keeps trying the session up to <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/engine/backoff.rs SLOW_CEILING seconds -->300 seconds<!-- /value --> apart, and `status.access` shows the state. Once the access works again, each cut-off reply runs from the start and each held line goes out. A first start whose access is paused waits the same way, and one whose link the session refuses exits instead. |
| The bot's access is revoked | It ends any agent still working on a reply, then exits with a failure that names `serve --link - --replace-link`. A revoked access never works again, so issue a new one and run that command. Each turn that was working is stopped, not finished, and runs again under the new link, so its agent runs again. |
| The session is unreachable | The bot reconnects on its own with a wait that grows to <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/engine/backoff.rs STANDARD_CEILING seconds -->60 seconds<!-- /value -->. A reply that was started goes out under the same operation. |
| The bot cannot tell whether a reply line posted | This happens when the bot is killed while a line goes out, and when the session cannot say. The bot asks the session, then looks for the line in the session's activity. It sends the line again only when a complete read of the same session run shows it missing. Otherwise it moves on, and the message that started the turn may get no reply. The log line `cannot say whether operation`, `status.unconfirmed`, and `status.last_error` show it. |
| A `--dm` open is still unsettled when its turn ends | [Receipts and direct-message opens](#receipts-and-direct-message-opens) says what the bot does about it. |
| The session refuses to say which access sent a line or open the bot left behind | `serve` exits with a failure that says so and names the next step: update the session to the version the bot was built with, then start the bot again. A session that is only slow or unreachable is asked again. |
| A reply is written but the session has not taken it | The bot retries the write and does not run the agent again. |
| A state file in the bot directory is unreadable | `serve` refuses and says so. To start fresh, follow the error. The bot then answers only lines sent after it starts. |
| The session cannot decode an event | The bot skips it, counts it in `status.unreadable`, and reads on. |
| The session restarts | The bot reads the new run's activity from its start and counts a gap. |

## Limits

- Lines posted while the session was restarting are not answered. They appear in `status.gaps`.
- A line sent while the bot was stopped is answered after the next start. A line sent before the bot's first start is not.
- The bot answers new lines only. It does not answer an edit of a line, and it never answers its own lines.
- A file sent to the bot is fetched from the sender's machine when its turn starts, because the sender holds the file and the session keeps no copy. Fetching may use half of what is left of the reply's deadline, and the agent is told of a file not saved by then as skipped. A sender that has disconnected leaves the file unsaved, and the agent is told it could not be fetched.
- One reply answers at most <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/ledger.rs MAX_TRIGGERS -->8<!-- /value --> waiting lines of a conversation. The rest wait for the next reply.
- One bot directory serves one session and one `serve` at a time. A second `serve` for the same directory is refused.
- The bot keeps recent lines, a working directory, and the agent's saved conversation for at most <!-- value ../../apps/rooms/rust/application/src/content/session/workspace.rs MAX_CONVERSATIONS -->256<!-- /value --> conversations. Past that, it removes all of them for the conversation it heard from longest ago, and that conversation starts fresh the next time it addresses the bot.
- The session keeps its last <!-- value ../../apps/rooms/rust/runtime/src/session/managed/activity.rs MAX_EVENTS -->4,096<!-- /value --> activity events. When a line's fate is unknown and its event has already left that window, the bot cannot find it, so it moves on without sending the line again. A session restart has the same effect.
