# A light, serve-only image for the rooms browser demo over iroh.
#
# It carries no build toolchain — no Zig, Rust, Racket, or Python, and no node or
# bun. It is the official Deno binary on a glibc base, running the rooms web UI
# (examples/apps/rooms/deno/web.ts) against the pancake TypeScript source and the
# prebuilt pancake shared libraries, both supplied at run time as read-only mounts
# (see docker-compose.yml). Build the shared libraries first, in the dev container:
#
#     zig build && zig build iroh-abi   # -> zig-out/lib/libpancake_ocapn.so
#                                       #    + libpancake_net_transport_iroh.so
#
# Deno comes from the official image's `bin` variant (just the binary), copied onto
# the same debian:trixie-slim base as the dev image. The .so need at most GLIBC_2.36,
# so any modern glibc loads them; trixie (2.41) gives headroom and matches the dev
# image digest. Nothing here needs ca-certificates: the public TLS is cloudflared's,
# CapTP peers authenticate with iroh's own node keys (Discovery via n0/pkarr), and
# the app makes no outbound HTTPS — provided the browser client is pre-built (see
# the README: `deno bundle` ui/main.ts -> ui/page.js in the dev container, so web.ts
# serves the ready-made bundle instead of reaching for esbuild at run time). So
# there is no apt layer at all. The iroh Rust sidecar is statically linked into the
# transport .so, so this image needs no cargo either.
#
# Keep the Deno tag below in sync with .devcontainer/pins.sh (DENO_VERSION).

FROM debian:trixie-slim@sha256:b6e2a152f22a40ff69d92cb397223c906017e1391a73c952b588e51af8883bf8
COPY --from=denoland/deno:bin-2.9.1 /deno /usr/local/bin/deno
ENV DENO_DIR=/deno-dir
ENTRYPOINT ["deno"]
