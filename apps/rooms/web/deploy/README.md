# Deploy the Rooms browser app

This Compose stack runs the Rooms browser UI, an iroh Rooms server, one
durable shared workspace session, and a PostgreSQL database for kept room
lines, the first three as native Rust services. The tracked base publishes no
host port. An ignored `docker-compose.override.yml` says how this machine
reaches the page, so a host's ports and network names never enter the
repository, and the database password lives in an ignored `secrets/` file
that `./ops up` mints on first use.

Build artifacts stay outside the image. Each container mounts `zig-out` at
`/runtime` read-only, including native executables, their shared libraries,
and the complete browser artifact. Serving needs no source tree or compiler.

This is the source distribution described in the Rooms
[prerelease scope](../../README.md#prerelease), not a standalone
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

Then, on the machine that runs Docker, bring it up through this directory's
operations front:

```sh
cd apps/rooms/web/deploy
./ops up
```

The first `up` creates the `rooms-net` network shared with the glowcap
devcontainer, seeds `docker-compose.override.yml` from its tracked example,
mints the database password, builds, recreates the containers, waits for each
to serve, and prints one handoff block with the room locator, browser
interface build, and every capability. The same short Git revision appears at
the bottom of Help in the browser. An override already in place is left
exactly as written.

The example override publishes the page on this host's loopback. Its comments
carry the other way in: joining the Docker network that a reverse proxy or
tunnel container already runs on. That neighbor reaches
`http://glowcap-rooms:8000` over the network and needs no published port. A
host may use either way, or both.

`ops` is plain `sh`, so it runs on a Docker host that has none of the
devcontainer's toolchain. Every verb checks the tool it needs and says which
machine to go to when one is missing:

| Verb | Does |
| --- | --- |
| `./ops doctor` | Which tools are here, what is prepared, what runs. Touches nothing |
| `./ops up` | The first-time setup above, then the strict start: refuse a dirty checkout or a stale preparation, mint, build, recreate, wait, hand off |
| `./ops redeploy` | `zig build rooms-deploy-prep` where Zig is, then `up` where Docker is |
| `./ops status` | Container and volume state |
| `./ops logs [service...]` | Follow the deployment's logs |
| `./ops down` | Stop the deployment and keep every volume |
| `./ops reset <what> [--yes]` | Destroy one custody unit and bring the stack back; see Operations capabilities below |
| `./ops compose <args...>` | Docker Compose with this deployment's files selected, for everything else |

`ops` calls `zig build` for the toolchain half and never the reverse: the
build graph does not know this front exists. `./ops compose` always selects
`docker-compose.yml`, explicitly adds the ignored override when it exists, and
disables Compose's implicit `.env` loading, so operator values come from the
exported process environment unless an explicit `--env-file` is passed:

```sh
./ops compose logs -f rooms
```

Open `http://127.0.0.1:8000`. The `glowcap-rooms` container serves the browser
page, its same-origin `/relay` WebSocket, `GET /locator`, and `GET /llms.txt`,
a plain-text description of the deployment for a program that was handed the
address (the shape https://llmstxt.org/ describes). The Compose port
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

`./ops status` shows whether it is *serving*, which is not the same as
running: the health probe asks `/locator`, and that answers only once the page
is being served and the Rooms server it supervises has announced itself. A
container stuck at `starting` or turning `unhealthy` is telling you the room
server is not coming up, and `./ops logs rooms` says why.

After pulling new work, `./ops up` refuses a dirty checkout or a completed
deployment revision from another commit. `./ops redeploy` runs
`zig build rooms-deploy-prep` again where Zig is and, when Docker is not on
the same machine, names the command to finish with on the host. The
preparation's revision is written only after the shared libraries, iroh
transport, Wasm Host, browser bundle, and native session peer all finish, so
a failed or partial preparation cannot authorize the new checkout.

## Your shared workspace

The `glowcap-rooms-session` container owns one durable user workspace. Its
identity, intended rooms and direct conversations, drafts, shared connection
and retention choices, retained capabilities, member-owned history, and the
passwords answered to bridge forms all live in the separate
`rooms-session-state` volume. Restarting the stack republishes the
same session capability and reconciles that saved intent; unreachable peers
remain visible as disconnected until they return.

Run `./ops up`. After both peers are ready, its single capability handoff block
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
./ops compose exec -T rooms-session \
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
(`GLOWCAP_ROOMS_PEERING`), the live timeline (`GLOWCAP_ROOMS_TRACE`, serving
port 9300 unless `GLOWCAP_ROOMS_TRACE_PORT` says otherwise), and the IRC
gateway (`GLOWCAP_ROOMS_IRC`). Each is the same as the matching `--flag` on a
local start; comment a line out to withhold that authority from the
deployment. The trace endpoint requires its capability of every socket, so
reaching the port neither reads the timeline nor writes traces into it.

`./ops up` is the one-step restart: it runs
`compose up -d --build --force-recreate`, waits for the Rooms server and
shared session to become ready, and prints one handoff block containing the
room's operator capabilities, room locator, and session administrator
capability.

A build that replaced a prerelease state schema refuses the files a volume
holds from the previous one, says which schema wrote them, and keeps
restarting until the operator resets. Each durable volume is one custody
unit, so a reset removes a whole volume and never one file. `./ops reset`
stops the stack, asks before it destroys anything, removes only what was
named, and brings the stack back up through the same handoff; `--yes`
answers for an unattended run:

| Command | Destroys |
| --- | --- |
| `./ops reset session` | The shared workspace. Its administrator capability is minted fresh, so the page must attach again from the new handoff block |
| `./ops reset state` | The room server's state: its identity, the operator capability swiss numbers, and every issued room link |
| `./ops reset storage` | The history database. Every kept room line goes with it, so dump it first (Storage below) if it matters |
| `./ops reset all` | Every volume the stack declares, state, session, history, and caches alike |

Each capability's swiss number is minted once and persists in the
`rooms-state` volume, so a restart republishes the same one. Three ways to
read them, any time:

```sh
# The capability printer reads the state volume and prints the token lines:
./ops compose exec rooms /runtime/bin/rooms-server --capabilities

# The startup logs carry the same lines:
./ops compose logs rooms | grep 'ROOMS-'

# Or read a single one straight from the volume:
./ops compose exec rooms cat /state/diagnostics
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
apps/rooms/web/deploy/ops compose restart rooms
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
./ops compose up -d
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

`./ops up` requires a clean checkout and checks both identities before recreating
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

Kept room lines live in the `rooms-storage-db` PostgreSQL service, in the
`rooms-storage-db` volume. The room server names it as
`postgres://rooms@rooms-storage-db:5432/rooms?sslmode=disable` and reads the
password from the Docker secret `storage-db-password`, so the password is in
no environment, command line, or `docker inspect` output. The database is
reachable only on the private compose network, TLS is off on that leg for
that reason, and a destination that cannot be opened stops the server at
startup with the reason, so a misconfiguration is a loud boot failure rather
than quiet forgetting. The room server waits for the database's health check
before it is started at all.

The password is one file, `secrets/storage-db-password`, which `./ops up` mints
from the kernel's randomness on first use and never rewrites. Git ignores the
directory. Keep that file with your backups: a restored data volume is only
readable with the password it was created under.

Back up the database while it runs, and restore into an empty volume:

```sh
./ops compose exec -T rooms-storage-db pg_dump -U rooms -Fc rooms >rooms-$(date +%Y%m%d).dump
./ops compose exec -T rooms-storage-db pg_restore -U rooms -d rooms --clean --if-exists <rooms-20260912.dump
```

Never change the PostgreSQL major version in place: dump with the old service,
recreate the volume, restore with the new one. The image is pinned by digest
so a rebuild cannot move it by accident.

To keep lines in the state volume's files instead, which suits a machine you
are only trying things on, export both storage values empty before bringing
it up; the database service still runs, idle:

```sh
export GLOWCAP_ROOMS_STORAGE= GLOWCAP_ROOMS_STORAGE_PASSWORD_FILE=
./ops up
```

Project provenance and upstream-contact policy live in
[`PROVENANCE.md`](../../../../PROVENANCE.md).
