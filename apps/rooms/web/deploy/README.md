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

The generated bundle is readable rather than minified. To build a smaller
variant with the same browser-specific import configuration:

```sh
deno bundle --platform browser --no-lock --quiet --minify \
  --config bindings/ts/web/browser-bundle.json \
  apps/rooms/web/ui/main.ts -o apps/rooms/web/ui/page.js
```

`page.js` is generated and gitignored.

## Network and transport reference

The service joins two external Docker networks:

- `rooms-net` connects the deployment to the pancake devcontainer.
- `EGRESS_NET` connects it to the reverse proxy.

The deployment defaults to `ROOMS_REACHABILITY=discovery`. The room announces
only its iroh node id; peers resolve it through n0 relay and DNS/pkarr
infrastructure.

For a self-contained same-host setup, set `ROOMS_REACHABILITY=direct`. To run a
TCP room instead, remove `--transport=iroh` and configure `ROOMS_BIND` and
`ROOMS_ANNOUNCE_HOST`; TCP does not use iroh discovery.

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
