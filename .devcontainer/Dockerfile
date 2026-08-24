# syntax=docker/dockerfile:1.7
# Versions and paths: pins.sh (enforced by test/env-sync.sh at container open).
# Gate: zig build check

FROM debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258

LABEL org.opencontainers.image.title="pancake-dev:local" \
      org.opencontainers.image.description="pancake-dev devcontainer: Zig, Goblins conformance, dogfood toolchains." \
      org.opencontainers.image.source="https://github.com/jimisaacs/pancake" \
      org.opencontainers.image.licenses="Apache-2.0"

# Paths must match pins.sh (see test/env-sync.sh).
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
    CLAUDE_CONFIG_DIR=/home/vscode/.claude \
    CURSOR_CONFIG_DIR=/home/vscode/.cursor \
    CURSOR_DATA_DIR=/home/vscode/.cursor \
    PATH=/home/vscode/.cargo/bin:/usr/local/cargo/bin:/usr/local/bin:${PATH}

# `tor` is here for the `onion` netlayer (ADR-0108), whose live checks talk to a
# Tor daemon over SOCKS and the control protocol. pancake never starts,
# supervises, or configures one, so the image installs the binary and nothing
# else: no init runs in this container, so the Debian service stays down, and a
# check that needs a daemon starts its own with its own torrc. The in-tree onion
# checks run against a fake daemon and need none of this.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
 && apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      build-essential ca-certificates curl gdb gh git hyperfine jq libssl-dev \
      linux-perf lldb netcat-openbsd pkg-config python-is-python3 python3 \
      python3-pip python3-venv shellcheck strace tar tor unzip valgrind \
      xz-utils util-linux

# ==============================================================================
# The vscode user space, created before any bind mount lands in it.
#
# Every directory a devcontainer.json mount targets exists here first with the
# runtime user's ownership. Empty named volumes inherit that shape on first use;
# a missing mount point would otherwise be created as root.
# ==============================================================================
RUN groupadd --gid 1000 vscode \
&& useradd --uid 1000 --gid 1000 -m -s /bin/bash vscode \
&& mkdir -p /home/vscode/.cache \
     /home/vscode/.claude \
     /home/vscode/.codex \
     /home/vscode/.config \
     /home/vscode/.config/agents \
     /home/vscode/.config/cursor \
     /home/vscode/.config/gh \
     /home/vscode/.config/opencode \
     /home/vscode/.cursor \
     /home/vscode/.local/share \
     /home/vscode/.local/share/opencode \
     /home/vscode/.local/state \
&& chown -R vscode:vscode /home/vscode
# ==============================================================================

ENV PANCAKE_DEVCONTAINER_DIR=/usr/local/share/pancake-devcontainer
# The image keeps the same layout the checkout has, so a path that works in
# one works in the other: the pinned versions, the shell library, the
# installers with their patches. The checks and the host-side commands stay
# in the checkout, which is mounted, so the image does not carry a copy.
COPY .devcontainer/pins.sh \
     .devcontainer/checksums.sh \
     "${PANCAKE_DEVCONTAINER_DIR}/"
COPY .devcontainer/lib/ "${PANCAKE_DEVCONTAINER_DIR}/lib/"
COPY .devcontainer/image/ "${PANCAKE_DEVCONTAINER_DIR}/image/"

RUN bash "${PANCAKE_DEVCONTAINER_DIR}/image/zig.sh" \
 && bash "${PANCAKE_DEVCONTAINER_DIR}/image/zls.sh" \
 && bash "${PANCAKE_DEVCONTAINER_DIR}/image/rust.sh" \
 && bash "${PANCAKE_DEVCONTAINER_DIR}/image/js-toolchains.sh" \
 && bash "${PANCAKE_DEVCONTAINER_DIR}/image/claude-code.sh" \
 && bash "${PANCAKE_DEVCONTAINER_DIR}/image/cursor-agent.sh" \
 && bash "${PANCAKE_DEVCONTAINER_DIR}/image/opencode.sh" \
 && bash "${PANCAKE_DEVCONTAINER_DIR}/image/codex.sh" \
 && bash "${PANCAKE_DEVCONTAINER_DIR}/image/python.sh" \
 && bash "${PANCAKE_DEVCONTAINER_DIR}/image/serena.sh" \
 && bash "${PANCAKE_DEVCONTAINER_DIR}/image/racket-goblins.sh"

# Playwright's browser install is its own layer because it is the only installer
# that also runs apt, and apt wants the same caches the first apt layer used.
# It needs npx, so it follows image/js-toolchains.sh above.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    bash "${PANCAKE_DEVCONTAINER_DIR}/image/playwright.sh"

# The repo-root pancake shim (ADR-0084) on PATH from any directory. The
# workspace bind lands at /workspaces/pancake only at container open, so the
# link dangles during the image build and resolves there.
RUN ln -s /workspaces/pancake/pancake /usr/local/bin/pancake

RUN bash "${PANCAKE_DEVCONTAINER_DIR}/image/verify-toolchains.sh"
