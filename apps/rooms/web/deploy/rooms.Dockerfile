# Native Rooms services consume the artifacts prepared by rooms-deploy-prep.
# The runtime mounts zig-out read-only and needs no source tree or compiler.
# Match the pinned devcontainer base to keep its glibc boundary aligned.
# Native IRC and TURN clients use the system certificate store.

FROM debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["/runtime/bin/rooms-web"]
