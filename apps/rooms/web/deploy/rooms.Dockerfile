# A light, serve-only image for the rooms browser demo over iroh.
#
# It carries no build toolchain — no Zig, Rust, Racket, or Python, and no node or
# bun. It is the official Deno binary on a glibc base, running the rooms web UI
# (apps/rooms/web/serve.ts) against the pancake TypeScript source and the
# prebuilt pancake shared libraries, both supplied at run time as read-only mounts
# (see docker-compose.yml). Prepare them first in the supported devcontainer:
#
#     zig build rooms-deploy-prep
#
# Deno comes from the official image's `bin` variant (just the binary), copied onto
# the same pinned debian:trixie-slim base as the dev image. Building in that
# devcontainer and running on this image keeps the glibc boundary aligned.
# Nothing here needs ca-certificates: the public TLS is cloudflared's and CapTP
# peers authenticate with iroh's own node keys. The browser bundle is prepared in
# the devcontainer so startup does not depend on package-cache state. There is no
# apt layer. The iroh Rust sidecar is statically linked into the transport .so, so
# this image needs no cargo either.
#
# Keep the Deno tag below in sync with .devcontainer/pins.sh (DENO_VERSION).

FROM debian:trixie-slim@sha256:b6e2a152f22a40ff69d92cb397223c906017e1391a73c952b588e51af8883bf8
COPY --from=denoland/deno:bin-2.9.4 /deno /usr/local/bin/deno
ENV DENO_DIR=/deno-dir
ENTRYPOINT ["deno"]
