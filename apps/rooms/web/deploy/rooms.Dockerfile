# Build context: a complete Linux product, never the source checkout.
# Distroless supplies glibc, the GCC runtime, and certificates without a shell
# or package manager. Existing deployment volumes retain their ownership.
FROM gcr.io/distroless/cc-debian13@sha256:e1f5543d45a2cd7c02a5b43dda5f0ff30729b4832113759d01ed39b0b152cddb
LABEL org.opencontainers.image.title="glowcap Rooms" \
      org.opencontainers.image.description="The glowcap Rooms chat directory and web app" \
      org.opencontainers.image.vendor="Glowcap LLC" \
      org.opencontainers.image.url="https://glowcap.org" \
      org.opencontainers.image.source="https://github.com/glowcap-org/glowcap" \
      org.opencontainers.image.licenses="Apache-2.0"
COPY . /runtime
WORKDIR /runtime
ENTRYPOINT ["/runtime/bin/glowcap", "apps", "rooms", "serve"]
