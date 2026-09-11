# shellcheck shell=bash
# glowcap devcontainer pins, versions and canonical paths. Sourced, never run;
# every variable is consumed by the scripts that source this file.
# shellcheck disable=SC2034
# Install, verify, Dockerfile ENV, and devcontainer.json must stay aligned.
# test/env-sync.sh enforces path consistency across those surfaces.

# --- Base image ---
# Both Dockerfiles build on this one image, and they pin its digest rather than
# its tag, because a tag moves under you and the two images have to be the same
# one. The digest names the multi-architecture index, so one value serves every
# machine the image builds on. `update-pins.sh check` reports it like any other
# dependency and `test/env-sync.sh` holds both Dockerfiles to the value here.
DEBIAN_BASE_TAG="trixie-slim"
DEBIAN_BASE_DIGEST="sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132"

# --- Zig ---
ZIG_VERSION="0.17.0-dev.2085+5e36170b5"
# ZLS currently refuses the pinned Zig 0.17 compiler. Keep its upstream source
# pin recorded for update checks, but do not build or advertise it until
# upstream supports this compiler generation.
ZLS_ENABLED="false"
ZLS_VERSION="0.17.0-dev"
ZLS_SOURCE_REVISION="3df042851351abdcfcdab9e133f3e144fe37b783"
ZLS_SOURCE_SHA256="b4de1b4f28dcfdf473dfad1f5ce2e1b106b07bb8d6f4113a7bd91c41d935dde5"

# --- Rust (C ABI dogfood) ---
RUST_VERSION="1.98.1"
RUSTUP_INIT_VERSION="1.29.1"

# --- JavaScript / TypeScript dogfood ---
DENO_VERSION="2.9.6"
NODE_VERSION="26.8.2"
BUN_VERSION="1.4.2"

# --- Playwright (the browser proofs' Chromium) ---
# This is the one place the version is written. The root deno.json resolves the
# browser proofs' `playwright` import from the same number, and
# `zig build source-check` fails if the two ever disagree. The browser build
# number (chromium-<rev>) is Playwright's to choose, so nothing here restates it.
PLAYWRIGHT_VERSION="1.63.0"

# --- Python (uv) / agent tools ---
UV_VERSION="0.12.12"
OCAPN_CONFORMANCE_PYTHON="3.12.14"
SERENA_AGENT_VERSION="1.7.0"
SERENA_PYTHON="3.13"
CLAUDE_CODE_VERSION="2.1.267"
OPENCODE_VERSION="1.18.30"
CODEX_VERSION="0.154.0"
# Cursor publishes the agent CLI as one dated build per platform. The version
# string is the whole path segment (date and commit), so it is copied verbatim
# into the download URL rather than composed from parts.
CURSOR_AGENT_VERSION="2026.09.08-6caf4ff"

# --- Host side (not in the image; used by up.sh when no CLI is installed) ---
DEVCONTAINER_CLI_VERSION="0.89.0"

# --- Racket / Spritely Goblins ---
RACKET_VERSION="9.3"
COMPILER_CHECKSUM="a79cef4aa671e7625e310577678ac5ed467983eb"
COMPILER_LIB_CHECKSUM="8270ecc4ff62a0770a89d4c680af2f5e36ee9a37"
GOBLINS_VERSION="0.18.0-52-gdcc2b2c5"
GOBLINS_REVISION="dcc2b2c5aa9ab66574f4c58f41ed7f3e02b7aa55"
GOBLINS_CHECKSUM="${GOBLINS_REVISION}"
GOBLINS_SOURCE="https://codeberg.org/spritely/racket-goblins.git?path=goblins#${GOBLINS_REVISION}"
UNIX_SOCKET_LIB_CHECKSUM="7c41d334bbef65f4ba122e902fd817ef358f5052"
RFC6455_CHECKSUM="e3a87e914e25841a6e1bb996aa001aeb178284bf"
CRYPTO_LIB_CHECKSUM="713eaaf45a5e6c55bd3e97a32b2a90f61ef13c4f"
CRYPTO_LIB_FFI_SOURCE_SHA256="ad743ac28d1a4598d011caf983ec51a85e661baff0c6d4c365ca6644338044a6"
CRYPTO_LIB_FFI_PATCHED_SHA256="cd80e435a91fa187a4f1772226604be318b6d791219bd7dc71c5d7a82a2df734"

