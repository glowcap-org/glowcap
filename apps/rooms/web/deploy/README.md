# Deploy the Rooms browser app

This Compose stack runs the Rooms browser UI and an iroh room server in a small
Deno container. It expects an existing reverse proxy, such as Cloudflare
Tunnel, on a shared Docker network.

Build artifacts stay outside the image. The container mounts this repository
and `zig-out/lib` read-only, then serves the prebuilt browser bundle and loads
the pancake shared libraries at runtime.

## Before you start

You need:

- the pancake devcontainer, with Zig, Deno, and Cargo;
- Docker Compose;
- an existing Docker network used by your reverse proxy.

The examples call the proxy network `cloudflare-tunnel-net`. Substitute the
network that exists on your host.

## Run it

From the repository root, build everything the container mounts:

```sh
zig build rooms-deploy-prep
```

Then configure and start the stack:

```sh
cd apps/rooms/web/deploy
cp .env.example .env
```

Set the proxy network in `.env`:

```dotenv
EGRESS_NET=cloudflare-tunnel-net
```

Create the two external networks if they do not already exist:

```sh
docker network create rooms-net
docker network create cloudflare-tunnel-net
```

If Docker reports that a network already exists, continue.

Start Rooms:

```sh
docker compose up -d --build
docker compose logs -f rooms
```

The container is named `pancake-rooms` and listens on port 8000 inside the
proxy network. It serves the browser page, its `/relay` WebSocket, and
`GET /locator`.

`docker compose ps` shows whether it is *serving*, which is not the same as
running: the health probe asks `/locator`, and that answers only once the page
is being served and the room server it supervises has announced itself. A
container stuck at `starting` or turning `unhealthy` is telling you the room
server is not coming up, and `docker compose logs rooms` says why.

The most likely why, after pulling new work, is that the prebuilt shared
libraries under `zig-out/lib` are older than the source mounted beside them.
They are mounted rather than baked in, so nothing rebuilds them for you and
nothing checks the pair. The server says so when it can — a status no version
defines is reported as exactly this — and the repair is to run
`zig build rooms-deploy-prep` again in the devcontainer and restart the
service.

## Operations capabilities

The deployed app can mint the same operator capabilities a local start can.
Uncomment `PANCAKE_ROOMS_DIAGNOSTICS: "1"` in `docker-compose.yml` for the
inspect capability, and `PANCAKE_ROOMS_ADMIN_LISTENERS: "1"` for listener
administration; each is the same as starting with `--diagnostics` or
`--admin-listeners`. Uncommenting `PANCAKE_ROOMS_VIZ: "1"` is the same as
starting with `--viz`: it serves the live timeline endpoint (port 9300 unless
`PANCAKE_ROOMS_VIZ_PORT` says otherwise) and mints the viz capability it
requires of every socket, so
reaching the port neither reads the timeline nor writes traces into it. The
server prints each swiss number into the container
logs (`docker compose logs rooms`), and the `rooms-state` volume keeps the
names stable across restarts. Whoever can read those logs holds the
capabilities, which is the whole of the access control: paste a swiss number
when flipping its toggle on in the page's Settings → Advanced, or fetch a
directory-session capability from any client.

## Put it behind a tunnel

The page and WebSocket share one origin, so one Cloudflare ingress rule is
enough:

```yaml
ingress:
  - hostname: rooms.example.com
    service: http://pancake-rooms:8000
  - service: http_status:404
```

Route the hostname to your tunnel:

```sh
cloudflared tunnel route dns <tunnel-name> rooms.example.com
```

Open the public hostname and join a room. To verify the CapTP bootstrap
separately:

```sh
curl https://rooms.example.com/locator
```

The response is a live `ocapn://<nodeid>.iroh` locator. HTTP only delivers that
locator to native and terminal peers; they then dial through iroh discovery.
The browser cannot dial iroh itself, so its CapTP bytes travel through the
`/relay` WebSocket and Cloudflared carries that opaque relay stream.

## Connect a Rooms peer

The pancake devcontainer shares `rooms-net` with the deployed app. From the
repository root inside that container:

```sh
zig build
export PATH="$PWD/zig-out/bin:$PATH"
pancake app rooms-peer start \
  --nick Alice --dir /tmp/rooms-peer-alice --room general
```

The peer fetches `http://pancake-rooms:8000/locator` by default, then dials the
returned iroh locator. The Docker service alias `rooms` works too.

Run `pancake app rooms-peer --help` for the remaining peer commands. After a
Rooms server source change, rebuild the mounted artifacts inside the
devcontainer:

```sh
zig build rooms-deploy-prep
```

Then restart the service from a shell with Docker access, at the repository
root:

```sh
docker compose -f apps/rooms/web/deploy/docker-compose.yml restart rooms
```

## How the container is assembled

The image contains Deno on the same pinned glibc-based Debian image used by the
supported devcontainer. It contains no Zig or Rust toolchain. The iroh sidecar
is already linked into `libpancake_net_transport_iroh.so`.

`zig build rooms-deploy-prep` creates:

- the pancake shared libraries;
- the iroh transport library;
- the WebAssembly Host loaded by the browser;
- `apps/rooms/web/ui/page.js`, the browser bundle.

Prebuilding the bundle keeps deployment startup independent of package-cache
state and avoids bundling on boot. The server can bundle at runtime when its
dependencies are already available, but the deployment does not rely on that
fallback.

The generated bundle is minified. That keeps it small, and it also selects the
production build of the page's UI runtime: unminified, React ships a development
build whose diagnostics belong in the console of whoever is editing the page
rather than in a deployment. The bundle `serve.ts` builds on the fly while
developing is the unminified one, for that reason. To rebuild the deployment
artifact by hand:

```sh
deno bundle --platform browser --no-lock --quiet --minify \
  --config bindings/ts/web/browser-bundle.json \
  apps/rooms/web/ui/main.tsx -o apps/rooms/web/ui/page.js
```

`page.js` is generated and gitignored.

## Network and transport reference

The service joins two external Docker networks:

- `rooms-net` connects the deployment to the pancake devcontainer.
- `EGRESS_NET` connects it to the reverse proxy.

The deployment defaults to `PANCAKE_ROOMS_REACHABILITY=discovery`. The room announces
only its iroh node id; peers resolve it through n0 relay and DNS/pkarr
infrastructure.

For a self-contained same-host setup, set `PANCAKE_ROOMS_REACHABILITY=direct`. To run a
TCP room instead, remove `--transport=iroh` and configure `PANCAKE_ROOMS_BIND` and
`PANCAKE_ROOMS_ANNOUNCE_HOST`; TCP does not use iroh discovery.

The devcontainer and this deployment each have an `EGRESS_NET`, but they
usually name different networks. Their shared network is always `rooms-net`.
See [devcontainer networking](../../../../.devcontainer/networking.md) for that
side of the setup.

## Use it from a larger Compose project

Copy the `rooms` service into the host's existing Compose file and replace the
two repository-relative mounts with absolute paths:

```yaml
volumes:
  - /absolute/path/to/pancake:/repo:ro
  - /absolute/path/to/pancake/zig-out/lib:/libs:ro
  - rooms-deno-cache:/deno-dir
```

Keep the command, environment, image build, and networks unchanged. To deploy
without mounting a working checkout, copy the required source and shared
libraries into stable read-only directories and mount those instead.
