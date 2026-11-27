---
type: static
description: How to run Rooms under Docker Compose on a deployment host.
audience: human
sources:
  - resource: /apps/rooms/web/deploy/
  - resource: /cli/app/rooms/deployment/
---

# Deploy Rooms

`glowcap apps rooms deployment` runs three things under Docker Compose: the web page, the directory (the server that
lists and hosts rooms), and one shared session. The shared session lets several people or devices use the same Rooms workspace through access links.
People who open the page can also keep separate sessions in their own browsers.
`up` always starts the shared session.

Docker keeps the services running after the terminal closes and restarts them after a host reboot. The directory and
session run the same product CLI as a host installation.

Install the [complete host product](../../host.md) and Docker with Compose v2.17 or later on the deployment host.
The [host guide's table](../../host.md#install) lists the supported targets.

Your user must be able to run Docker, either as root or through the `docker` group.

A published image needs no checkout, compiler, Python, or product source. Releases carry build provenance. Verify the
image before running it with
`gh attestation verify --repo glowcap-org/glowcap oci://ghcr.io/glowcap-org/glowcap-rooms:vVERSION`.

## Run it

For the product's default image:

```sh
glowcap apps rooms deployment up
```

For a tag, digest, or existing local image:

```sh
glowcap apps rooms deployment up --image ghcr.io/glowcap-org/glowcap-rooms:vVERSION
```

An installed executable defaults to `ghcr.io/glowcap-org/glowcap-rooms:vVERSION`, with the version from the installed
CLI. The first `up` pulls the public image from ghcr.io, so the host needs outbound network access. It resolves the
image to an immutable ID and waits for service health. Then it prints, in order:

- the page link, which opens the published Rooms page with this server filled in. On this host,
  `http://127.0.0.1:8080/`, the loopback port the override publishes, serves the same page
- the directory's operator capabilities, the secret `ocapn://` links that grant access
  ([operator capabilities](../../operating.md#operator-capabilities))
- the directory locator
- the browser revision
- the shared session's use link
- the shared session's management link
- the trace link

Copy them now. `glowcap apps rooms deployment links` prints them again
([Read your links again](#read-your-links-again)).

If port 8080 is taken, change the first port in the override's `ports` entry, such as `127.0.0.1:8081:8080`.
Then uncomment these lines, `environment:` as well as the variable, so the printed link follows:

```yaml
services:
  directory:
    environment:
      GLOWCAP_ROOMS_HTTP_PUBLIC: "http://localhost:8081/"
```

The
[work admission guide](../../../../docs/rooms/admission.md#configuration) covers rate, capacity, and HTTP source
overrides for this deployment, and the operator page shows the directory's effective profile under **Work budgets**.

- Later `up` commands reuse the selected image and never silently download an upgrade. Every `up` and `reset` names
  the image it selected or kept.
- Passing `--image` again updates the image and records the previous image ID in `previous-image`. Changing images does
  not reverse changes to the stored session format.
- An image built with `--build` carries its product's source revision in the `org.opencontainers.image.revision`
  label.

Configuration defaults to `$XDG_STATE_HOME/glowcap/rooms-deployment`, or `$HOME/.local/state/glowcap/rooms-deployment`.
Every command accepts `--dir <configuration-directory>` to pick the configuration. The deployment has fixed container,
network, and volume names, so one Docker daemon runs one stack.

The managed `compose.yml` is refreshed from the installed product during `up` and `reset`. Every setting this host
chooses belongs in `docker-compose.override.yml`, which `up` copies once from the example and never rewrites. Its
`environment` entries add to and replace the managed file's. Every operator capability is on by default. To withhold
some, list the ones you want in the override, such as
`GLOWCAP_ROOMS_CAPABILITIES: "admin-listeners,diagnostics,operator,peering,trace"`, which leaves IRC out.

The directory and session run as container user 0 so they can reopen their existing state volumes. Compose drops all
Linux capabilities, prevents the processes from gaining privileges on exec, and makes the container root filesystem
read-only. The state volumes and the session's readiness tmpfs remain writable. If you supply your own mounts,
give the container user write access to its state and mount any additional output directories writable.

### Host it publicly

The example override publishes the page on this host's loopback port only. That keeps the page local but not the
directory: anyone holding its locator reaches the directory over iroh, through public iroh relays and DNS discovery.
That path needs outbound UDP and DNS from the host to the public iroh relays. To let people open the page from
elsewhere:

1. Run `up` once. It creates `docker-compose.override.yml` in the configuration directory. `doctor` prints that path.
2. Put an HTTPS proxy or tunnel in front of port 8080, or of `http://glowcap-rooms-directory:8080` over a shared
   network. It must pass WebSocket upgrades, because browsers reach the directory through `/relay`, and it must keep
   the original `Host` header, because the server accepts its own page by that header. A proxy that rewrites `Host`
   needs the public page address listed in `GLOWCAP_RELAY_ALLOW_ORIGINS` instead. A Caddy on the same host needs
   only this, since Caddy passes WebSocket upgrades and keeps `Host` by default:

   ```
   rooms.example {
       reverse_proxy 127.0.0.1:8080
   }
   ```

   A Caddy in a container joins the `glowcap-rooms-net` network, as the override example shows, and names the service:

   ```
   rooms.example {
       reverse_proxy glowcap-rooms-directory:8080
   }
   ```

   The proxy is the only thing that needs inbound ports, 80 and 443. Publish nothing else.
3. In the override, uncomment `environment:` together with the variable, and set `GLOWCAP_ROOMS_HTTP_PUBLIC` to the
   public address, ending in `/`. The page link the server prints is then one people elsewhere can open:

   ```yaml
   services:
     directory:
       environment:
         GLOWCAP_ROOMS_HTTP_PUBLIC: "https://rooms.example/"
   ```

   For a public host, list in `GLOWCAP_ROOMS_CAPABILITIES` only the capabilities you need.
   Read the minted links with `deployment links` ([the capability table](../../operating.md#operator-capabilities)).
4. Charge each client its own allowance. Add `GLOWCAP_ROOMS_HTTP_ADMISSION_PER_ADDRESS: "true"` and
   `GLOWCAP_ROOMS_HTTP_TRUSTED_PROXIES` under the same `environment:`, set to the address the container sees your proxy
   at. For a proxy on this host, that is the network gateway:

   ```sh
   docker network inspect glowcap-rooms-net --format '{{(index .IPAM.Config 0).Gateway}}'
   ```

   Without these, every user behind the proxy shares one allowance. The
   [work admission guide](../../../../docs/rooms/admission.md#configuration) describes both variables.
5. Run `up` again and give people the page link it prints. The server also serves the same page itself at its public
   address. By default the link opens the page glowcap.org publishes, run against your server.
6. To print a link for your own page instead, list it first in `GLOWCAP_RELAY_ALLOW_ORIGINS`. Write its public address
   ending in `/`, and keep glowcap.org in the list ([the origin rule](../../operating.md#security-posture)):

   ```yaml
   GLOWCAP_RELAY_ALLOW_ORIGINS: "https://rooms.example/,https://glowcap.org/rooms/app/"
   ```

   Each page keeps its own browser sessions. Run `up` again to print the new link.

### A relay behind a browser login

Open Rooms at the server's public address and sign in there. The page and its requests then use the same origin and
browser session. A Rooms page hosted elsewhere reads anonymously, so give readers the server's own page link for a
deployment that requires sign-in. Set the public address and list its page first as shown in [Host it publicly](#host-it-publicly).

When public ingress requires a login, such as Cloudflare Access, a shared-session server cannot use the browser's
login cookie. When it connects for a direct message, it follows the other browser's advertised `/relay` route and
receives a login redirect.
Configure an alias when that public route reaches this deployment's directory relay:

```yaml
services:
  session:
    environment:
      GLOWCAP_ROOMS_SESSION_RELAY_ALIAS_URL: wss://rooms.example/relay
```

Add this to `docker-compose.override.yml` in your configuration directory, replacing `rooms.example` with the page's
public host (and port if needed). Then run `glowcap apps rooms deployment up`.

- The shared session dials the matching route through the Compose default `ws://directory:8080/relay`. Browser
  connections still use public ingress.
- Only this exact endpoint is redirected, including scheme, host, port, path, and fixed query. Other deployments' relay
  hints keep their routes.
- Both routes must reach the same registry.
- The alias gives outside non-browser peers no access to a protected relay. Browser sign-in, peer identity, and Noise
  encryption stay as they were.
- A standalone session accepts the same setting as `--relay-alias-url`, together with `--relay-url` naming the
  internal endpoint.
- A standalone session dials WebRTC-only browsers when started with `--dial-transports=webrtc`. The Compose session
  keeps the relay route, which every browser can reach.

To move a deployment's configuration, copy its operator override into the new directory before running `up` or
`reset`. Relative paths in the override resolve from the configuration directory, so review them. Keep the originals
until the deployment is healthy. The CLI does not discover or copy configuration from other directories.

## Upgrade

Read the release notes and [back up the stopped stack](#data-and-reset) before upgrading. Run these commands in the
configuration directory printed by `deployment doctor`. For a local build or a rollback on another Docker host,
[save the selected image](#keep-a-copy-of-the-selected-image) with the backup. Select the new version and check its health:

```sh
glowcap apps rooms deployment up --dir "$PWD" --image ghcr.io/glowcap-org/glowcap-rooms:vNEW
glowcap apps rooms deployment status --dir "$PWD"
```

Upgrade the host CLI as well as the image. The CLI writes the managed Compose file on each `up`. If your
override defines a bot session, copy its `healthcheck`, `cap_drop`, `security_opt`, and `read_only` settings from the
updated bot-session example before running `up`.
Both checks should invoke `/runtime/libexec/rooms-session --check-ready=/run/rooms-session/use.sturdyref`.

With the updated image these probes report readiness by exit status. An older template calls a command that prints
the use link into Docker health history, even with the updated image. Older images can also retain bearer links
in startup logs. Treat those records as credentials, including any retained after a rollback.

After an image change, `image` holds the new ID and `previous-image` holds the old one. To roll back that change,
use the backup you made immediately before the upgrade. The older version may need the matching state restored
**before** it starts. If Docker no longer has that image, [load the archived image](#keep-a-copy-of-the-selected-image) first.
Once its data is ready, this checks the previous image against the saved selection:

```sh
rollback_image=$(cat previous-image) &&
  saved_image=$(tar xOzf "$backup/config.tgz" ./image) &&
  test -n "$rollback_image" && test "$rollback_image" = "$saved_image" &&
  glowcap apps rooms deployment up --dir "$PWD" --image "$rollback_image"
```

If the IDs differ, check `image` before proceeding. It still holds the original ID if the upgrade stopped before saving a new selection.
When restoring the pre-upgrade configuration, its own `image` already selects the matching version.

### A session the new version cannot read

When the release notes say saved sessions no longer open, the session container stops at each start and Compose
starts it again. `glowcap apps rooms deployment logs --dir "$PWD" session` shows `This session's saved data is in a form this version
of Rooms can't read`. A bot's session stops the same way. Start new sessions in their place:

1. [Back up the stopped stack](#data-and-reset), including the bot's volumes and host files if you run one.
   Check the archives before removing any state. Keep the stack stopped.
2. If you run a bot, comment out the override's `bot` and `bot secret` pieces. Keep its home mount and give
   `bot-session-state` and `bot-state` two new, unused Docker names. Compose creates the empty volumes and leaves the
   old ones under the names you backed up.

   Create the replacement yourself for an external volume, or point a bind mount at a new empty directory.
   Move the old bot link to the private backup directory so the next issue can create its file.
3. Run `glowcap apps rooms deployment reset session --dir "$PWD" --image ghcr.io/glowcap-org/glowcap-rooms:vNEW`.
   It confirms removal of this configuration's shared session volume, starts the stack, and prints the new use and management links.

   For an external volume or bind mount, reset refuses removal. Point the shared session's `/session-state` mount
   at a new empty volume or directory you provisioned. Start it with
   `glowcap apps rooms deployment up --dir "$PWD" --image ghcr.io/glowcap-org/glowcap-rooms:vNEW`.
   The previous mount remains available for rollback.
4. Send members the new use link. Each attaches again as [Read your links again](#read-your-links-again) shows. Every
   access link the old session issued stops working, so issue new ones with the new management link.
5. If you run a bot, follow steps 2 to 4 of [Run a bot](#run-a-bot). It answers only lines sent after it starts.

## Build and run your own version

A checkout prepares its own image with `./glowcap apps rooms deployment up`. The steps, the build environment, and the
image are in [Developing Rooms](../../developing.md#deploy-from-a-checkout).

## Run a bot

A [Rooms bot](../../../../docs/rooms/bot.md) is a member whose replies come from a coding agent. Compose keeps it
running beside the deployment. This adds a second session for the bot to speak as, and the bot itself.
The agent and its configuration are this host's choice, so they live in your override and your own files, never in the
repository or the managed file.

The release image holds no shell and no agent, so the bot runs from an image you build from
[`bot.Dockerfile.example`](bot.Dockerfile.example). An installation keeps it in `share/glowcap/deployment/`, beside the
skills directory that `glowcap apps rooms skills` prints. For a new bot image, copy the example into the configuration directory:

```sh
mkdir -p bot-image
cp "$(glowcap apps rooms skills)/../deployment/bot.Dockerfile.example" bot-image/Dockerfile
```

Keep only image build inputs in `bot-image/`. Runtime files under `bot/` and `secrets/` stay outside the Docker build context.

`up` preserves an existing `docker-compose.override.yml`. If yours predates the bot, merge the bot session, bot,
volumes, and secret sections from `docker-compose.override.yml.example` beside the installed Dockerfile example.
If your override already builds from `./bot`, move its Dockerfile to `bot-image/Dockerfile` and set the bot's
`build.context` to `./bot-image` before the next build. Leave its credentials and home under `bot/`.

The Dockerfile starts from the same Debian release as the image and copies `/runtime` out of it. The override passes it
the agent's npm package and configuration directory as `AGENT_PACKAGE` and `AGENT_DIR`, so changing agents changes
those two lines of the override and not the file.

| Agent | `AGENT_PACKAGE` | `AGENT_DIR` | Sign-in file to copy |
| --- | --- | --- | --- |
| Claude Code | `@anthropic-ai/claude-code` | `.claude` | `.credentials.json` |
| Codex | `@openai/codex` | `.codex` | `auth.json` |
| Pi | `@earendil-works/pi-coding-agent` | `.pi/agent` | `auth.json` |

Codex reads `auth.json` from `CODEX_HOME`, else `~/.codex`.

The container user is `node`, user 1000. The bot's access link is a file Compose mounts with its owner and mode on this
host, so that user must be the file's owner. Change the user, or the file's owner, if your account is not 1000. The
`mkdir` also makes `/bot-state/home`, so a new home volume starts out owned by that user.

The bot's [home](../../../../docs/rooms/bot.md#the-bots-home), where its agent keeps notes and memories across every
conversation, is its own volume, `glowcap-rooms-bot-home`, mounted inside the bot volume. Starting the bot fresh removes
only `glowcap-rooms-bot-state`, so the home survives it. To keep the home on this host, where you can read and back it
up directly, replace the `bot-home` mount with the bind mount the override's comment shows, from a directory owned by
user 1000.

1. Open `docker-compose.override.yml` and uncomment the bot session and the volumes, the pieces headed `bot session` and
   `bot volumes`. Run `glowcap apps rooms deployment up --dir "$PWD"`.
2. Give the bot's session its nickname and rooms. It keeps them across restarts, so this runs once:

   ```sh
   docker exec glowcap-rooms-bot-session /runtime/bin/glowcap apps rooms session start \
     --dir /session-state --nick helper --locator http://directory:8080/locator --room workshop
   ```

3. Issue the bot's access link into a file. The link is a secret, so the file is private and the link never reaches a
   command line, a variable, or a log. Run this in the configuration directory, which `doctor` prints:

   ```sh
   install -d -m 700 secrets
   (
     umask 077
     set -C
     exec 3>secrets/bot-link || exit 1
     docker exec glowcap-rooms-bot-session /runtime/bin/glowcap apps rooms session access issue \
       --dir /session-state --label bot --rights collaborator >&3 || { rm -f secrets/bot-link; exit 1; }
   )
   ```

4. Uncomment the pieces headed `bot` and `bot secret`, and fill in the agent, its permission, its model, and the files
   it reads its sign-in from, as the comments there say. Mount only what the agent needs, from copies kept in the
   configuration directory. Run `glowcap apps rooms deployment up --dir "$PWD"` again.

   Agents rewrite their sign-in file each time they refresh a token. Create a private directory under `bot/` (for Claude
   Code, `install -d -m 700 bot/claude`). Copy the sign-in file there, give user 1000 ownership of the copy and its
   directory, and mount the directory writable at
   `/home/node/<AGENT_DIR>`. A read-only mount works until the first token expires, and then every reply is a sign-in
   failure. The agent can rewrite that copy, so keep nothing else in it.

The bot is healthy when `bot ready` passes, which the bot guide's
[Looking after it](../../../../docs/rooms/bot.md#looking-after-it) defines. `status` shows it, and `logs bot` follows it. Send the bot a
direct message to see a reply, or mention it in a room. A bot whose agent is missing from the image refuses to start and
names the program it looked for.

The bot guide's [What the bot may do](../../../../docs/rooms/bot.md#what-the-bot-may-do) says how to limit what it
does and who can reach it. The override's comments show the hourly limit and your own instructions file. To drop
instructions the bot already stored, add `--no-instructions` to its `command`, run `up`, and remove the flag once the bot
serves. Left in, it drops every instructions file, including one a later `GLOWCAP_ROOMS_BOT_INSTRUCTIONS` names, and
says nothing.

The bot guide's [Choosing the agent and its permission](../../../../docs/rooms/bot.md#choosing-the-agent-and-its-permission)
says what a `full` agent can reach, including the files and credentials available to its user.
The example bot drops all Linux capabilities and prevents executables from gaining privileges. For an existing
override, copy `cap_drop` and `security_opt` from the example into the `bot` service. The bot reaches its session over
[iroh](https://www.iroh.computer/) and needs none of this deployment's networks. A model server that listens only on the host's loopback needs
`network_mode: host`, as the override's comments say.

To pause, resume, or revoke the bot, manage its access from its session:

```sh
docker exec glowcap-rooms-bot-session /runtime/bin/glowcap apps rooms session access list --dir /session-state
docker exec glowcap-rooms-bot-session /runtime/bin/glowcap apps rooms session access pause --dir /session-state --id ID
```

`resume` and `revoke` take the same arguments.

### Give the bot a new link

Wait until the bot has no turn open, because a turn still working sends its reply next and only the old access can
settle a reply going out. This prints `status.open_turns`, which must be 0:

```sh
docker exec glowcap-rooms-bot /runtime/bin/glowcap apps rooms bot status --dir /bot-state
```

A bot that keeps restarting runs no turn, so skip this wait for it.

Then run `docker rm -f glowcap-rooms-bot` and `docker volume rm glowcap-rooms-bot-state`, revoke the old access, and
remove `secrets/bot-link`, which step 3 refuses to overwrite. Repeat steps 3
and 4. A bot that starts fresh answers only lines sent after it starts.

To keep the bot's place in its session instead, keep its volume. Remove `secrets/bot-link`, repeat step 3, add
`--replace-link` to the bot's `command`, run `up`, and revoke the old access once the bot serves. Then remove the
flag from `command`: left in, the next fresh start has no stored link to replace, so the bot refuses to start, naming
the flag. The bot guide's
[Replacing the link](../../../../docs/rooms/bot.md#replacing-the-link) says what becomes of replies going out at the time.

### A bot that keeps restarting

A bot that cannot start stops with an error, and Compose starts it again and again. `docker exec` into it fails while
it is down, so read the error with `glowcap apps rooms deployment logs bot`:

- A bot directory its build cannot read names the unreadable file. Start the bot fresh as
  [Give the bot a new link](#give-the-bot-a-new-link) describes, which drops its settings and its place in the session.
- A `config.json` that holds a field the bot does not read names each field. Stop the bot, delete those fields through
  a container of the bot's own image, and start it again with its place kept. Replace `FIELD` with each named field:

  ```sh
  docker stop glowcap-rooms-bot
  docker run --rm --user 1000 -v glowcap-rooms-bot-state:/bot-state --entrypoint node glowcap-rooms-bot -e '
    const fs = require("fs"), file = "/bot-state/config.json";
    const config = JSON.parse(fs.readFileSync(file, "utf8"));
    for (const field of process.argv.slice(1)) delete config[field];
    fs.writeFileSync(file, JSON.stringify(config, null, 2));
  ' FIELD
  docker start glowcap-rooms-bot
  ```

- A bot that names `--replace-link` and says it needs a stored link to replace is starting fresh with the flag left in
  `command` from an earlier replacement. Remove the flag and run `up`.
- A revoked access names `--replace-link`, because a bot does not wait for a new access. Replace the link with its
  volume kept, as [Give the bot a new link](#give-the-bot-a-new-link) describes. The bot keeps its old link until its
  session has answered the new one. A new link the session refuses makes the bot exit with an error that says so, and
  it restarts with the same refused link until you correct it, so check the new access before you run `up`.

### Remove the bot

To remove the bot for good, revoke its access, comment its pieces out, and remove both of its containers, its three
volumes, and its link file. Removing `glowcap-rooms-bot-home` deletes everything its agent saved, so copy it first if
you want to keep it:

```sh
docker rm -f glowcap-rooms-bot glowcap-rooms-bot-session
docker volume rm glowcap-rooms-bot-state glowcap-rooms-bot-home glowcap-rooms-bot-session-state
rm secrets/bot-link
```

The bot session's volume holds the bot's identity and its session's management link, so removing it ends the bot's
membership for good.

To upgrade, run `up --image` as [Upgrade](#upgrade) says. `up` also names the selected image `glowcap-rooms:selected`
and rebuilds the bot image from it, so the bot follows the image without a separate step. A change to `bot-image/Dockerfile`
rebuilds on the next `up` the same way. Everything else about the bot, such as the agent, its limits, and its
failures, is in [Running a Rooms bot](../../../../docs/rooms/bot.md).

## Inspect and stop

```sh
glowcap apps rooms deployment doctor
glowcap apps rooms deployment links
glowcap apps rooms deployment status
glowcap apps rooms deployment logs directory   # follows until Ctrl-C
glowcap apps rooms deployment trace
glowcap apps rooms deployment restart
glowcap apps rooms deployment down
```

`trace` follows the protocol feed from a short-lived viewer container on the deployment network, so no trace port is
published. It prints the replay, then live events, and `--json` gives complete records.

- Service logs and protocol traces are separate streams.
- The feed holds the directory's events and events from session producers configured to publish to it. It cannot see
  traffic that stays with another peer.

For browser and session publication and for remote viewers:

1. Set the directory's `GLOWCAP_ROOMS_TRACE_CONNECT` and `GLOWCAP_ROOMS_TRACE_PUBLISH` in your override to its public
   WebSocket routes. The example override shows `/trace/captp` and `/publish`. A proxy that forwards every
   path with its WebSocket upgrades, as the one above does, needs nothing more.
2. Run `deployment up` and paste its complete trace link into **Settings**, **Holdings**, **Live trace**.

Publishing starts once that toggle holds the link, and the **Visualizer** page shows its state
([Operating Rooms](../../operating.md#watching-the-room-live)). An attached shared session publishes from its server process, so `deployment trace` receives those events too.

- `doctor` is read-only. It reports the selected configuration directory and whether an image has been selected.
- `up` starts missing services and replaces services whose image or configuration changed.
- `restart` bounces the services, waits for health, and prints the links again. It keeps the selected image, data,
  identities, and access links.
- `down` removes containers and keeps data.

Mutating commands lock the configuration directory and release the lock when the process exits.

A failed command names the Docker command and its exit status.

### Read your links again

`glowcap apps rooms deployment links` prints what `up` printed, without restarting anything. Keep its output as
private as the first print.

The image has no shell. Use the product commands to inspect it:

```sh
docker exec glowcap-rooms-directory /runtime/bin/glowcap apps rooms status
docker exec glowcap-rooms-session /runtime/bin/glowcap apps rooms session ready --file=/run/rooms-session/use.sturdyref
```

This form prints the operator capabilities alone:

```sh
docker exec glowcap-rooms-directory /runtime/bin/glowcap apps rooms capabilities
```

The shared session's use link and management link are independent
([the session service](../../operating.md#the-session-service)).

- To attach a browser, paste the use link into **Choose a session**, **Shared session**, and **Attach**, or under
  **Settings**, **Session**, and **Attach this browser**.
- To issue, pause, or revoke access, open **Session access** and hold the management link.
- Neither link appears in public HTML or an unauthenticated endpoint. Keep printed links, logs, secrets, and state
  private.

## Data and reset

With the state volumes retained, the directory locator and the shared session's use and management links
stay the same across restarts and container recreation. Saved grants, drafts, conversations, and session history
recover from those volumes. Browsers reload to establish fresh connections using their saved capabilities.

The directory lives in `glowcap-rooms-directory-state` and the shared session in `glowcap-rooms-session-state`. The
directory retains no private rooms or direct messages. The session's readiness file is recreated on each start, and
its authority stays in durable session state.

### Back up a stopped stack

Run this in the configuration directory printed by `deployment doctor`. Choose a backup directory outside that
configuration. The example creates one under your home.

Set the volume names to match your override. For the example bot, include `glowcap-rooms-bot-session-state` (session identity and grants),
`glowcap-rooms-bot-state` (settings, saved link and position), and `glowcap-rooms-bot-home` (agent files).
If the home is a bind mount, back up its host directory. The mounted home is separate from the bot state archive.

```sh
backup=$(mktemp -d "$HOME/rooms-backup.XXXXXXXX")
(
  set -eu
  umask 077
  test -d "$backup"
  glowcap apps rooms deployment down --dir "$PWD"
  set -- glowcap-rooms-directory-state glowcap-rooms-session-state
  # For the example bot, uncomment this line:
  # set -- "$@" glowcap-rooms-bot-session-state glowcap-rooms-bot-state glowcap-rooms-bot-home
  for volume in "$@"; do
    docker volume inspect "$volume" >/dev/null
    docker run --rm -v "$volume:/volume:ro" debian tar czf - -C /volume . > "$backup/$volume.tgz.partial"
    tar tzf "$backup/$volume.tgz.partial" >/dev/null
    mv "$backup/$volume.tgz.partial" "$backup/$volume.tgz"
  done
  tar czf "$backup/config.tgz.partial" -C "$PWD" .
  tar tzf "$backup/config.tgz.partial" >/dev/null
  mv "$backup/config.tgz.partial" "$backup/config.tgz"
)
```

Keep the backup private. The configuration archive includes the
override, image selection, Dockerfile, and files under `bot/` and `secrets/`, including sign-in files and bearer links.
Back up host paths mounted from elsewhere separately, preserving owners and permissions. Use a backup account that
can read those files. Once every archive succeeds, run the intended upgrade or restart with `deployment up --dir "$PWD"`.

### Keep a copy of the selected image

The configuration backup records the image ID. To recover a local-only build or recover after Docker discards its
cached image, save the image itself once. This optional archive can be large. Use the image selected in the stopped
stack's backup:

```sh
(
  set -eu
  umask 077
  saved_image=$(tar xOzf "$backup/config.tgz" ./image)
  docker image save "$saved_image" > "$backup/rooms-image.tar.partial"
  mv "$backup/rooms-image.tar.partial" "$backup/rooms-image.tar"
)
```

On the recovery host, load that archive before starting the stack. Check that Docker can resolve the saved ID:

```sh
saved_image=$(tar xOzf "$backup/config.tgz" ./image) &&
  docker image load --input "$backup/rooms-image.tar" &&
  docker image inspect "$saved_image" >/dev/null
```

An image must support the recovery host's architecture. The optional bot service rebuilds its own image from the
Dockerfile and package settings in your override.

### Restore a backup

Stop the stack before restoring it. Keep the current volumes and configuration until the restored services are healthy.
For each volume archive, restore into a fresh volume. This example prints the Docker volume name for the directory:

```sh
(
  set -eu
  archive="$backup/glowcap-rooms-directory-state.tgz"
  tar tzf "$archive" >/dev/null
  restored=$(docker volume create)
  docker run --rm -i -v "$restored:/volume" debian tar --numeric-owner -xzpf - -C /volume < "$archive"
  printf '%s\n' "$restored"
)
```

Extract the matching configuration into a new private directory. When the backup includes files owned by the
container user, extract as an account that can restore that owner.

```sh
restored_root=$(mktemp -d "$HOME/rooms-restored.XXXXXXXX") &&
  restored_config="$restored_root/config" && mkdir -m 700 "$restored_config" &&
  tar --numeric-owner -xzpf "$backup/config.tgz" -C "$restored_config"
```

The private parent protects the restored files even if the original configuration directory was shared.
Recover external bind mounts separately. In the restored `docker-compose.override.yml`, update their paths and
point each logical volume at its recovered Docker name. For example:

```yaml
volumes:
  directory-state:
    name: <Docker volume name printed above>
    external: true
```

Do the same for `session-state` and each configured bot volume. A home restored to a bind mount uses its host path
instead. Run `glowcap apps rooms deployment up --dir "$restored_config"` to use its saved image ID,
then check `deployment status --dir "$restored_config"`. The CLI refuses to reset volumes marked external.

`glowcap apps rooms deployment reset <unit>` describes what will be lost and confirms before destroying the chosen
volume and restarting. Reset ends by running `up` and printing new links, and every link the unit issued before
the reset stops working. Use `restart` to keep the existing identity and access links.

- Without a terminal, such as ssh with no tty or a script, pass `--yes`. At the terminal, type the full word `yes` to
  proceed. `no`, an empty answer, or end-of-input cancels, and other answers explain the choices and prompt again.
- Reset prepares configuration and a missing image before confirmation and needs no earlier `up`.
  It chooses its image as `up` does. An explicit `--image` or `--build` wins, then the prepared product on a Linux
  checkout, then, from an installed executable, the saved selection or the versioned release image. It names the image
  and its revision.
- Image preparation and Compose validation must succeed before services stop or volumes are removed.
- If a removal fails, the stack remains stopped and the error names the failed volume. Earlier removals in an `all` reset
  may already have completed. Inspect the data before restarting with `deployment up`.

| Unit        | Permanently removes                                                  |
| ----------- | -------------------------------------------------------------------- |
| `session`   | Shared session, identity, and session access links                   |
| `directory` | Directory identity, grants, room links, and kept public-room history |
| `all`       | Both volumes                                                         |

The [host guide](../../host.md) covers joining from agent skills and terminal peers.
[Operating Rooms](../../operating.md) covers capabilities, transport choices, relay admission, and the
[environment-only settings](../../operating.md#the-web-launcher) for TURN, ICE, and relay limits. Each setting goes in
the override under the service that reads it.

## Settings as variables

`glowcap apps rooms serve --help` lists the directory's settings, and `glowcap apps rooms session serve --help` the
session's. A directory option `--name` is the variable `GLOWCAP_ROOMS_NAME`, with dashes as underscores. A session
option is `GLOWCAP_ROOMS_SESSION_NAME`.

`--allow-origin` is `GLOWCAP_RELAY_ALLOW_ORIGINS`. `--http-port` and `--http-bind` are fixed by the managed file, and
the override's `ports` entry chooses the host port.