# --- Paths (image build vs container open) ---
RUSTUP_HOME="/usr/local/rustup"
CARGO_HOME_IMAGE="/usr/local/cargo"
# Shared with the host at ~/.cache/glowcap (same layout in the container).
GLOWCAP_CACHE_DIR="/home/vscode/.cache/glowcap"
CARGO_HOME_RUNTIME="${GLOWCAP_CACHE_DIR}/cargo"
DENO_INSTALL="/usr/local"
# Shared tool downloads: Zig global, Deno, npm, pip, bun, uv, zls.
CACHE_ROOT="${GLOWCAP_CACHE_DIR}/tool"
DENO_DIR="${CACHE_ROOT}/deno"
NPM_CACHE_DIR="${CACHE_ROOT}/npm"
PIP_CACHE_DIR="${CACHE_ROOT}/pip"
UV_CACHE_DIR="${CACHE_ROOT}/uv"
ZIG_CACHE_DIR="${CACHE_ROOT}/zig"
BUN_CACHE_DIR="${CACHE_ROOT}/bun"
BUN_INSTALL_CACHE_DIR="${BUN_CACHE_DIR}/install"
# Per-worktree Zig local cache and extracted packages live on a Docker volume.
# The daemon-owned filesystem supplies Zig's atomic-file semantics consistently
# under native Linux Docker and Docker Desktop; host-bind implementations vary.
ZIG_WORK_CACHE_DIR="/home/vscode/.cache/glowcap-zig-work"
PLTUSERHOME="/opt/glowcap-racket-userhome"
# Playwright's default download directory is ~/.cache/ms-playwright, which is
# outside the glowcap cache bind, so a browser landing there would vanish with
# the container. Browsers belong to the image: root installs them once and
# every user reads them.
PLAYWRIGHT_BROWSERS_PATH="/usr/local/share/ms-playwright"
# Claude Code splits its state in two by default: `~/.claude` for skills,
# plugins, and credentials, and `~/.claude.json` beside it for the account,
# onboarding state, and per-project history. Only the directory can be
# bind-mounted, so the loose file lived in the container's writable layer and
# died with the container, and every new container opened on the login screen.
# Pointing CLAUDE_CONFIG_DIR at the directory puts `.claude.json` inside it, so
# one bind carries the whole tool the way `~/.codex` already does.
CLAUDE_CONFIG_DIR="/home/vscode/.claude"
# Cursor's installer unpacks the agent CLI under ~/.local/share, which is
# neither a volume nor a bind here. The binary belongs to the image, so it goes
# to a shared system path instead, one directory per pinned build.
CURSOR_AGENT_DIR="/usr/local/share/cursor-agent"
# Settings and session history live under CURSOR_CONFIG_DIR / CURSOR_DATA_DIR
# (then XDG_CONFIG_HOME/cursor, then ~/.cursor). Access and refresh tokens on
# Linux live separately at ~/.config/cursor/auth.json; that directory is its
# own host bind. There is no environment variable that redirects the token
# file, so CURSOR_CONFIG_DIR cannot cover it. Both directory variables still
# point at the settings bind so ambient XDG settings cannot send harness
# state into the writable layer.
CURSOR_STATE_DIR="/home/vscode/.cursor"
CURSOR_AUTH_DIR="/home/vscode/.config/cursor"
UV_TOOL_DIR="/usr/local/uv/tools"
UV_TOOL_BIN_DIR="/usr/local/bin"
UV_PYTHON_INSTALL_DIR="/usr/local/uv/python"
