# pancake devcontainer pins, versions and canonical paths.
# Install, verify, Dockerfile ENV, and devcontainer.json must stay aligned.
# check-env-sync.sh enforces path consistency across those surfaces.

# --- Zig (ZLS must match the compiler generation) ---
ZIG_VERSION="0.16.0"
ZLS_VERSION="0.16.0"

# --- Rust (C ABI dogfood) ---
RUST_VERSION="1.97.1"

# --- JavaScript / TypeScript dogfood ---
DENO_VERSION="2.9.5"
NODE_VERSION="26.7.0"
BUN_VERSION="1.3.14"

# --- Playwright (the browser proofs' Chromium) ---
# This is the one place the version is written. The root deno.json resolves the
# browser proofs' `playwright` import from the same number, and
# `zig build meta-check` fails if the two ever disagree. The browser build
# number (chromium-<rev>) is Playwright's to choose, so nothing here restates it.
PLAYWRIGHT_VERSION="1.62.1"

# --- Python (uv) / agent tools ---
UV_VERSION="0.12.3"
SERENA_AGENT_VERSION="1.6.1"
SERENA_PYTHON="3.13"
CLAUDE_CODE_VERSION="2.1.226"
OPENCODE_VERSION="1.18.15"

# --- Racket / Spritely Goblins ---
RACKET_VERSION="9.2"
GOBLINS_VERSION="0.18.0-52-gdcc2b2c5"
GOBLINS_REVISION="dcc2b2c5aa9ab66574f4c58f41ed7f3e02b7aa55"
GOBLINS_CHECKSUM="${GOBLINS_REVISION}"
GOBLINS_SOURCE="https://codeberg.org/spritely/racket-goblins.git?path=goblins#${GOBLINS_REVISION}"

# --- Paths (image build vs container open) ---
RUSTUP_HOME="/usr/local/rustup"
CARGO_HOME_IMAGE="/usr/local/cargo"
CARGO_HOME_RUNTIME="/home/vscode/.cargo"
DENO_INSTALL="/usr/local"
CACHE_ROOT="/home/vscode/.cache"
DENO_DIR="${CACHE_ROOT}/deno"
NPM_CACHE_DIR="${CACHE_ROOT}/npm"
PIP_CACHE_DIR="${CACHE_ROOT}/pip"
ZIG_CACHE_DIR="${CACHE_ROOT}/zig"
BUN_CACHE_DIR="${CACHE_ROOT}/bun"
BUN_INSTALL_CACHE_DIR="${BUN_CACHE_DIR}/install"
PLTUSERHOME="/opt/pancake-racket-userhome"
# Playwright downloads browsers to ~/.cache/ms-playwright by default, which is
# neither a volume nor a bind here, so it would live in the container's writable
# layer and vanish with the container. The browsers belong to the image, so they
# go to a shared system path instead: root installs them once and every user
# reads them.
PLAYWRIGHT_BROWSERS_PATH="/usr/local/share/ms-playwright"
UV_TOOL_DIR="/usr/local/uv/tools"
UV_PYTHON_INSTALL_DIR="/usr/local/uv/python"
OPENCODE_HOME="/opt/opencode"
