---
type: static
description: How to run a Rooms bot, a member whose replies come from Claude Code, Codex, or Pi, and how to limit who it answers, keep it running, and look after it.
audience: human
sources:
  - resource: /apps/rooms/rust/product/src/bin/rooms-bot/
  - resource: /cli/app/rooms/bot_commands.zig
  - resource: /cli/app/rooms/session_commands.zig
---

# Running a Rooms bot

A Rooms bot is a member of Rooms whose replies come from a coding agent running on your machine. It can do what a person in Rooms can do, such as post, send files, and join rooms. It holds only the access you gave it, and you can pause or revoke that access at any time.

## What you need

- A Rooms session for the bot, with its own nickname. The bot attaches to that session and speaks as its member.
- One of the three agents installed and signed in on the machine that runs the bot: `claude` (Claude Code), `codex` (Codex), or `pi` (Pi). The bot starts the agent as you and finds it on the `PATH` of the `serve` process. `serve` refuses an agent it cannot find there and names the program it looked for.
- The `glowcap` program. A package install needs nothing more. From a checkout, pass `--glowcap <path>` with the path of an existing executable file.

## First run

The commands below start the bot's session, issue it an access with the right to post and join, and serve the bot with that access. The session directory is private to the bot's session, and the bot directory is where `serve` keeps the bot's settings and state. Replace the nickname, the directory locator, and the room with your own.

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

`serve` checks the agent, its permission, and the `glowcap` path before it reads or stores the link, so a refused first run stores no settings and no link. It leaves only the bot directory and its `lock` file. The access `issue` made still exists, so revoke it with `session access list` and `revoke` before you issue another. `codex` and `pi` need `--permission full` on that first run, for example `--harness codex --permission full --link -`.

`serve` stays in the foreground and prints `ROOMS-BOT-SERVING claude` once it is attached. It starts at the newest activity, so lines written before the bot existed are never answered. Stop it with Ctrl-C. The next `serve` for the same directory needs only `--dir`, because the settings and the link are stored.

## Talking to it

Send the bot a direct message to its nickname and it answers every line you send. In a room, mention it with `@helper` in a line and it answers that line. A room-wide mention such as `@room` or `@here` does not wake it.

A line that is exactly `/reset` (in a room, `@helper /reset`) starts a new conversation with the agent, which forgets what was said there before. The bot answers it with one line that says so.

The bot reads the lines around a mention too. It keeps the last 40 lines of each conversation that did not address it, so a mention arrives with what was said just before. It answers one line at a time per conversation and shows as typing there while its agent works. Mentions that arrive while it works are answered together in its next reply. At most two conversations are answered at once.

The agent remembers each conversation. It works in its own directory for that conversation, and files sent to the bot are saved there for it.

## The bot's home

The bot's home is the `home` directory inside the bot directory, the one place the agent keeps across every conversation and restart. `serve` creates it, and the agent saves there what will help it later: notes, scripts, procedures it worked out, and its memories.

A memory is one small file in `home/memory/` whose first line is a one-line summary. For every reply, the agent is shown a list of its memories, newest first, by file name and summary, so it knows what it saved and opens a file when its summary matters. The list names at most <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/home.rs MAX_LISTED -->64<!-- /value --> memories and <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/home.rs MAX_LISTING_BYTES -->8,192<!-- /value --> bytes of names and summaries, and says how many more there are. A summary is cut after <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/home.rs MAX_SUMMARY_BYTES -->200<!-- /value --> bytes. A file that is not text, and any link, is listed by name only, and a `home` or `home/memory/` that is itself a link lists nothing.

The agent is asked to save what would help it next time, and to rewrite a memory that turns out to be wrong, or delete it when it can. A `safe` Claude agent can rewrite a memory but not delete one.

Every conversation shares the same memories, rooms and direct messages alike. So the agent is asked to save only what is fine to repeat anywhere: nothing from a direct message that its sender would not want said in a room, and no secrets. That is an instruction the agent follows, not a rule the bot enforces, so look through the home now and then.

The home belongs to you as much as to the agent. Read it, edit it, back it up, or move it to another bot directory while no `serve` runs. The bot writes nothing in it after creating it.

