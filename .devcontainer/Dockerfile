# syntax=docker/dockerfile:1.7
# Versions and paths: pins.sh (enforced by check-env-sync.sh at container open).
# Gate: zig build check

FROM debian:trixie-slim@sha256:b6e2a152f22a40ff69d92cb397223c906017e1391a73c952b588e51af8883bf8

LABEL org.opencontainers.image.title="pancake-dev:local" \
      org.opencontainers.image.description="pancake-dev devcontainer: Zig, Goblins conformance, dogfood toolchains." \
      org.opencontainers.image.source="https://github.com/jimisaacs/pancake" \
      org.opencontainers.image.licenses="Apache-2.0"

# Paths must match pins.sh (see check-env-sync.sh).
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    DENO_INSTALL=/usr/local \
    DENO_DIR=/home/vscode/.cache/deno \
    BUN_INSTALL_CACHE_DIR=/home/vscode/.cache/bun/install \
    npm_config_cache=/home/vscode/.cache/npm \
    PIP_CACHE_DIR=/home/vscode/.cache/pip \
    UV_TOOL_DIR=/usr/local/uv/tools \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    UV_PYTHON_INSTALL_DIR=/usr/local/uv/python \
    ZIG_GLOBAL_CACHE_DIR=/home/vscode/.cache/zig \
    PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/ms-playwright \
    PLTUSERHOME=/opt/pancake-racket-userhome \
    PATH=/home/vscode/.cargo/bin:/usr/local/cargo/bin:/usr/local/bin:${PATH}

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
 && apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      build-essential ca-certificates curl gdb gh git hyperfine jq libssl-dev \
      linux-perf lldb netcat-openbsd pkg-config python-is-python3 python3 \
      python3-pip python3-venv strace tar unzip valgrind xz-utils util-linux

# ==============================================================================
# The vscode user space, created before any bind mount lands in it.
#
# Every directory a devcontainer.json bind targets must exist here first. Docker
# creates a missing mount path itself, as root, and it creates the missing
# *parents* the same way — so binding `.local/share/opencode` into an image with
# no `.local` leaves `.local` and `.local/share` owned by root, and the first
# tool that wants `.local/state` fails with EACCES before any gate runs.
# ==============================================================================
RUN groupadd --gid 1000 vscode \
&& useradd --uid 1000 --gid 1000 -m -s /bin/bash vscode \
&& mkdir -p /home/vscode/.cache \
     /home/vscode/.config \
     /home/vscode/.local/share \
     /home/vscode/.local/state \
&& chown -R vscode:vscode /home/vscode
# ==============================================================================

ENV PANCAKE_DEVCONTAINER_DIR=/usr/local/share/pancake-devcontainer
COPY .devcontainer/pins.sh \
     .devcontainer/lib.sh \
     .devcontainer/checksums.sh \
     .devcontainer/check-env-sync.sh \
     .devcontainer/install-zig.sh \
     .devcontainer/install-zls.sh \
     .devcontainer/install-rust.sh \
     .devcontainer/install-js-toolchains.sh \
     .devcontainer/install-claude-code.sh \
     .devcontainer/install-opencode.sh \
     .devcontainer/install-uv.sh \
     .devcontainer/install-serena.sh \
     .devcontainer/install-racket-goblins.sh \
     .devcontainer/install-playwright.sh \
     .devcontainer/verify-toolchains.sh \
     "${PANCAKE_DEVCONTAINER_DIR}/"

RUN bash "${PANCAKE_DEVCONTAINER_DIR}/install-zig.sh" \
 && bash "${PANCAKE_DEVCONTAINER_DIR}/install-zls.sh" \
 && bash "${PANCAKE_DEVCONTAINER_DIR}/install-rust.sh" \
 && bash "${PANCAKE_DEVCONTAINER_DIR}/install-js-toolchains.sh" \
 && bash "${PANCAKE_DEVCONTAINER_DIR}/install-claude-code.sh" \
 && bash "${PANCAKE_DEVCONTAINER_DIR}/install-opencode.sh" \
 && bash "${PANCAKE_DEVCONTAINER_DIR}/install-serena.sh" \
 && bash "${PANCAKE_DEVCONTAINER_DIR}/install-racket-goblins.sh"

# Playwright's browser install is its own layer because it is the only installer
# that also runs apt, and apt wants the same caches the first apt layer used.
# It needs npx, so it follows install-js-toolchains.sh above.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    bash "${PANCAKE_DEVCONTAINER_DIR}/install-playwright.sh"

RUN bash "${PANCAKE_DEVCONTAINER_DIR}/verify-toolchains.sh"
