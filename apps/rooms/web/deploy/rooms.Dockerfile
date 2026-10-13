# Build context: a complete Linux product, never the source checkout.
# Distroless supplies glibc, the GCC runtime, and certificates without a shell
# or package manager. Existing deployment volumes retain their ownership.
FROM gcr.io/distroless/cc-debian13@sha256:159783207c2cd44c2aa5715961d13c8612368ac9bd450f887e3f08fc8ea461e3
COPY . /runtime
WORKDIR /runtime
ENTRYPOINT ["/runtime/bin/glowcap", "apps", "rooms", "serve"]
