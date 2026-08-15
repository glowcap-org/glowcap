# shellcheck shell=bash
# pancake devcontainer pins, versions and canonical paths. Sourced, never run;
# every variable is consumed by the scripts that source this file.
# shellcheck disable=SC2034
# Install, verify, Dockerfile ENV, and devcontainer.json must stay aligned.
# check-env-sync.sh enforces path consistency across those surfaces.

# --- Zig (ZLS must match the compiler generation) ---
ZIG_VERSION="0.16.0"
ZLS_VERSION="0.16.0"

# --- Rust (C ABI dogfood) ---
RUST_VERSION="1.97.1"
RUSTUP_INIT_VERSION="1.29.0"

# --- JavaScript / TypeScript dogfood ---
DENO_VERSION="2.9.5"
NODE_VERSION="26.7.0"
BUN_VERSION="1.3.14"

# --- Playwright (the browser proofs' Chromium) ---
# This is the one place the version is written. The root deno.json resolves the
# browser proofs' `playwright` import from the same number, and
# `zig build source-check` fails if the two ever disagree. The browser build
# number (chromium-<rev>) is Playwright's to choose, so nothing here restates it.
PLAYWRIGHT_VERSION="1.62.1"

# --- Python (uv) / agent tools ---
UV_VERSION="0.12.4"
OCAPN_CONFORMANCE_PYTHON="3.12.13"
SERENA_AGENT_VERSION="1.7.0"
SERENA_PYTHON="3.13"
CLAUDE_CODE_VERSION="2.1.232"
OPENCODE_VERSION="1.18.18"
CODEX_VERSION="0.147.0"

# --- Host side (not in the image; used by up.sh when no CLI is installed) ---
DEVCONTAINER_CLI_VERSION="0.88.0"

# --- Racket / Spritely Goblins ---
RACKET_VERSION="9.2"
GOBLINS_VERSION="0.18.0-52-gdcc2b2c5"
GOBLINS_REVISION="dcc2b2c5aa9ab66574f4c58f41ed7f3e02b7aa55"
GOBLINS_CHECKSUM="${GOBLINS_REVISION}"
GOBLINS_SOURCE="https://codeberg.org/spritely/racket-goblins.git?path=goblins#${GOBLINS_REVISION}"
UNIX_SOCKET_LIB_CHECKSUM="f95429d8b8990ed5ee6033a40e31bf1c52fca610"
RFC6455_CHECKSUM="e3a87e914e25841a6e1bb996aa001aeb178284bf"
CRYPTO_LIB_CHECKSUM="713eaaf45a5e6c55bd3e97a32b2a90f61ef13c4f"
CRYPTO_LIB_FFI_SOURCE_SHA256="ad743ac28d1a4598d011caf983ec51a85e661baff0c6d4c365ca6644338044a6"
CRYPTO_LIB_FFI_PATCHED_SHA256="cd80e435a91fa187a4f1772226604be318b6d791219bd7dc71c5d7a82a2df734"

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
UV_TOOL_BIN_DIR="/usr/local/bin"
UV_PYTHON_INSTALL_DIR="/usr/local/uv/python"
