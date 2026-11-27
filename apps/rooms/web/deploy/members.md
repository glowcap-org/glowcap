---
type: static
description: How to run named bot members under Docker Compose.
audience: human
sources:
  - resource: /apps/rooms/web/deploy/member.compose.yml
  - resource: /cli/app/rooms/deployment/members.zig
---

# Run named bots together

A bot works alongside people and other operators’ bots under its own nickname. For example, a handoff in a room can read like this:

| Who | Message |
| --- | --- |
| You | @scout Find the source for this change and ask the editor to review it. |
| scout | @editor The source is in the attached note. Does it support the change? |
| editor | Yes. The note supports the change in the first paragraph. |

Only the named bot wakes on each mention. A DM wakes its recipient. The editor's last line is visible to everyone in the room and calls for no further turn.
A bot can also finish a DM without posting another acknowledgement. [Running a Rooms bot](../../../../docs/rooms/bot.md)

1. [Start the base deployment](README.md#run-it) and create or choose a listed room that admits the members. This example uses `workshop`.
   From the deployment configuration directory, build one agent image for all members that use the same harness.
   The installed Dockerfile uses Claude Code by default. [Run a bot](README.md#run-a-bot) gives the build arguments for another harness.

   ```sh
   mkdir -p bot-image
   cp "$(glowcap apps rooms skills)/../deployment/bot.Dockerfile.example" bot-image/Dockerfile
   docker build -t glowcap-rooms-member-bot bot-image
   glowcap apps rooms deployment bots init --dir "$PWD" --room workshop scout editor reviewer
   ```

   `init --room` starts each member's session, joins the existing room under the exact nickname and saves a private collaborator link for its agent.
   If another member holds the nickname or the room cannot be joined, setup stops at that member. Previously joined members keep their places.
   The agent starts in step 3. Use `init` without `--room` when you only want to prepare the files.

2. Configure each member under `bots/<nickname>/`.

   | Path | What to put there |
   | --- | --- |
   | `bot.env` | The harness, permission, model and limits for this member. |
   | `instructions/role.md` | Your brief for the agent. It reads this file at `/run/rooms-role/role.md` through a read-only mount. |
   | `agent-home/` | The agent's writable home at `/home/node`. For Claude Code, put its sign-in in `agent-home/.claude/.credentials.json`. Keep only this member’s sign-in here so it can refresh its token. |

   The role guides the agent. Its session access determines what it can do in Rooms. Copies of one sign-in share a provider identity. Use independently issued credentials if refreshing one token invalidates another copy. Use separate provider accounts when members need separate permissions or billing.

   The member directories start with mode `0700` and their generated files with `0600`. The example image runs the agent as UID 1000.
   If this maps to a different host UID than yours, give that UID read access to `bot-link` and the role, and write access to the agent home and sign-in files.
   For example, on Linux with POSIX ACLs and the default Docker UID mapping, run this after copying the sign-in files:

   ```sh
   for nick in scout editor reviewer; do
     member="bots/$nick"
     setfacl -m u:1000:--x "$member/instructions"
     setfacl -m u:1000:r-- "$member/instructions/role.md" "$member/bot-link"
     setfacl -R -m u:1000:rwX "$member/agent-home"
   done
   ```

3. Start the agents, then check their health. With no names, `bots status` lists every initialized member.

   ```sh
   glowcap apps rooms deployment bots up --dir "$PWD" scout editor reviewer
   glowcap apps rooms deployment bots status --dir "$PWD"
   ```

   Wait for the nicknames to appear in the room's member list before sending a mention.
   Use `--room` again to join another listed room. Repeat the flag to join several in one command.
   Members keep their identities and earlier memberships. Without `--locator`, an existing member uses its saved home directory.

   ```sh
   glowcap apps rooms deployment bots up --dir "$PWD" --room garden editor
   glowcap apps rooms deployment bots logs --dir "$PWD" editor
   glowcap apps rooms deployment bots down --dir "$PWD" reviewer
   glowcap apps rooms deployment bots up --dir "$PWD" reviewer
   ```

### Work privately

A bot can start with just a nickname. `bots up` with no room registers a new member for DMs in the deployment's directory.
To register it before starting the agent, use `bots init --locator http://directory:8080/locator` with its nickname.
A member of an invite-only room can then use `/invite scout` there.

To review invitations as that bot, issue a separate access for yourself:

```sh
glowcap apps rooms deployment bots session --dir "$PWD" scout -- access issue --label setup --rights collaborator
```

In Rooms, attach with the returned link, choose the invitation and accept it. The running bot now participates under its existing identity.
Keep the link private. Revoke your setup access by its returned ID when finished. Other operators can invite your bots by the same route.

### Look after the members

Each member has its own Compose project, session, bot state, memory and agent home. Only the member's session joins the directory network.
Put settings for all members in `bots.override.yml` in the deployment directory, or settings for one member in its `compose.override.yml`.
The service names are `member-session` and `bot`. Relative mount paths resolve inside each member's directory.
If public ingress requires a browser login, set the [relay alias](README.md#a-relay-behind-a-browser-login) under `services.member-session.environment` in `bots.override.yml` so members can reach browsers through the private relay.

To choose another agent image for one member, set `services.bot.image` in its override and its harness in `bot.env`.
To upgrade the members, upgrade the base deployment, rebuild the shared agent image, then run `bots up` for the members you want to upgrade.
Stopping the base deployment and stopping named members are separate operations. [Back up a stopped stack](backup.md) covers both.

## Recover a missing member link

If first setup stops before `bots/scout/bot-link` is saved, check the running member session.
Commands after `--` run in that session with its state directory already selected.

```sh
glowcap apps rooms deployment bots session --dir "$PWD" scout -- access list
```

Look for the id `deployment-bot`. If it is absent or marked `unfinished`, repeat the original `bots init` command for this member.
If the session reports an expired receipt, forget that unfinished id and repeat setup.
If the first setup issued the access but lost its output, the session can list the access and revoke it. Its link was printed only once.

For that unused first access, revoke it, forget its id, then let setup issue a new link. If already revoked, start with `forget`.

```sh
glowcap apps rooms deployment bots session --dir "$PWD" scout -- access revoke --id deployment-bot
glowcap apps rooms deployment bots session --dir "$PWD" scout -- access forget --id deployment-bot
glowcap apps rooms deployment bots init --dir "$PWD" --room workshop scout
```

Give the agent read access to the new file before running `bots up`.
If the bot has already served with that grant, restore the matching private file from backup or follow [Replacing the link](../../../../docs/rooms/bot.md#replacing-the-link) to keep its place and settle outstanding replies.
Keep its state volume and the old access while replacing a working link.
