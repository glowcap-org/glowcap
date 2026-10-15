---
type: static
description: How to run Rooms under Docker Compose on a deployment host.
audience: human
sources:
  - resource: /apps/rooms/web/deploy/
  - resource: /cli/app/rooms/deployment/
---

# Deploy Rooms

`glowcap apps rooms deployment` runs the web page, directory, and one shared session under Docker Compose. Docker keeps
them running after the terminal closes and restarts them after a host reboot. The directory and session run the same
product CLI as a host installation.

Install the [complete host product](../../host.md) and Docker with Compose on the deployment host. A published image
needs no checkout, compiler, Python, or product source.

## Run it

For the product's default image:

```sh
glowcap apps rooms deployment up
```

For a tag, digest, or existing local image:

```sh
glowcap apps rooms deployment up --image ghcr.io/jimisaacs/glowcap-rooms:vVERSION
```

An installed executable defaults to `ghcr.io/jimisaacs/glowcap-rooms:vVERSION`, with the version from the installed
CLI. The first `up` resolves the image to an immutable ID, writes the managed Compose file, creates the network, waits
for service health, and prints the directory and shared-session capabilities. Open `http://127.0.0.1:8080`. The
[work admission guide](../../../../docs/rooms/admission.md#deployment) covers rate, capacity and HTTP source overrides
for this deployment, and startup reports the effective profile.

- Later `up` commands reuse the selected image and never silently download an upgrade. Every `up` and `reset` names
  the image it selected or kept.
- Passing `--image` again updates the image and records the previous image ID in `previous-image`. Changing images does
  not reverse workspace schema changes.
- An image built with `--build` carries its product's source revision in the `org.opencontainers.image.revision`
  label.

Configuration defaults to `$XDG_STATE_HOME/glowcap/rooms-deployment`, or `$HOME/.local/state/glowcap/rooms-deployment`.
Every command accepts `--dir <configuration-directory>`, which selects configuration and not another stack: the
deployment has fixed container, network, and volume names and supports one stack per Docker daemon.

The managed `compose.yml` is refreshed from the installed product during `up` and `reset`. Operator settings belong in
`docker-compose.override.yml`, which is preserved. The example exposes only host loopback. To publish the page, add an
HTTPS proxy or tunnel and choose the host port or ingress network there. The iroh directory uses authenticated
discovery separately, so a loopback HTTP port does not restrict membership in the directory.

### A relay behind a browser login

When public ingress requires a login, such as Cloudflare Access, a shared-session server cannot use the browser's
login cookie. Its DM dial follows the other browser's advertised `/relay` route and receives a login redirect.
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
- Only this exact endpoint is redirected, including scheme, host, port, path and fixed query. Other deployments' relay
  hints keep their routes.
- Both routes must reach the same registry.
- The alias gives outside non-browser peers no access to a protected relay and changes no browser login policy, peer identity
  or Noise encryption.
- A standalone session accepts the same setting as `--relay-alias-url`, together with `--relay-url` naming the
  internal endpoint.
- A standalone session dials WebRTC-only browsers when started with `--dial-transports=webrtc`. The Compose session
  keeps the relay route, which every browser can reach.

To move a deployment's configuration, copy its operator override into the new directory before running `up` or
`reset`. Relative paths in the override resolve from the configuration directory, so review them. Keep the originals
until the deployment is healthy. The CLI does not discover or copy configuration from other directories.

## Build and run your own version

On a Linux contributor host, run:

```sh
./glowcap apps rooms deployment up
```

Each checkout `up` prepares the current source, including uncommitted edits, with the `rooms-release` preset: the shared
`rooms-build` graph with ReleaseSafe and baseline CPU settings, in the matching devcontainer when available. It then
builds an immutable image from the complete product.

- Checkout `reset` uses the same preparation before asking for confirmation.
- Explicit `--image` or `--build` sources take precedence and skip source preparation when the host product exists.
- An installed `glowcap` keeps its selected image across ordinary `up` calls and never builds application source.
- Deployment inspection, `restart`, and session commands run the prepared product without build tools, so a stopped
  development container does not block them.
- Preparation progress goes to stderr, and a preparation failure stops before the deployment command starts.

Install with `./glowcap install` to keep a verified generation outside the checkout and independent of later
development builds.

To prepare a Linux product separately, build inside the devcontainer:

```sh
zig build rooms-release
```

Then, on the Docker host with glowcap installed:

```sh
glowcap apps rooms deployment up --build /path/to/checkout/zig-out/product
```

On macOS, use a macOS host installation to control Docker, and a Linux product from the devcontainer as the image build
context. A macOS executable cannot run inside a Linux image.

The Dockerfile copies the complete product into the image and mounts no checkout, compiler output, or browser source at
runtime, so a rebuild cannot replace executables underneath the daemon. The distroless Debian base supplies glibc, the
GCC runtime, and certificates, without a shell or package manager. Directory and session containers share the same image
layers. Dependency pins live in [pins.sh](../../../../.devcontainer/pins.sh).

## Inspect and stop

```sh
glowcap apps rooms deployment doctor
glowcap apps rooms deployment status
glowcap apps rooms deployment logs directory
glowcap apps rooms deployment trace
glowcap apps rooms deployment restart
glowcap apps rooms deployment down
```

`trace` follows the protocol feed through the installed container runtime. It prints replay, then live events, and
`--json` gives complete records.

- Service logs and protocol traces are separate streams.
- Startup prints the complete `ROOMS-TRACE-LISTENING` capability for other viewers.
- The feed holds the directory's events and events from session producers configured to publish to it. It cannot see
  traffic that stays with another peer.

For browser and session publication and for remote viewers:

1. Set the directory's `GLOWCAP_ROOMS_TRACE_CONNECT` and `GLOWCAP_ROOMS_TRACE_PUBLISH` in your override to its public
   WebSocket routes. The example override shows `/trace/captp` and `/publish`.
2. Run `deployment up` and paste its complete trace capability into **Settings**, **Holdings**, **Live trace**.
3. Enable publication on the **Visualizer** page.

An attached shared session publishes from its server process, so `deployment trace` receives those events too.

- `doctor` is read-only. It reports the selected configuration directory and whether an image has been selected.
- `up` starts missing services and replaces services whose image or configuration changed.
- `restart` restarts the selected deployment, waits for health, and prints its capabilities. It keeps the selected
  image, data, identities, and access links.
- `down` removes containers and keeps data.

Mutating commands lock the configuration directory and release the lock when the process exits.

Docker actions stream stdout and stderr directly. Internal queries capture stdout for parsing and forward stderr
immediately, and a failed query also shows its captured stdout. Failures identify the command and its exit status or
signal.

The image has no shell. Use the product commands to inspect it:

```sh
docker exec glowcap-rooms-directory /runtime/bin/glowcap apps rooms status
docker exec glowcap-rooms-directory /runtime/bin/glowcap apps rooms directory capabilities
docker exec glowcap-rooms-session /runtime/bin/glowcap apps rooms session ready --file=/run/rooms-session/admin.sturdyref
```

Deployment output prints two independent session capabilities. Paste the workspace capability into **Choose a
session**, **Shared session**, and **Attach**, or into the same form under **Settings**, **Session**. To issue, pause,
or revoke access, open **Session access** and hold the management capability. Neither capability appears in public HTML
or an unauthenticated endpoint. This is one owner session, not an account system. Keep printed capabilities, logs,
secrets, and state private.

## Data and reset

With the state volumes retained, the deployed directory locator and shared-session use and management capabilities
stay the same across restarts and container recreation. Saved grants, drafts, conversations, and session history
recover from those volumes. Browsers reload to establish fresh connections using their saved capabilities.

The directory identity, grants, and kept public-room history live in `glowcap-rooms-directory-state`. The shared
workspace lives in `glowcap-rooms-session-state`. The directory retains no private rooms or direct messages. The
session's readiness mirror is recreated on each start, and its authority stays in durable session state.

Back up a stopped stack. Run `glowcap apps rooms deployment down`, copy each state volume as one unit, then `up`.
Prerelease application stores accept only their current schema. Incompatible state requires an explicit reset.

`glowcap apps rooms deployment reset <unit>` describes what will be lost and confirms before destroying the chosen
volume and restarting. Use `restart` to keep the existing identity and access links.

- `--yes` confirms for automation. At the terminal, type the full word `yes` to proceed. `no`, an empty answer, or
  end-of-input cancels, and other answers explain the choices and prompt again.
- Reset prepares configuration and a missing image before confirmation and needs no earlier `up`. It chooses its image
  as `up` does: an explicit `--image` or `--build`, else the prepared product on a Linux checkout, else, from an
  installed executable, the saved selection or the versioned release image. It names the image and its revision.
- Image preparation and Compose validation must succeed before services stop or volumes are removed.
- If a removal fails, the stack remains stopped and the error names the failed volume. Earlier removals in an `all`
  reset may already have completed. Inspect the data before restarting with `deployment up`.

| Unit      | Permanently removes                                                  |
| --------- | -------------------------------------------------------------------- |
| `session` | Shared workspace, identity, and session authority                    |
| `state`   | Directory identity, grants, room links, and kept public-room history |
| `all`     | Both volumes                                                         |

The [host guide](../../host.md) covers joining from skills and terminal peers. [Operating Rooms](../../operating.md)
covers capabilities, transport choices, relay admission, and TURN settings. Keep machine settings in the override.
