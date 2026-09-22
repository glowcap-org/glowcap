# Deploy Rooms

`glowcap apps rooms deployment` runs the browser front, directory, one shared
session, and PostgreSQL under Docker Compose. Docker keeps them running after
the terminal closes and restarts them after a host reboot. The directory and
session run the same product CLI as a host installation.

Install the [complete host product](../../host.md), then install Docker with
Compose on the deployment host. A published image needs no checkout, compiler,
Python, or product source. The repository is prerelease, so this repository does
not claim that a release image or archive has been published.

## Run it

For the product's default image:

```sh
glowcap apps rooms deployment up
```

For a tag, digest, or existing local image:

```sh
glowcap apps rooms deployment up --image ghcr.io/jimisaacs/glowcap-rooms:vVERSION
```

On its first run, the installed executable defaults to
`ghcr.io/jimisaacs/glowcap-rooms:vVERSION`, where the version comes from the
installed CLI. The first `up` resolves the image to an immutable ID, writes the
managed Compose file, creates the network and database secret, waits for service health,
and prints the directory and shared-session capabilities. Open
`http://127.0.0.1:8080`. Later `up` commands reuse the selected image; they do
not silently download an upgrade. Selecting `--image` again is an explicit
update. The previous image ID is recorded in `previous-image`; changing images
does not reverse database or workspace schema changes.

Configuration defaults to `$XDG_STATE_HOME/glowcap/rooms-deployment`, or
`$HOME/.local/state/glowcap/rooms-deployment`. Every command accepts
`--dir <configuration-directory>`. This selects configuration, not another
stack: the deployment has fixed container, network, and volume names and
supports one stack per Docker daemon.

The managed `compose.yml` is refreshed from the installed product during `up`
and `reset`.
Operator settings belong in `docker-compose.override.yml`, which is preserved.
The example exposes only host loopback. To publish the page, add an HTTPS
proxy or tunnel and explicitly choose the host port or ingress network there.
The iroh directory separately uses authenticated discovery: a loopback HTTP
port does not restrict membership in the directory.

If the database volume already exists, its original
`secrets/storage-db-password` must be present in this configuration directory.
Use `--dir` to select the directory that already owns it, or restore the secret
from backup. A missing password never authorizes deleting or resetting data.

To move a deployment's configuration, copy its original password and operator
override into the new directory before running `up` or `reset`. Keep the password file
mode `0600` and its `secrets` directory mode `0700`. Review relative paths in
the override because they resolve from the configuration directory. Keep the
originals until the deployment is healthy, and resolve existing destination
files explicitly rather than overwriting them. The CLI does not discover or
migrate configuration from other directories.

## Build and run your own version

On a Linux contributor host, run:

```sh
./glowcap apps rooms deployment up
```

The launcher bootstraps a missing product through the devcontainer when
available. After source changes, explicitly run `zig build rooms-build` in the
build environment first. Without `--image` or `--build`, each checkout `up` builds an immutable
image from that prepared product. It needs no published release image.
Explicit image or build flags take precedence. An installed `glowcap` keeps its
selected image across ordinary `up` calls and never builds application source.

Once prepared, the checkout product runs without invoking build tools; a
stopped development container does not block deployment status or session
commands. Bootstrap progress goes to stderr. Install with `./glowcap install`
to keep a verified generation outside the checkout and independent of later
development builds.

To prepare a Linux product separately, build inside the devcontainer:

```sh
zig build rooms-deploy-prep -Doptimize=ReleaseSafe -Dcpu=baseline
```

Then, on the Docker host with glowcap installed:

```sh
glowcap apps rooms deployment up --build /path/to/checkout/zig-out/product
```

On macOS, use a macOS host installation to control Docker, and a Linux product
from the devcontainer as the image build context. A macOS executable cannot
run inside a Linux image.

