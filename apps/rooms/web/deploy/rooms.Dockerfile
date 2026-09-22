# Build context: a complete Linux product, never the source checkout.
# Distroless supplies glibc, the GCC runtime, and certificates without a shell
# or package manager. Existing deployment volumes retain their ownership.
FROM gcr.io/distroless/cc-debian13@sha256:4594d59540d1948417f6ca2829ddd9294493a7c68b7528f4dd459de7f203a750
COPY . /runtime
WORKDIR /runtime
ENTRYPOINT ["/runtime/bin/glowcap", "apps", "rooms", "serve"]
