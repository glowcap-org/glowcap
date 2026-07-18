# Running the rooms browser demo behind a tunnel

This directory serves the rooms browser UI over iroh from a small container that
carries no build toolchain. The image is Deno on a `debian:trixie-slim` base; the
pancake TypeScript source and the prebuilt pancake shared libraries both arrive at
run time as read-only mounts, so nothing pancake is baked into the image. A
Cloudflare tunnel (or any reverse proxy) puts the browser UI on the public
internet; CapTP peers on the shared Docker network bootstrap the live
`ocapn://` locator from HTTP, then dial over iroh Discovery.

The split is deliberate. The heavy dev image builds the shared libraries once; this
light image only runs them. The Rust iroh sidecar is statically linked into
`libpancake_net_transport_iroh.so`, so the runtime needs no cargo: just Deno and
two `.so` files.

## Build the shared libraries and the UI bundle first

The libraries live in `zig-out/lib/`, which is generated, so build them in the
dev container before starting the compose service:

```sh
zig build && zig build iroh-abi
```

That produces the two objects the iroh rooms UI loads:
`libpancake_ocapn.so` (the core) and `libpancake_net_transport_iroh.so` (the iroh
transport with its sidecar linked in). The base image is pinned to the same
`debian:trixie-slim` digest as the dev image, so the glibc the `.so` were built
against matches the glibc that loads them.

The browser client is authored as TypeScript modules under `ui/` (entered through
`ui/main.ts`) and served as JavaScript. In the dev
container `web.ts` bundles it on the fly, but that first bundle downloads esbuild over
the network, which the light runtime image deliberately cannot do (no CA
certificates, no outbound HTTPS). So pre-build the bundle here too, and `web.ts` will
serve the ready-made `ui/page.js` instead of bundling at run time:

```sh
deno bundle --platform browser examples/apps/rooms/deno/ui/main.ts \
  -o examples/apps/rooms/deno/ui/page.js
```

`ui/page.js` is generated and gitignored, and it rides in on the same read-only
source mount as the rest of the UI.

The bundle is not minified, so it stays readable in the browser's view-source (the
dev on-the-fly bundle omits `--minify` for the same reason). It carries zod, so it is
roughly 150 KB. For a leaner production bundle, add `--minify` to the command above.
It drops the size a lot at the cost of that readability:

```sh
deno bundle --platform browser --minify examples/apps/rooms/deno/ui/main.ts \
  -o examples/apps/rooms/deno/ui/page.js
```

## Run it

From this directory:

```sh
docker compose up -d --build
```

The container is named `pancake-rooms` and serves:

- **HTTP/WebSocket** on port **8000** (browser UI via the tunnel; also
  `GET /locator` for CapTP bootstrap)
- **iroh CapTP** with `ROOMS_REACHABILITY=discovery`: announces a bare
  `ocapn://<nodeid>.iroh` URI resolved through n0 relays + DNS/pkarr

It attaches to two Docker networks:

- **`rooms-net`**: shared with the pancake devcontainer, so a rooms-peer there
  reaches this container's internal CapTP by name. Fixed name, committed in both
  compose files; create it once with `docker network create rooms-net`.
- **your tunnel's network**: so a cloudflared container on it reaches the web UI
  (`:8000`) by name. Name it per host in the gitignored `.env` via `EGRESS_NET`:

```sh
cp .env.example .env
# then edit .env: EGRESS_NET=<your tunnel's network>
docker network create "$(grep ^EGRESS_NET= .env | cut -d= -f2)"   # if missing
docker network create rooms-net                                    # if missing
```

`.env` is gitignored; `.env.example` has an empty value so no network name is
committed. The pancake devcontainer joins `rooms-net` at create time via
[`.devcontainer/.env`](../../../../../.devcontainer/.env.example) +
[`docker-compose.yml`](../../../../../.devcontainer/docker-compose.yml). It sets
its own `EGRESS_NET` (the LLM backend) in its own `.env`, so the two `EGRESS_NET`
values differ: the shared network is `rooms-net`.

## Point cloudflared at it

The browser talks to the page and the WebSocket over one origin, so a single
ingress rule carries everything. Add it next to your other services:

```yaml
ingress:
  - hostname: rooms.example.com
    service: http://pancake-rooms:8000
  # ... your other rules, then the catch-all
  - service: http_status:404
```

Then route DNS for it:

```sh
cloudflared tunnel route dns <your-tunnel-name> rooms.example.com
```

Iroh CapTP (directory + DM members) uses Discovery: peers resolve the node id
through n0 infrastructure. Cloudflared only ever sees port 8000.

## CapTP peers (`pancake app rooms-peer`)

From the pancake devcontainer on the shared `rooms-net`:

```sh
zig build
export PATH="$PWD/zig-out/bin:$PATH"
pancake app rooms-peer start \
  --nick Alice --dir /tmp/rooms-peer-alice --room general
# default locator is http://pancake-rooms:8000/locator
# peer fetches the ocapn:// URI, then dials over iroh Discovery
# install alias: rooms-peer start --nick Alice --dir /tmp/rooms-peer-alice --room general
```

`GET http://pancake-rooms:8000/locator` (service alias `rooms` also resolves)
returns the live bare `ocapn://<nodeid>.iroh` line. That HTTP hop is only
bootstrap. CapTP itself rides iroh. Use `pancake app rooms-peer --help` (or the
`rooms-peer` shim) for the wake-loop verbs. Members publish `dm` on the room
session; the directory fetches it (no dial-back). After pulling a `server.ts`
fix, restart the `rooms` container (`docker compose restart rooms`).

## Lifting it into a shared host compose

To fold this into the compose file that already runs your other services, copy the
`rooms` service into it and change the two source-relative mounts to absolute host
paths:

```yaml
volumes:
  - /abs/path/to/pancake:/repo:ro
  - /abs/path/to/pancake/zig-out/lib:/libs:ro
  - rooms-deno-cache:/deno-dir
```

Everything else (the image build, the `PANCAKE_LIB_DIR`, the network, the command)
carries over unchanged. If you would rather decouple the deploy from a working
checkout, copy the two `.so` into a stable directory and mount that as `/libs`
instead of the live `zig-out/lib`.

## Notes

- **A glibc base, not musl/alpine.** The `.so` are glibc-linked and need at most
  `GLIBC_2.36`, so any modern glibc loads them. The image copies the official Deno
  binary (the `bin` image variant) onto the same `debian:trixie-slim` base as the
  dev image, which gives glibc headroom. Alpine is musl and cannot load the `.so`.
- **Direct reachability** is still available for self-contained same-host demos: set
  `ROOMS_REACHABILITY=direct` (or omit it). Deploy defaults to `discovery` so
  CapTP peers on other containers resolve the room by node id.
- **A TCP room** works by dropping `--transport=iroh` and binding CapTP with
  `ROOMS_BIND` / `ROOMS_ANNOUNCE_HOST`; that path does not use iroh Discovery.
