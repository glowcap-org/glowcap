# Deploy the Rooms browser app

This Compose stack runs the Rooms browser UI, an iroh room server, and one
durable shared workspace session as native Rust services. The tracked base
publishes no host port. An ignored `docker-compose.override.yml` says how this
machine reaches the page, so a host's ports and network names never enter the
repository.

Build artifacts stay outside the image. Each container mounts `zig-out` at
`/runtime` read-only, including native executables, their shared libraries,
and the complete browser artifact. Serving needs no source tree or compiler.

This is the source distribution described in the Rooms
[prerelease scope](../../README.md#prerelease-distribution), not a standalone
application image. Check out the announced commit and run `rooms-deploy-prep`
from that same checkout before recreating the containers.

## Before you start

You need:

- the glowcap devcontainer, with Zig, Deno, and Cargo;
- Docker Compose.

## Run it

From the repository root, build everything the container mounts:

```sh
zig build rooms-deploy-prep
```

Create the external network shared with the glowcap devcontainer if it does not
already exist:

```sh
docker network create rooms-net
```

If Docker reports that a network already exists, continue.

Create the local override from its tracked example, then bring the deployment
up:

```sh
cd apps/rooms/web/deploy
cp docker-compose.override.yml.example docker-compose.override.yml
./up.sh
```

The example override publishes the page on this host's loopback. Its comments
carry the other way in: joining the Docker network that a reverse proxy or
tunnel container already runs on. That neighbor reaches
`http://glowcap-rooms:8000` over the network and needs no published port. A
host may use either way, or both.

`./up.sh` is the front door. It builds, recreates both containers, waits for
each to serve, and prints one handoff block with the room locator, browser
interface build, and every capability. The same short Git revision appears at
the bottom of Help in the browser. Underneath it, `./compose.sh` is the front
for everything else. It always selects `docker-compose.yml`, explicitly adds
the ignored override when it exists, and disables Compose's implicit `.env`
loading, so operator values come from the exported process environment unless
an explicit `--env-file` is passed:

```sh
./compose.sh logs -f rooms
```

Open `http://127.0.0.1:8000`. The `glowcap-rooms` container serves the browser
page, its same-origin `/relay` WebSocket, and `GET /locator`. The Compose port
mapping names host loopback explicitly, so no other machine reaches this HTTP
surface through a host LAN address. Reaching further than this machine is the
separate, deliberate choice of attaching a site network above. Containers on
`rooms-net` reach the same service as `http://glowcap-rooms:8000` (or the
`rooms` service alias).

The application still listens on port 8000 inside its container. Docker's port
mapping, not a second application bind setting, is what makes that container
port available as host localhost. Change the host side only when port 8000 is
already occupied, for example `127.0.0.1:18000:8000`, then open
`http://127.0.0.1:18000`.

`./compose.sh ps` shows whether it is *serving*, which is not the same as
running: the health probe asks `/locator`, and that answers only once the page
is being served and the room server it supervises has announced itself. A
container stuck at `starting` or turning `unhealthy` is telling you the room
server is not coming up, and `./compose.sh logs rooms` says why.

After pulling new work, `./up.sh` refuses a dirty checkout or a completed
deployment revision from another commit. Run `zig build rooms-deploy-prep`
again in the devcontainer. Its revision is written only after the shared
libraries, iroh transport, Wasm Host, browser bundle, and native session peer
all finish, so a
failed or partial preparation cannot authorize the new checkout.

## Your shared workspace

The `glowcap-rooms-session` container owns one durable user workspace. Its
identity, intended rooms and direct conversations, drafts, shared connection
and retention choices, retained capabilities, member-owned history, and the
passwords answered to bridge forms all live in the separate
`rooms-session-state` volume. Restarting the stack republishes the
same session capability and reconciles that saved intent; unreachable peers
remain visible as disconnected until they return.

Run `./up.sh`. After both peers are ready, its single capability handoff block
includes a **shared-session administrator capability**. Open the page and paste
that sturdyref into **Choose a session**, then **Shared session**, then press **Attach**.
A new empty session adopts the workspace saved in that browser; otherwise its
durable workspace becomes current.

If this browser already has a local workspace open, the same Attach form lives
under **Settings**, then **Session**. Subsequent browsers attach and become views of
the same durable workspace.

The printed sturdyref is bearer authority over the whole session. Anyone who
has it can act as that user, including changing retained operator capabilities.
The page therefore does not fetch it from a public endpoint and Compose does
not inject it into HTML. Read it again from the operator side with:

```sh
./compose.sh exec -T rooms-session \
  /runtime/bin/rooms-session --check-ready=/run/rooms-session/admin.sturdyref
```

That same command is the container's healthcheck: the native peer reads its
own readiness mirror, prints the sturdyref when the file holds exactly one, and
exits nonzero otherwise, so the session container runs no second runtime.

That readiness mirror lives on a mode-0700 tmpfs, not in the durable session
volume. Every container start therefore begins without a stale ready marker;
the session writes the mirror after restoring grants, publishing its listener,
and scheduling workspace reconciliation. Network reachability is recoverable
workspace state, not process readiness. The authority itself remains durable
because its identity and publication entropy live in `rooms-session-state`.

This is one deliberate owner session, not an account system and not an ambient
session for every site visitor. A future per-user service would need to own
bounded provisioning, recovery, quotas, and durable revocable grants; adding a
username form or an unauthenticated `POST /sessions` would not supply those
authority boundaries.

## Room history

`GLOWCAP_ROOMS_HISTORY: "1"` is on in `docker-compose.yml` (the same as
starting with `--history`): each listed room keeps its last lines in the
`rooms-state` volume, serving them to members who join later. Private rooms
and direct messages never record server-side. Comment the line out to run
without retention.

## Operations capabilities

Every operator capability is on in `docker-compose.yml`: inspect
(`GLOWCAP_ROOMS_DIAGNOSTICS`), listener administration
(`GLOWCAP_ROOMS_ADMIN_LISTENERS`), room-steward operation
(`GLOWCAP_ROOMS_OPERATOR`), directory peering
(`GLOWCAP_ROOMS_PEERING`), the live timeline (`GLOWCAP_ROOMS_VIZ`, serving
port 9300 unless `GLOWCAP_ROOMS_VIZ_PORT` says otherwise), and the IRC
gateway (`GLOWCAP_ROOMS_IRC`). Each is the same as the matching `--flag` on a
local start; comment a line out to withhold that authority from the
deployment. The viz endpoint requires its capability of every socket, so
reaching the port neither reads the timeline nor writes traces into it.

`./up.sh` is the one-step restart: it runs
`compose.sh up -d --build --force-recreate`, waits for the room server and
shared session to become ready, and prints one handoff block containing the
room's operator capabilities, room locator, and session administrator
capability.

A build that replaced a prerelease state schema refuses the files a volume
holds from the previous one, says which schema wrote them, and keeps
restarting until the operator resets. The session's durable files are one
custody unit, so reset the whole volume rather than one file:

```sh
./compose.sh down
docker volume ls --filter name=rooms-session-state   # shows the project-prefixed name
docker volume rm <that name>
./up.sh
```

The same applies to `rooms-state`. To start the whole deployment fresh,
`./compose.sh down -v` removes every volume the stack declares, state and
caches alike, and `./up.sh` rebuilds from nothing. Resetting the session
volume mints a new session identity, so the page's shared session must be
attached again from the new handoff block.

Each capability's swiss number is minted once and persists in the
`rooms-state` volume, so a restart republishes the same one. Three ways to
read them, any time:

```sh
# The capability printer reads the state volume and prints the token lines:
./compose.sh exec rooms /runtime/bin/rooms-server --capabilities

# The startup logs carry the same lines:
./compose.sh logs rooms | grep 'ROOMS-'

# Or read a single one straight from the volume:
./compose.sh exec rooms cat /state/diagnostics
```

Whoever can read the room volume or logs holds those directory-operation
capabilities, which is the whole of their access control: paste a swiss number
when flipping its toggle on under Settings, Holdings. The shared
session administrator is separate authority in `rooms-session-state` and goes
through the Session form described above.

## Connect a Rooms peer

The glowcap devcontainer shares `rooms-net` with the deployed app. From the
repository root inside that container:

```sh
zig build
export PATH="$PWD/zig-out/bin:$PATH"
glowcap app rooms-peer start \
  --nick Alice --dir /tmp/rooms-peer-alice --room general
```

The peer fetches `http://glowcap-rooms:8000/locator` by default, then dials the
returned iroh locator. The Docker service alias `rooms` works too.

Run `glowcap app rooms-peer --help` for the remaining peer commands. After a
Rooms server source change, rebuild the mounted artifacts inside the
devcontainer:

```sh
zig build rooms-deploy-prep
```

Then restart the service from a shell with Docker access, at the repository
root:

```sh
apps/rooms/web/deploy/compose.sh restart rooms
```

Browser-to-browser WebRTC uses the application's public STUN default. Set
`GLOWCAP_ROOMS_ICE_SERVERS` in Compose to a comma-separated STUN list, or to an
empty string for host candidates only. The server validates the value at
startup and serves that exact configuration to both browser halves.

Symmetric NATs and restrictive firewalls need a TURN candidate. Rooms keeps the
long-lived credential authority on the server and publishes only short-lived
username/password rows to browsers. Configure any HTTPS issuer that answers
the bounded ICE-server credential document:

```sh
export GLOWCAP_ROOMS_TURN_CREDENTIALS_URL="https://turn.example/credentials"
export GLOWCAP_ROOMS_TURN_BEARER_TOKEN="<issuer bearer token>"
export GLOWCAP_ROOMS_TURN_TTL_SECONDS=86400
./compose.sh up -d
```

The URL and token must be present together, the issuer must use HTTPS, and the
TTL is bounded to 5 minutes–48 hours. Each new WebRTC connection asks `/ice`
for fresh credentials, so a tab left open does not age out of TURN reachability.
If the issuer is configured but unavailable, `/ice` answers 503 rather than
quietly degrading to STUN-only. This TURN relay remains below WebRTC's DTLS
channel; it is not Rooms' separately selectable Noise-sealed relay DM transport.

## How the container is assembled

The image uses the same pinned glibc-based Debian base as the supported
devcontainer, with system CA certificates. It runs the installed Rust
executables; the iroh sidecar is already linked into
`libglowcap_net_transport_iroh.so`.

`zig build rooms-deploy-prep` creates:

- the native Rooms executables and glowcap shared libraries;
- the iroh transport library;
- `zig-out/rooms-web/current`, an atomic pointer to one immutable browser
  generation containing its page, minified scripts, styles, fonts and Wasm Host;
- `zig-out/rooms-deployment.version`, written last with the checkout revision
  and the selected browser generation's source identity.

`up.sh` requires a clean checkout and checks both identities before recreating
either service. The native web front loads the selected generation as a whole;
`--prepared` never invokes a compiler or inspects a source checkout. Readiness
checks both the directory and browser assets through `rooms-web --check-ready`.

For a separate browser artifact, run `rooms-web --prepare=<output-directory>`
from the repository root, then serve `<output-directory>/current` with
`--prepared --assets=<output-directory>/current`. Preparation uses Deno only as
the browser compiler. The source identity covers its configuration, source
files, fonts and Wasm bytes. An unchanged graph reuses its validated generation;
a failed build leaves the previous publication in place. Generated generations
remain under the output directory until that build output is cleaned.

Both development refresh and deployment preparation use the same minified
compiler contract. The UI revision identifies the actual source digest, while
the separate deployment marker ties all mounted artifacts to the checkout.

## Network and transport reference

The base service joins one external Docker network, `rooms-net`, which connects
the deployment to the glowcap devcontainer. The ignored local override adds
whatever else this host needs:

- `127.0.0.1:8000` reaches the browser page and `/relay` from the Docker host.
- A site network puts the page beside a reverse proxy or tunnel container, and
  that neighbor reaches `http://glowcap-rooms:8000` over it. An override adding
  one must keep `rooms-net` in the same list, or terminal peers in the
  devcontainer lose the room.

The shared-session container also joins `rooms-net`, but publishes no host
port: browser bytes reach its authenticated iroh identity through the Rooms
page's existing opaque `/relay` path.

The deployment defaults to `GLOWCAP_ROOMS_REACHABILITY=discovery`. The room announces
only its iroh node id; peers resolve it through n0 relay and DNS/pkarr
infrastructure.

For a self-contained same-host setup, set `GLOWCAP_ROOMS_REACHABILITY=direct`. To run a
TCP room instead, remove `--transport=iroh` and configure `GLOWCAP_ROOMS_BIND` and
`GLOWCAP_ROOMS_ANNOUNCE_HOST`; TCP does not use iroh discovery.

The Compose front also forwards the web relay's admission settings. General sessions and held registrations use
`GLOWCAP_RELAY_MAX_SESSIONS`, `GLOWCAP_RELAY_MAX_REGISTRATIONS`, and
`GLOWCAP_RELAY_MAX_REGISTRATIONS_PER_IDENTITY`. Iroh relay legs additionally use
`GLOWCAP_RELAY_MAX_IROH_SESSIONS` and `GLOWCAP_RELAY_MAX_IROH_DIALS_PER_MINUTE`, because each one retains a native
endpoint runtime. Leaving a value unset takes the defaults documented in [Operating Rooms](../../operating.md#web-relay-admission).

See [devcontainer networking](../../../../.devcontainer/docs/networking.md) for
the `rooms-net` side of the setup.

## Use it from a larger Compose project

Copy the `rooms` service into the host's existing Compose file and replace the
artifact mount with an absolute path:

```yaml
volumes:
  - /absolute/path/to/glowcap/zig-out:/runtime:ro
  - rooms-state:/state
```

Keep the command, environment, image build, network, and ignored override's
loopback port mapping unchanged. To deploy without mounting a working checkout,
copy the prepared `zig-out` artifacts into a stable read-only directory and
mount it at `/runtime`. Keep the sibling `bin`, `lib` and `rooms-web` paths.

## Storage

Kept room lines live in the state volume by default. To keep them in a managed
database instead, bring up the optional service and point the server at it:

```sh
export STORAGE_DB_PASSWORD='<a long secret>'
export GLOWCAP_ROOMS_STORAGE='postgres://rooms:<that secret>@rooms-storage-db:5432/rooms'
./compose.sh --profile storage-db up -d
./up.sh
```

The database is reachable only on the private compose network. A destination
that cannot be opened stops the server at startup with the reason, so a typo
here is a loud boot failure rather than quiet forgetting.

Project provenance and upstream-contact policy live in
[`PROVENANCE.md`](../../../../PROVENANCE.md).