| What happens | What becomes of the home |
| --- | --- |
| `/reset` | Kept. Only the agent's conversation starts over. |
| A conversation is let go past the conversation limit | Kept. Only that conversation's own state goes. |
| `serve` restarts, or takes a new link with `--replace-link` | Kept. |
| You remove the bot directory | Removed with it. Keep a copy of `home` first. |

## Who it answers

Without an allow list the bot answers everyone who can write to it, which in a shared room is anyone who joins. `--allow` limits it to the nicknames you name:

```sh
glowcap apps rooms bot serve --dir "$HOME/.rooms/helper-bot" --allow ann --allow bob
```

`--allow` is repeatable and also takes a comma-separated list, and `--allow ''` clears the list. With a list, a line from anyone else never reaches the agent, not even as context for a later reply, and never counts toward the conversations the bot keeps.

A nickname is the name a room or directory shows for a member, compared without regard to case the same way Rooms compares nicknames. It proves only that the member wrote under that name when the bot read the line. Another person in another directory can hold the same nickname, a member who renames is no longer on the list, and someone who later takes a listed name is answered. Use an allow list to keep a bot quiet, and use the access rights below, not the allow list, to limit what it can do. A direct message from a member the session has not listed yet is read again a few times before the bot treats its sender as unknown.

Three limits bound the work anyone can start, even someone on the list:

| Flag | Default | What it limits |
| --- | --- | --- |
| `--sender-limit` | <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/config.rs DEFAULT_SENDER_LIMIT -->30<!-- /value --> | Messages from one person the bot answers in an hour, across conversations. |
| `--conversation-limit` | <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/config.rs DEFAULT_CONVERSATION_LIMIT -->60<!-- /value --> | Messages in one conversation the bot answers in an hour. |
| `--streak-limit` | <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/config.rs DEFAULT_STREAK_LIMIT -->10<!-- /value --> | Replies in a row to one person in one conversation, which stops bots from answering each other without end, however many take part. Only that person being quiet for ten minutes starts their count over. Other people writing in the conversation do not. |

A message the bot does not answer gets no reply, starts no turn, and writes one line in the bot's log. One from a sender on the list that a limit held back is kept as context for the bot's next reply there. The counts live in memory, so a restart starts them over.

## What it can do in Rooms

Each reply is the agent's final message. During a turn the agent can also use these commands, all as the bot's member:

| Command | What the agent can do with it |
| --- | --- |
| `say` | Post a line in the turn's conversation, in another conversation the session lets the bot post in, or with `--dm <nickname>` privately to a member. |
| `send` | Send files from its working directory to the turn's own conversation, or with `--dm <nickname>` privately to a member, up to eight at a time. |
| `workspace` | List the conversations the bot can post to, the people in them, and its own nickname. |
| `command` | Run any other session command the access's rights allow, such as editing or withdrawing a line, joining or leaving a room, or closing a direct message. |

These commands act for the turn that runs them: the bot tells them its directory and the turn's conversation, so they take no `--dir`, and they work only while the turn runs. One turn may run `say`, `send`, and `command` at most <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/actions.rs MAX_ACTIONS_PER_TURN -->12<!-- /value --> times in all, and past that they are refused with a message naming the bound. The bound holds however the agent is prompted only while the agent cannot write to the bot's directory outside its home or start a process that outlives its turn, as under `claude` with `--permission safe`. Looking again at an earlier `command` with its operation and base does not count. The bot's log records each line posted to another conversation, each direct message the bot opens, and each `command` run.

`--dm` looks the nickname up in the directory of the turn's conversation, so it reaches the member the agent saw there. The bot posts to the open direct message with that member when there is one. Otherwise it reopens the last one it closed with them, or opens a new one, and then posts. A nickname nobody holds there now, or the bot's own, is refused before anything is sent. Under `collaborator` rights the member cannot answer in a direct message the bot opened, because the session sets up the bot's side of it only for an access with `administrator` rights.

The session decides what the bot may do, so the rights you issue limit what the bot can do through Rooms.

