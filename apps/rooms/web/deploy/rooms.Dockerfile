# Build context: a complete Linux product, never the source checkout.
# Distroless supplies glibc, the GCC runtime, and certificates without a shell
# or package manager. Existing deployment volumes retain their ownership.
FROM gcr.io/distroless/cc-debian13@sha256:809d04afa1be033c441f76bb0051878c342fb76d0ea236bc6dc94b655fa0fbd6
LABEL org.opencontainers.image.title="glowcap Rooms" \
      org.opencontainers.image.description="The glowcap Rooms chat directory and web app" \
      org.opencontainers.image.vendor="Glowcap LLC" \
      org.opencontainers.image.url="https://glowcap.org" \
      org.opencontainers.image.source="https://github.com/glowcap-org/glowcap" \
      org.opencontainers.image.licenses="Apache-2.0"
ENV GLOWCAP_ROOMS_PRIVATE_STARTUP=1
COPY . /runtime
WORKDIR /runtime
ENTRYPOINT ["/runtime/bin/glowcap", "apps", "rooms", "serve"]
