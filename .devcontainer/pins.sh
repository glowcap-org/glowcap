# shellcheck shell=bash
# glowcap devcontainer pins, versions and canonical paths. Sourced, never run;
# every variable is consumed by the scripts that source this file.
# shellcheck disable=SC2034
# Install, verify, Dockerfile ENV, and devcontainer.json must stay aligned.
# test/env-sync.sh enforces path consistency across those surfaces.

# --- Base image ---
# The development image includes the toolchain. Production uses only the
# compatible system runtime below. Both pins name multi-architecture indexes;
# update-pins tracks them and env-sync checks their Dockerfile consumers.
# dep Debian: The base image for the development container and the Rooms runtime.
DEBIAN_BASE_TAG="trixie-slim"
DEBIAN_BASE_DIGEST="sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f"

# --- Production service images ---
# dep Distroless: The minimal base for the Rooms server image.
DISTROLESS_BASE_DIGEST="sha256:159783207c2cd44c2aa5715961d13c8612368ac9bd450f887e3f08fc8ea461e3"

# --- Zig ---
# dep Zig: Builds the library, the C archives, the CLI and every check.
ZIG_VERSION="0.17.0"
# dep ZLS: The Zig language server for editors, built against the pinned Zig.
ZLS_VERSION="0.17.0-dev"
ZLS_SOURCE_REVISION="eab2be0fd74443a27662da809b771c4ad0d2afcf"
ZLS_SOURCE_SHA256="e33ac991c827b3e38150530864d3d4deafc1ca020539a6358fb056b8c4a48606"

# --- Rust (C ABI dogfood) ---
# dep Rust and rustup: The Rust binding, the iroh and WebRTC transports, and Rooms.
RUST_VERSION="1.99.0"
RUSTUP_INIT_VERSION="1.29.1"

# --- JavaScript / TypeScript dogfood ---
# dep Deno: The TypeScript binding, Rooms' web client, ocapnviz and the browser tests.
DENO_VERSION="2.9.7"
# dep Node and npm: Install the coding agents the container offers.
NODE_VERSION="26.11.1"
NPM_VERSION="12.2.0"
# dep Bun: Runs the TypeScript binding's tests on a second JavaScript runtime.
BUN_VERSION="1.4.3"

# --- Playwright (the browser proofs' Chromium) ---
# This is the one place the version is written. The root deno.json resolves the
# browser proofs' `playwright` import from the same number, and
# `zig build source-check` fails if the two ever disagree. The browser build
# number (chromium-<rev>) is Playwright's to choose, so nothing here restates it.
# dep Playwright: Drives Chromium for the browser tests.
PLAYWRIGHT_VERSION="1.64.0"

# --- Python (uv) / agent tools ---
# dep uv: Installs Python and the Python projects' packages.
UV_VERSION="0.13.0"
# dep Python: The Python binding and the OCapN test suite.
PYTHON_VERSION="3.14.7"
# dep Serena: Symbol-level navigation of the Zig code for coding agents.
SERENA_AGENT_VERSION="2.0.0"
# The four AI harnesses are managed tools, not image content: these versions
# are the verified cold-install seeds the dispatcher installs on first use
# (.devcontainer/tools), and update-pins keeps them fresh. An explicit
# `tools.sh update` may move a tool past its seed; the seed stays what a cold
# machine installs. Cursor publishes the agent CLI as one dated build per
# platform; the version string is the whole path segment (date and commit),
# so it is copied verbatim into the download URL rather than composed from
# parts.
# dep Coding agents: Claude Code, opencode, Codex and Cursor Agent, installed
#   on first use.
CLAUDE_CODE_VERSION="2.1.296"
OPENCODE_VERSION="1.19.0"
CODEX_VERSION="0.162.1"
CURSOR_AGENT_VERSION="2026.10.01-e373342"

# --- Host side (not in the image; used by up.sh when no CLI is installed) ---
# dep Dev Container CLI: Starts and rebuilds the container from the host.
DEVCONTAINER_CLI_VERSION="0.89.0"

# --- Racket / Spritely Goblins ---
# dep Racket and Spritely Goblins: The reference peer for interop tests.
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
ZIG_WORK_CACHE_DIR="/home/vscode/.cache/glowcap-dev-zig-work"
PLTUSERHOME="/opt/glowcap-racket-userhome"
# Claude Code splits its state in two by default: `~/.claude` for skills,
# plugins, and credentials, and `~/.claude.json` beside it for the account,
# onboarding state, and per-project history. Only the directory can be
# bind-mounted, so a loose file would live in the container's writable layer and
# die with the container, and every new container would open on the login screen.
# Pointing CLAUDE_CONFIG_DIR at the directory puts `.claude.json` inside it, so
# one bind carries the whole tool the way `~/.codex` already does.
CLAUDE_CONFIG_DIR="/home/vscode/.claude"
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
