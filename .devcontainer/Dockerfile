# syntax=docker/dockerfile:1.7
# Toolchain versions and paths: pins.sh; Rooms Wasm glue follows its Cargo.lock.
# Environment consistency is enforced by test/env-sync.sh at container open.
# Gate: zig build check

FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a

LABEL org.opencontainers.image.title="glowcap-dev:local" \
      org.opencontainers.image.description="glowcap-dev devcontainer: Zig, Goblins conformance, dogfood toolchains." \
      org.opencontainers.image.source="https://github.com/jimisaacs/glowcap" \
      org.opencontainers.image.licenses="Apache-2.0"

# Paths must match pins.sh (see test/env-sync.sh).
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    DENO_INSTALL=/usr/local \
    DENO_DIR=/home/vscode/.cache/glowcap/tool/deno \
    BUN_INSTALL_CACHE_DIR=/home/vscode/.cache/glowcap/tool/bun/install \
    npm_config_cache=/home/vscode/.cache/glowcap/tool/npm \
    PIP_CACHE_DIR=/home/vscode/.cache/glowcap/tool/pip \
    UV_TOOL_DIR=/usr/local/uv/tools \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    UV_PYTHON_INSTALL_DIR=/usr/local/uv/python \
    ZIG_GLOBAL_CACHE_DIR=/home/vscode/.cache/glowcap/tool/zig \
    PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/ms-playwright \
    PLTUSERHOME=/opt/glowcap-racket-userhome \
    CLAUDE_CONFIG_DIR=/home/vscode/.claude \
    CURSOR_CONFIG_DIR=/home/vscode/.cursor \
    CURSOR_DATA_DIR=/home/vscode/.cursor \
    PATH=/home/vscode/.cache/glowcap/cargo/bin:/usr/local/cargo/bin:/usr/local/bin:${PATH}

# `ripgrep` is a floor for the agent CLIs this image installs. Every one of them
# reaches for `rg` by default, and only Claude Code carries its own copy behind a
# shell function, so without the real binary the others fail their first search
# and fall back to something slower that does not read `.gitignore`.
#
# `tor` is here for the `onion` netlayer (ADR-0108), whose live checks talk to a
# Tor daemon over SOCKS and the control protocol. glowcap never starts,
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
      python3-pip python3-venv ripgrep shellcheck strace tar tor unzip valgrind \
      xz-utils util-linux zsh

# ==============================================================================
# The vscode user space, created before any bind mount lands in it.
#
# Every directory a host bind targets exists here first with the runtime
# user's ownership. A missing mount point would otherwise be created as root.
# ==============================================================================
RUN groupadd --gid 1000 vscode \
&& useradd --uid 1000 --gid 1000 -m -s /bin/zsh vscode \
&& mkdir -p /home/vscode/.cache \
     /home/vscode/.cache/glowcap \
     /home/vscode/.cache/glowcap-dev-zig-work \
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
     /home/vscode/.serena \
&& chown -R vscode:vscode /home/vscode
# ==============================================================================

ENV GLOWCAP_DEVCONTAINER_DIR=/usr/local/share/glowcap-devcontainer
# The image keeps the same layout the checkout has, so a path that works in
# one works in the other: the pinned versions, the shell library, the
# installers with their patches. Everything else in this directory stays in
# the checkout, which is mounted.
COPY .devcontainer/pins.sh \
     .devcontainer/checksums.sh \
     "${GLOWCAP_DEVCONTAINER_DIR}/"
COPY .devcontainer/lib/ "${GLOWCAP_DEVCONTAINER_DIR}/lib/"
COPY .devcontainer/image/ "${GLOWCAP_DEVCONTAINER_DIR}/image/"

RUN bash "${GLOWCAP_DEVCONTAINER_DIR}/image/zig.sh" \
 && bash "${GLOWCAP_DEVCONTAINER_DIR}/image/zls.sh" \
 && bash "${GLOWCAP_DEVCONTAINER_DIR}/image/rust.sh" \
 && bash "${GLOWCAP_DEVCONTAINER_DIR}/image/js-toolchains.sh" \
 && bash "${GLOWCAP_DEVCONTAINER_DIR}/image/claude-code.sh" \
 && bash "${GLOWCAP_DEVCONTAINER_DIR}/image/cursor-agent.sh" \
 && bash "${GLOWCAP_DEVCONTAINER_DIR}/image/opencode.sh" \
 && bash "${GLOWCAP_DEVCONTAINER_DIR}/image/codex.sh" \
 && bash "${GLOWCAP_DEVCONTAINER_DIR}/image/python.sh" \
 && bash "${GLOWCAP_DEVCONTAINER_DIR}/image/serena.sh" \
 && bash "${GLOWCAP_DEVCONTAINER_DIR}/image/racket-goblins.sh"

# Browser application builds use the compiler matching the locked library.
# Keep this layer separate so application lock changes do not reinstall the
# language toolchains or agent tools above.
COPY apps/rooms/rust/Cargo.lock "${GLOWCAP_DEVCONTAINER_DIR}/rooms-Cargo.lock"
RUN bash "${GLOWCAP_DEVCONTAINER_DIR}/image/rust-wasm.sh"

# Playwright's browser install is its own layer because it is the only installer
# that also runs apt, and apt wants the same caches the first apt layer used.
# It needs npx, so it follows image/js-toolchains.sh above.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    bash "${GLOWCAP_DEVCONTAINER_DIR}/image/playwright.sh"

# The repo-root glowcap shim (ADR-0084) on PATH from any directory. The
# workspace bind lands at /workspaces/glowcap only at container open, so the
# link dangles during the image build and resolves there.
RUN ln -s /workspaces/glowcap/glowcap /usr/local/bin/glowcap

RUN bash "${GLOWCAP_DEVCONTAINER_DIR}/image/verify-toolchains.sh"