| Rights | What the bot can do |
| --- | --- |
| `observer` | Read only. It cannot post, so it cannot answer. |
| `collaborator` | Post, send files, and join rooms. This is the right for a bot. |
| `administrator` | Everything a collaborator can, and manage the workspace. |

## Choosing the agent and its permission

`--harness` picks the agent and `--permission` picks what it may do. The default permission is `safe`.

- `safe` keeps the agent to its own working directory, its home, and the bot's own actions.
- `full` lets the agent do anything you can do on this machine. That includes reading the bot's link and your sessions' files, so the rights you issued no longer limit a full agent that runs as you. The operating system user is the boundary. Run a full bot in a container, as the [deployment guide](../../apps/rooms/web/deploy/README.md#run-a-bot) does, or as a separate user.

The bot refuses a combination it cannot enforce before it serves, so no agent runs with less confinement than you asked for.

| Agent | `safe` | `full` |
| --- | --- | --- |
| `claude` | Allowed. The agent may read, write, and edit files under its working directory and its home, and run only the bot's own commands. It gets no other tool. | Allowed. Every permission check is skipped. |
| `codex` | Refused. Codex's sandbox limits where it writes but not what it reads, so it could read the bot's session link. | Allowed. It needs a Codex sign-in the bot can find through `HOME` or `CODEX_HOME`. |
| `pi` | Refused. Pi has no sandbox or approval mode. | Allowed. |

So a first run with `--harness codex` or `--harness pi` also needs `--permission full`. Claude Code runs with its safe mode on, which drops your hooks, MCP servers, plugins, and instruction files and keeps your sign-in. It reads settings only from your user settings, and a safe run may not write a `.claude` directory in its working directory, so the agent cannot change what a later run allows. A safe Claude bot also refuses a `glowcap` path or a bot directory that holds any of `()*?[]{}\!#`, because a permission rule reads those as pattern syntax and would reach past the path.

`--model` selects the provider and model in the agent's own syntax, and the agent's own default is used when it is left out. `--deadline` sets how many seconds one reply may take, from 1 up to a day, and the default is 600.

`--instructions <file>` adds your own instructions to the bot's, such as a language to answer in or a topic to stay on. The bot reads the file for every reply, so an edit applies to the next one. The file holds UTF-8 text of at most <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/config.rs MAX_INSTRUCTIONS_BYTES -->16,384<!-- /value --> bytes. If it cannot be read when a reply starts, the bot answers with a line that says so. `--instructions ''` drops it.

## Settings as variables

Every `serve` setting is stored in the bot directory, so later runs keep it until you pass a new value. Each one is also read from a variable named `GLOWCAP_ROOMS_BOT_` and the flag's name in capitals with dashes as underscores. `--streak-limit` is `GLOWCAP_ROOMS_BOT_STREAK_LIMIT`, and `--allow` is `GLOWCAP_ROOMS_BOT_ALLOW` with a comma-separated list. A flag wins over its variable. `GLOWCAP_ROOMS_BOT_LINK` names the file or `-` that holds the link, never the link itself.

A variable never raises a bot stored as `safe` to `full`. `serve` refuses `GLOWCAP_ROOMS_BOT_PERMISSION=full` for such a bot and asks for `--permission full` on the command line.

## Keeping it running

A Rooms deployment under Docker Compose keeps a bot running as one of its services. [Run a bot](../../apps/rooms/web/deploy/README.md#run-a-bot) shows how. Any other supervisor, such as a systemd unit, can run `glowcap apps rooms bot serve --dir <bot directory>` once a first `serve` has stored the settings and the link.

## Looking after it

`bot status` reports whether a `serve` is running and what it last did:

```sh
glowcap apps rooms bot status --dir "$HOME/.rooms/helper-bot"
```

| Field | Meaning |
| --- | --- |
| `running` | Whether a `serve` holds the directory now. |
| `status.access` | `active`, `paused`, `revoked`, or `refused`, as the session reported the bot's access, and `unknown` until the session first answers. No turn starts unless it is `active`. |
| `status.queued` | Lines read but not yet given a turn, because <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/ledger.rs MAX_OPEN -->16<!-- /value --> turns are already open. The bot reads them again after a restart. |
| `status.open_turns` | Turns not finished, whether waiting, running, or sending. |
| `status.sending` | Turns whose reply is written and waiting for the session to take it. |
| `status.turns_finished` | Turns finished since the bot was first served. |
| `status.gaps` | Times the session reported events the bot missed. |
| `status.unavailable` | Times the session could not show some events. |
| `status.unreadable` | Events skipped since this `serve` started because the session could not decode them. |
| `status.unconfirmed` | Reply lines given up on since this `serve` started, because the session could no longer say whether they posted. Each such line posted once or not at all. |
| `status.last_error` | The last failure and what the bot was doing, until that activity next succeeds. A reply line the session has been working on for a long time shows here too, because that conversation's next reply waits for it, and so does a line given up on, until a later line posts. |
| `home.path` | The bot's home. |
| `home.memories` | How many memories `home/memory/` holds now. |

`bot ready --dir <bot directory>` exits 0 only while a `serve` holds the directory, has written its status, reports `status.access` as `active`, and has no `status.last_error` from reading the session (`during` is `receiving`). Otherwise it prints why and exits nonzero, so a container health check can use it.

The log is `bot.log` in the bot directory. Each line starts with its UTC time. A turn logs when it starts and when it finishes, with its conversation, duration, and outcome, and the log never holds message text. An access state such as `paused` or `revoked` is logged once when it changes. What the agent prints to its error output is logged with control characters escaped, and each logged line is cut at <!-- value ../../apps/rooms/rust/product/src/bin/rooms-bot/store.rs MAX_LOG_LINE_BYTES -->4,096<!-- /value --> bytes. The log rotates to `bot.log.1` after one megabyte.

You manage the access from the bot's session directory:

```sh
glowcap apps rooms session access list --dir "$HOME/.rooms/helper"
glowcap apps rooms session access pause --dir "$HOME/.rooms/helper" --id <id>
glowcap apps rooms session access resume --dir "$HOME/.rooms/helper" --id <id>
glowcap apps rooms session access revoke --dir "$HOME/.rooms/helper" --id <id>
glowcap apps rooms session access forget --dir "$HOME/.rooms/helper" --id <id>
```

`list` shows each access with its id, rights, and whether it is active, paused, or revoked. A paused access stops working until you resume it, and a revoked one is over for good. `forget` drops a revoked access from the list and refuses one that still works. The session page lists the same accesses. A failed command prints `{"ok":false,"error":{"class":...,"retry":...,"message":...}}`, the same shape the `bot` commands print.

The session saves an access's row before it creates the access. If the session stops partway through an `issue`, `list` shows that id as `unfinished`, and the access it may have made stays paused. Run `issue` again with `--id` set to that id and the same label and rights to finish it. If another issue took its place first, finishing is refused, and `forget` drops the row instead. Any access the stopped issue made stays paused with its link never shown, and `list` shows it without an id.

To give the bot a new link, stop the bot, issue a new access, run `serve` once more with the link and `--replace-link`, and revoke the old access once the bot serves. Without that flag `serve` refuses a link other than the stored one, because the bot's saved position belongs to the session the old link reached. Before it saves the new link, `serve` waits up to a minute in all for the replies that were going out under the old one to settle, so the old access's own record decides whether each posted. A bot stopped during that wait keeps the old link. A reply still unsettled then is left to the new link, which looks for it in the session's activity and never sends it again.

The log says what became of each reply. Only the old access can give a reply's record back, so a record it left when the minute ran out or the old access stopped working stays with the session until the old access is revoked, and the session then releases it. Until then each such record keeps one of the session's few receipt places.

```sh
glowcap apps rooms session access issue \
  --dir "$HOME/.rooms/helper" --label bot --rights collaborator \
  | glowcap apps rooms bot serve \
      --dir "$HOME/.rooms/helper-bot" --link - --replace-link
```

## When something goes wrong

A turn is one run of the agent for one reply. Every line the bot answers ends with a reply, either the agent's answer or one line that says why there is none, with one exception: a reply line the bot gives up on, below, because the session can no longer say whether it posted. That line posted once or not at all. No reply line posts twice.

| What happens | What the bot does |
| --- | --- |
| The agent crashes or ends without an answer | It starts the agent again, and a start counts as a try. The agent resumes the same conversation when it reached it before it failed. Only an agent that never found its saved conversation gets a new one. After two tries it posts `I could not answer that: the agent stopped unexpectedly, after 2 tries.` When the agent said why, the line carries its short message. |
| The agent takes longer than the deadline | It ends the agent's process group, which holds the agent and every process it started that stayed in the group, and posts a line saying the agent did not finish in that many seconds. It does not retry. A process the agent moved out of the group, for example with `setsid`, keeps running. |
| The agent's sign-in is refused, it hit a usage limit, or it declined the request | It posts one line naming that reason, with the agent's short message when it gave one, and does not retry. |
| The bot itself stops or is killed during a turn | The next `serve` finishes the turn. A turn in the middle of its run runs the agent again, so its side effects can repeat. A reply already written is posted at most once, and once unless the bot gives it up as below. |
| The answer is long | A line holds at most 8192 bytes. A longer answer is posted as several lines, split at paragraph breaks, and cut after eight lines with a notice. |
| The bot's access is paused or revoked | It ends any agent still working on a reply and starts no new one. It keeps trying to reach the session, waiting up to five minutes between tries, and `status.access` shows the state. Once the access works again, each reply that was cut off runs from the start, and a reply already written is posted. |
| The session is unreachable | The bot reconnects on its own with a wait that grows to one minute. A reply that was started is posted at most once, under the same operation. |
| The bot is killed while a reply line is going out | The next `serve` asks the session about that line before it sends anything. A line the session took is kept and never sent again. When the session holds no record of the line, the bot looks for it in the session's activity. Found, it counts as sent. Not found in a complete read since the line went out, in the same session run, it is sent once more. When the activity cannot say, the bot moves on without sending it again. This is what happens when the bot is killed and the session also restarts before the bot is back: the line posted once or never, so that trigger may get no reply. The log line `cannot say whether operation`, `status.unconfirmed`, and `status.last_error` show it. |
| The session refuses to send a line again because the workspace has changed since | The bot looks for the line in the session's activity again. Not found in a complete read in the same session run, it sends the line once under a new operation. Otherwise it treats the line as above. |
| The session cannot say whether a line posted | The bot looks for the line in the session's activity. Found, it counts as sent. Otherwise the bot moves on without sending it again, so a line is never posted twice, and the log, `status.unconfirmed`, and `status.last_error` say so. |
| The session cannot decode an event | The bot skips it, counts it in `status.unreadable`, and reads on. |
| The session restarts | The bot reads the new run's activity from its start and counts a gap. |

If saving the agent's answer to the bot's state fails, the bot tries the write again with a growing wait and does not run the agent again while it lives. A bot that dies before that write lands runs the turn again after a restart.

## Limits

- Lines posted while the session was restarting are not answered. They appear in `status.gaps`.
- A line sent while the bot was stopped is answered after the next start. A line sent before the bot's first start is not.
- The bot answers new lines only. It does not answer an edit of a line, and it never answers its own lines.
- A file sent to the bot is fetched from the sender's machine when its turn starts, because the sender holds the file and the session keeps no copy. A sender that has disconnected by then leaves the file unsaved, and the agent is told it could not be fetched.
- One reply answers at most eight waiting lines of a conversation. The rest wait for the next reply.
- One bot directory serves one session and one `serve` at a time. A second `serve` for the same directory is refused.
- The bot keeps recent lines, a working directory, and the agent's saved conversation for at most <!-- value ../../apps/rooms/rust/application/src/content/session/workspace.rs MAX_CONVERSATIONS -->256<!-- /value --> conversations. Past that, it removes all of them for the conversation it heard from longest ago, and that conversation starts fresh the next time it addresses the bot.
- The session keeps its last <!-- value ../../apps/rooms/rust/runtime/src/session/managed/activity.rs MAX_EVENTS -->4,096<!-- /value --> activity events. When a line's fate is unknown and its event has already left that window, the bot cannot find it, so it moves on without sending the line again. A session restart has the same effect.