The Dockerfile copies the complete product into the image. It mounts no
checkout, compiler output, or browser source at runtime. A rebuild therefore
cannot replace executables underneath the daemon. The distroless Debian base
supplies glibc, the GCC runtime, and certificates, without a shell or package
manager. Product packages contain one runtime soname library, not the C SDK's
static archives, headers, and linker aliases. Directory and session containers
share the same image layers.

The repository defines image and archive workflow paths for Linux x86-64, ARM64,
and both macOS architectures. A workflow definition is not evidence that a
particular run succeeded or that an artifact was published. Dependency pins live in
[pins.sh](../../../../.devcontainer/pins.sh).

## Inspect and stop

```sh
glowcap apps rooms deployment doctor
glowcap apps rooms deployment status
glowcap apps rooms deployment logs directory
glowcap apps rooms deployment down
```

`doctor` is read-only. `down` stops containers and keeps data. Mutating commands
lock the configuration directory and release the lock when the process exits.
`doctor` reports the selected configuration directory, whether an image has
been selected, and whether the database password file is present. It does not
print the password or test database authentication.

Docker actions stream stdout and stderr directly. Internal queries capture
their stdout for parsing while forwarding stderr immediately, including
warnings from successful commands. Failed queries also show their captured
stdout on stderr. Failures identify the command and its exit status or signal;
diagnostics printed before a timeout remain visible.

The image has no shell. Use the product commands to inspect it:

```sh
docker exec glowcap-rooms-directory /runtime/bin/glowcap apps rooms status
docker exec glowcap-rooms-directory /runtime/bin/glowcap apps rooms directory capabilities
docker exec glowcap-rooms-session /runtime/bin/glowcap apps rooms session ready --file=/run/rooms-session/admin.sturdyref
```

The session administrator capability controls the whole shared workspace.
Paste it into **Choose a session**, **Shared session**, and **Attach**, or into
the same form under **Settings**, **Session**. It is never placed in public HTML or fetched from
an unauthenticated endpoint. This is one owner session, not an account system.
Keep printed capabilities, logs, secrets, and state private.

## Data and reset

The directory identity and grants live in `glowcap-rooms-directory-state`.
The shared workspace lives in `glowcap-rooms-session-state`. Public-room
history lives in `glowcap-rooms-postgres`; private rooms and direct messages
are not retained by the directory. The session's readiness mirror is temporary
and is recreated on each start. Its authority remains in durable session state.

Back up PostgreSQL while it runs:

```sh
docker exec glowcap-rooms-postgres pg_dump -U rooms -Fc rooms > rooms.dump
```

Keep the database secret with its backup. Back up stopped directory/session
volumes separately. Do not change PostgreSQL major versions in place: dump
with the old service and restore into the new major's empty database.
Prerelease application stores accept their current schema and provide no
automatic migration.

`glowcap apps rooms deployment reset <unit>` confirms before destroying the
chosen volume and restarting. `--yes` supplies that confirmation for automation.
At the terminal, type the full word `yes` to proceed. `no`, an empty answer, or
end-of-input cancels; other answers explain the choices and prompt again.
Reset prepares configuration and a missing image before confirmation; it does
not require a successful `up` first. It keeps an existing image selection unless
you supply `--image` or `--build`. With no saved selection, it uses the same
defaults as `up`: the prepared product on a Linux checkout, or the versioned
release image from an installed executable. Image preparation and Compose
validation must succeed before services stop or volumes are removed.
The original password is still required when a database volume exists, and
operator overrides must be copied when moving configuration. Reset does not
discover configuration in other directories or bypass the missing-secret guard.
If a removal fails, the stack remains stopped and the error names the failed
volume. Earlier removals in an `all` reset may already have completed; inspect
the data before restarting with `deployment up`.

| Unit | Permanently removes |
| --- | --- |
| `session` | Shared workspace, identity, and session authority |
| `state` | Directory identity, grants, and issued room links |
| `storage` | Kept public-room history |
| `all` | All three volumes |

The [host guide](../../host.md) covers joining from skills and terminal peers.
[Operating Rooms](../../operating.md) covers capabilities, transport choices,
relay admission, and TURN settings. Keep machine settings in the override.
