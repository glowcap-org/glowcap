# Running the rooms browser demo behind a tunnel

This directory serves the rooms browser UI over iroh from a small container that
carries no build toolchain. The image is Deno on a `debian:trixie-slim` base; the
pancake TypeScript source and the prebuilt pancake shared libraries both arrive at
run time as read-only mounts, so nothing pancake is baked into the image. A
Cloudflare tunnel (or any reverse proxy) puts it on the public internet.

The split is deliberate. The heavy dev image builds the shared libraries once; this
light image only runs them. The Rust iroh sidecar is statically linked into
`libpancake_net_transport_iroh.so`, so the runtime needs no cargo: just Deno and
two `.so` files.

## Build the shared libraries and the UI bundle first

The libraries live in `zig-out/lib/`, which is generated, so build them in the dev
container before starting the compose service:

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

The container is named `pancake-rooms` and serves the page and its WebSocket on
port 8000. It joins the external network your tunnel already uses, so a cloudflared
container on that network reaches it by name. Tell it which network by copying
`.env.example` to `.env` and setting your network's name:

```sh
cp .env.example .env
# then edit .env: ROOMS_EXTERNAL_NET=<your shared network>
```

`.env` is gitignored, so your infrastructure names stay out of the repo. Create the
network first if it does not exist (`docker network create <name>`).

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

Iroh runs entirely inside the container: the browser bridge and the room directory
it spawns talk to each other over loopback QUIC, so there are no UDP ports to
expose. Cloudflared only ever sees port 8000.

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
- **A TCP variant works the same way.** Drop `--transport=iroh` from the command
  and the UI runs over plain TCP, needing only `libpancake_ocapn.so` (the core's
  networking is Deno-native, so no separate TCP transport `.so` is loaded). Iroh is
  the encrypted-QUIC path; over a Cloudflare tunnel the public hop is already TLS,
  so the in-container transport is a free choice.
