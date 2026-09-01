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
# Nothing here needs ca-certificates: the web surface is host-local and CapTP
# peers authenticate with iroh's own node keys. The browser bundle is prepared in
# the devcontainer so startup does not depend on package-cache state. There is no
# apt layer. The iroh Rust sidecar is statically linked into the transport .so, so
# this image needs no cargo either.
#
# The Deno tag, its source-image index digest, and the base image digest below
# come from .devcontainer/pins.sh. `update-pins.sh bump deno` stages the Deno
# version, release hashes, digest, and this reference as one transaction.

FROM debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258
COPY --from=denoland/deno:bin-2.9.5@sha256:0d1262facd139e815217c001945eb822c7a78584cf660142c34a6b53effec1aa /deno /usr/local/bin/deno
ENV DENO_DIR=/deno-dir
ENTRYPOINT ["deno"]
