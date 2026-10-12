# Deploy Rooms

`glowcap apps rooms deployment` runs the web page, directory, one shared session, and PostgreSQL under Docker
Compose. Docker keeps them running after the terminal closes and restarts them after a host reboot. The directory and
session run the same product CLI as a host installation.

Install the [complete host product](../../host.md), then install Docker with Compose on the deployment host. A published
image needs no checkout, compiler, Python, or product source. glowcap has no release yet, so this repository does not
claim that any release image or archive has been published.

## Run it

The [work admission guide](../../../../docs/rooms/admission.md#deployment)
describes rate, accounting capacity and HTTP source overrides through this
deployment's existing configuration. Startup reports the effective profile.

For the product's default image:

```sh
glowcap apps rooms deployment up
```

For a tag, digest, or existing local image:

```sh
glowcap apps rooms deployment up --image ghcr.io/jimisaacs/glowcap-rooms:vVERSION
```

On its first run, the installed executable defaults to `ghcr.io/jimisaacs/glowcap-rooms:vVERSION`, where the version
comes from the installed CLI. The first `up` resolves the image to an immutable ID, writes the managed Compose file,
creates the network and database secret, waits for service health, and prints the directory and shared-session
capabilities. Open `http://127.0.0.1:8080`. Later `up` commands reuse the selected image. They do not silently download
an upgrade. Every `up` and `reset` names the image it selected or kept. An image built with `--build` carries its
product's source revision in the `org.opencontainers.image.revision` label. Selecting `--image` again is an explicit update. The previous image ID is recorded in `previous-image`.
Changing images does not reverse database or workspace schema changes.

Configuration defaults to `$XDG_STATE_HOME/glowcap/rooms-deployment`, or `$HOME/.local/state/glowcap/rooms-deployment`.
Every command accepts `--dir <configuration-directory>`. This selects configuration, not another stack: the deployment
has fixed container, network, and volume names and supports one stack per Docker daemon.

The managed `compose.yml` is refreshed from the installed product during `up` and `reset`. Operator settings belong in
`docker-compose.override.yml`, which is preserved. The example exposes only host loopback. To publish the page, add an
HTTPS proxy or tunnel and explicitly choose the host port or ingress network there. The iroh directory separately uses
authenticated discovery: a loopback HTTP port does not restrict membership in the directory.

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

Add this to the existing `docker-compose.override.yml` in your deployment configuration directory. Replace
`rooms.example` with the page's public host and include its port if needed. Run `glowcap apps rooms deployment up`
with a product/image that includes this option. The shared session dials the matching route through the Compose
default `ws://directory:8080/relay`. Browser connections still use public ingress. Only this exact endpoint is
redirected, including its scheme, host, port, path and fixed query. Other deployments' relay hints keep their routes.

Both routes must reach the same registry. This alias does not give outside native peers access to a protected relay.
It changes no browser login policy, peer identity or Noise encryption. A standalone session accepts the same setting
as `--relay-alias-url`, together with `--relay-url` naming the internal endpoint.

If the database volume already exists, its original `secrets/storage-db-password` must be present in this configuration
directory. Use `--dir` to select the directory that already owns it, or restore the secret from backup. A missing
password never authorizes deleting or resetting data.

To move a deployment's configuration, copy its original password and operator override into the new directory before
running `up` or `reset`. Keep the password file mode `0600` and its `secrets` directory mode `0700`. Review relative
paths in the override because they resolve from the configuration directory. Keep the originals until the deployment is
healthy, and resolve existing destination files explicitly rather than overwriting them. The CLI does not discover or
copy configuration from other directories.

## Build and run your own version

On a Linux contributor host, run:

```sh
./glowcap apps rooms deployment up
```

Each checkout `up` prepares the current source with the `rooms-release` preset, including uncommitted edits. The preset
calls the shared `rooms-build` graph with ReleaseSafe and baseline CPU settings. The launcher uses the matching
devcontainer when available. It then builds an immutable image from the complete product, without a published release
image or a separate build command. Checkout `reset` uses the same preparation before asking for confirmation.
Explicit `--image` or `--build` sources take precedence and skip source preparation when the host product exists.
An installed `glowcap` keeps its selected image across ordinary `up` calls and never builds application source.

Deployment inspection, `restart`, and session commands run the prepared product without invoking build tools.
A stopped development container does not block them. Preparation progress goes to stderr, and a preparation failure
stops before the deployment command starts. Install with `./glowcap install` to keep a
verified generation outside the checkout and independent of later development builds.

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

The Dockerfile copies the complete product into the image. It mounts no checkout, compiler output, or browser source at
runtime. A rebuild therefore cannot replace executables underneath the daemon. The distroless Debian base supplies
glibc, the GCC runtime, and certificates, without a shell or package manager. Product packages contain one runtime
soname library, not the C SDK's static archives, headers, and linker aliases. Directory and session containers share the
same image layers.

The repository defines image and archive workflow paths for Linux x86-64, ARM64, and both macOS architectures. A
workflow definition is not evidence that a particular run succeeded or that an artifact was published. Dependency pins
live in [pins.sh](../../../../.devcontainer/pins.sh).

## Inspect and stop

```sh
glowcap apps rooms deployment doctor
glowcap apps rooms deployment status
glowcap apps rooms deployment logs directory
glowcap apps rooms deployment trace
glowcap apps rooms deployment restart
glowcap apps rooms deployment down
```

`trace` follows the protocol feed through the installed container runtime.
It prints replay, then live events. Add `--json` for complete records. Service
logs and protocol traces are separate streams. Startup prints the complete
`ROOMS-TRACE-LISTENING` capability for other viewers. The feed contains the
directory's events and events from session producers configured to publish
to it. It cannot see traffic that stays with another peer.

For browser/session publication and remote viewers, set the directory's
`GLOWCAP_ROOMS_TRACE_CONNECT` and `GLOWCAP_ROOMS_TRACE_PUBLISH` in your override
to its public WebSocket routes. The example override shows `/trace/captp` and
`/publish`. Then run `deployment up` and paste its complete trace capability
into **Settings**, **Holdings**, **Protocol visualizer**. Enable publication
on the Visualizer page. An attached shared session publishes from its server
process. `deployment trace` receives those events alongside directory events.

`doctor` is read-only. `up` starts missing services and replaces services whose image or configuration changed.
`restart` restarts the selected deployment, waits for health, and prints its capabilities. It keeps the selected image,
data, identities, and access links. `down` removes containers and keeps data. Mutating commands lock the configuration directory and
release the lock when the process exits. `doctor` reports the selected configuration directory, whether an image has
been selected, and whether the database password file is present. It does not print the password or test database
authentication.

Docker actions stream stdout and stderr directly. Internal queries capture their stdout for parsing while forwarding
stderr immediately, including warnings from successful commands. Failed queries also show their captured stdout on
stderr. Failures identify the command and its exit status or signal. Diagnostics printed before a timeout remain
visible.

The image has no shell. Use the product commands to inspect it:

```sh
docker exec glowcap-rooms-directory /runtime/bin/glowcap apps rooms status
docker exec glowcap-rooms-directory /runtime/bin/glowcap apps rooms directory capabilities
docker exec glowcap-rooms-session /runtime/bin/glowcap apps rooms session ready --file=/run/rooms-session/admin.sturdyref
```

Deployment output prints two independent session capabilities. Paste the workspace capability into **Choose a
session**, **Shared session**, and **Attach**, or into the same form under **Settings**, **Session**. To issue,
pause, or revoke access, open **Session access** and hold the management capability. Neither capability is placed
in public HTML or fetched from an unauthenticated endpoint. This is one owner session, not an account system.
Keep printed capabilities, logs, secrets, and state private.

## Data and reset

With the state volumes retained, the deployed directory locator and shared-session use and management capabilities
stay the same across restarts and container recreation. Saved grants, drafts, conversations, and session history
recover from those volumes. Browsers reload to establish fresh connections using their saved capabilities.

The directory identity and grants live in `glowcap-rooms-directory-state`. The shared workspace lives in
`glowcap-rooms-session-state`. Public-room history lives in `glowcap-rooms-postgres`. Private rooms and direct messages
are not retained by the directory. The session's readiness mirror is temporary and is recreated on each start. Its
authority remains in durable session state.

Back up PostgreSQL while it runs:

```sh
docker exec glowcap-rooms-postgres pg_dump -U rooms -Fc rooms > rooms.dump
```

Keep the database secret with its backup. Back up stopped directory/session volumes separately. Do not change PostgreSQL
major versions in place: dump with the old service and restore into the new major's empty database. Prerelease
application stores accept only their current schema. Incompatible state requires an explicit reset.

`glowcap apps rooms deployment reset <unit>` describes what will be lost and confirms before destroying the chosen
volume and restarting. Use `restart` to keep the existing identity and access links. `--yes`
supplies that confirmation for automation. At the terminal, type the full word `yes` to proceed. `no`, an empty answer,
or end-of-input cancels. Other answers explain the choices and prompt again. Reset prepares configuration and a missing
image before confirmation. It does not require a successful `up` first. It chooses its image by the same rule as `up`:
an explicit `--image` or `--build`, else the prepared product on a Linux checkout, else, from an installed executable,
the saved selection or the versioned release image. It names the image it selected or kept and that image's revision. Image preparation and Compose validation
must succeed before services stop or volumes are removed. The original password is still required when a database volume
exists, and operator overrides must be copied when moving configuration. Reset does not discover configuration in other
directories or bypass the missing-secret guard. If a removal fails, the stack remains stopped and the error names the
failed volume. Earlier removals in an `all` reset may already have completed. Inspect the data before restarting with
`deployment up`.

| Unit      | Permanently removes                               |
| --------- | ------------------------------------------------- |
| `session` | Shared workspace, identity, and session authority |
| `state`   | Directory identity, grants, and issued room links |
| `storage` | Kept public-room history                          |
| `all`     | All three volumes                                 |

The [host guide](../../host.md) covers joining from skills and terminal peers. [Operating Rooms](../../operating.md)
covers capabilities, transport choices, relay admission, and TURN settings. Keep machine settings in the override.
