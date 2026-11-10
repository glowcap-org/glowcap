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
lists and hosts rooms), and one shared session. The shared session is one Rooms session you and your friends can all
attach to, like a shared login. People who only open the page keep their own browser-local sessions and never need it.
`up` always starts the shared session.

Docker keeps the services running after the terminal closes and restarts them after a host reboot. The directory and
session run the same product CLI as a host installation.

Install the [complete host product](../../host.md) and Docker with Compose v2.17 or later on the deployment host.
`up` waits for health with `--wait-timeout`, which Compose added in that release. The product needs glibc 2.39 or
newer, and the [host guide's table](../../host.md#install) lists the targets.

Your user must be able to run Docker, either as root or through the `docker` group.

A published image needs no checkout, compiler, Python, or product source. Releases carry build provenance. Verify the
image before running it with
`gh attestation verify --repo glowcap-org/glowcap oci://ghcr.io/glowcap-org/glowcap-rooms:vVERSION`. That check needs
the `gh` command.

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
image to an immutable ID, writes the managed Compose file, creates the network, and waits for service health. Then it
prints, in order:

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

   For a public host, also list in `GLOWCAP_ROOMS_CAPABILITIES` only the capabilities you need. Every minted one prints
   in the logs and in the output of `up` ([the capability table](../../operating.md#operator-capabilities)).
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

1. Run `glowcap apps rooms deployment up --image ghcr.io/glowcap-org/glowcap-rooms:vNEW`.
2. Run `glowcap apps rooms deployment status` and check that every service is healthy.
3. To roll back, run `up --image` with the previous image. `up` printed it when it selected the new one.

Changing images does not reverse changes to the stored session format.

## Build and run your own version

A checkout prepares its own image with `./glowcap apps rooms deployment up`. The steps, the build environment, and the
image are in [Developing Rooms](../../developing.md#deploy-from-a-checkout).

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
- Startup prints the complete trace link after `ROOMS-TRACE-LISTENING` for other viewers.
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
  identities, and access links. `links` prints them without restarting anything.
- `down` removes containers and keeps data.

Mutating commands lock the configuration directory and release the lock when the process exits.

A failed command names the Docker command and its exit status.

### Read your links again

`glowcap apps rooms deployment links` prints what `up` printed, without restarting anything. That is the page
link, the operator capabilities, the directory locator, the browser revision, the shared session's use and
management links, and the trace link. Keep its output as private as the first print.

The image has no shell. Use the product commands to inspect it:

```sh
docker exec glowcap-rooms-directory /runtime/bin/glowcap apps rooms status
docker exec glowcap-rooms-session /runtime/bin/glowcap apps rooms session ready --file=/run/rooms-session/use.sturdyref
```

This form prints the operator capabilities alone:

```sh
docker exec glowcap-rooms-directory /runtime/bin/glowcap apps rooms capabilities
```

Deployment output prints two independent links to the shared session, the use link and the management link
([the session service](../../operating.md#the-session-service)). `glowcap apps rooms deployment links` prints them
again.

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

To back up a stopped stack:

1. Run `glowcap apps rooms deployment down`.
2. Copy each state volume as one unit. Docker copies a volume through any image that has `tar`:

   ```sh
   docker run --rm -v glowcap-rooms-directory-state:/volume -v "$PWD":/backup debian \
     tar czf /backup/directory-state.tgz -C /volume .
   docker run --rm -v glowcap-rooms-session-state:/volume -v "$PWD":/backup debian \
     tar czf /backup/session-state.tgz -C /volume .
   ```

3. Run `glowcap apps rooms deployment up`.

To restore the directory volume:

1. Run `glowcap apps rooms deployment down`.
2. Remove the volume and extract the backup into a new one:

   ```sh
   docker volume rm glowcap-rooms-directory-state
   docker run --rm -v glowcap-rooms-directory-state:/volume -v "$PWD":/backup debian tar xzf /backup/directory-state.tgz -C /volume
   ```

3. Run `glowcap apps rooms deployment up`.

Restore the session volume the same way. Prerelease application stores accept
only their current schema. Incompatible state requires an explicit reset.

`glowcap apps rooms deployment reset <unit>` describes what will be lost and confirms before destroying the chosen
volume and restarting. Reset ends by running `up` and printing new links, and every link the unit issued before
the reset stops working. Use `restart` to keep the existing identity and access links.

- Without a terminal, such as ssh with no tty or a script, pass `--yes`. At the terminal, type the full word `yes` to
  proceed. `no`, an empty answer, or end-of-input cancels, and other answers explain the choices and prompt again.
- Reset prepares configuration and a missing image before confirmation and needs no earlier `up`. <!-- status-allow: runtime state or operation ordering -->
  It chooses its image as `up` does. An explicit `--image` or `--build` wins, then the prepared product on a Linux
  checkout, then, from an installed executable, the saved selection or the versioned release image. It names the image
  and its revision.
- Image preparation and Compose validation must succeed before services stop or volumes are removed.
- If a removal fails, the stack remains stopped and the error names the failed volume. Earlier removals in an `all` reset <!-- status-allow: runtime state or operation ordering -->
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
