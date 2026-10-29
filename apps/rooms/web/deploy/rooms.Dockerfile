# Build context: a complete Linux product, never the source checkout.
# Distroless supplies glibc, the GCC runtime, and certificates without a shell
# or package manager. Existing deployment volumes retain their ownership.
FROM gcr.io/distroless/cc-debian13@sha256:d74d144baa124dd9defd01d71872bb56c49d4441dba6153ccf790364f97e64b1
LABEL org.opencontainers.image.vendor="Glowcap LLC" \
      org.opencontainers.image.url="https://glowcap.org" \
      org.opencontainers.image.source="https://github.com/glowcap-org/glowcap" \
      org.opencontainers.image.licenses="Apache-2.0"
COPY . /runtime
WORKDIR /runtime
ENTRYPOINT ["/runtime/bin/glowcap", "apps", "rooms", "serve"]
