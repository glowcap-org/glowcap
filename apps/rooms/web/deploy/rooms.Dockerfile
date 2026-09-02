# A light, serve-only image for the rooms browser demo over iroh.
#
# It carries no build toolchain — no Zig, Rust, Racket, or Python, and no node or
# bun. It is the official Deno binary on a glibc base, running the rooms web UI
# (apps/rooms/web/serve.ts) against the glowcap TypeScript source and the
# prebuilt glowcap shared libraries, both supplied at run time as read-only mounts
# (see docker-compose.yml). Prepare them first in the supported devcontainer:
#
#     zig build rooms-deploy-prep
#
# Deno comes from the official image's `bin` variant (just the binary), copied onto
# the same pinned debian:trixie-slim base as the dev image. Building in that
# devcontainer and running on this image keeps the glibc boundary aligned.
# Nothing here needs ca-certificates: the web surface is host-local and CapTP
# peers authenticate with iroh's own node keys. The browser bundle is prepared in
# the devcontainer so startup does not depend on package-cache state. There is no
# apt layer. The iroh Rust sidecar is statically linked into the transport .so, so
# this image needs no cargo either.
#
# The Deno tag, its source-image index digest, and the base image digest below
# come from .devcontainer/pins.sh. `update-pins.sh bump deno` stages the Deno
# version, release hashes, digest, and this reference as one transaction.

FROM debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132
COPY --from=denoland/deno:bin-2.9.6@sha256:4cf0029b9aeeeed5efcbb71828737f0d7c8c8a20072df960e51a5679ef0d21ba /deno /usr/local/bin/deno
ENV DENO_DIR=/deno-dir
ENTRYPOINT ["deno"]
