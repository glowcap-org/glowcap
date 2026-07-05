# pancake devcontainer pins, versions and canonical paths.
# Install, verify, Dockerfile ENV, and devcontainer.json must stay aligned.
# check-env-sync.sh enforces path consistency across those surfaces.

# --- Zig (ZLS must match the compiler generation) ---
ZIG_VERSION="0.16.0"
ZLS_VERSION="0.16.0"

# --- Rust (C ABI dogfood) ---
RUST_VERSION="1.96.1"

# --- JavaScript / TypeScript dogfood ---
DENO_VERSION="2.9.1"
NODE_VERSION="26.4.0"
BUN_VERSION="1.3.14"

# --- Python (uv) / agent tools ---
UV_VERSION="0.11.26"
SERENA_AGENT_VERSION="1.5.3"
SERENA_PYTHON="3.13"
CLAUDE_CODE_VERSION="2.1.198"

# --- Racket / Spritely Goblins ---
RACKET_VERSION="9.2"
GOBLINS_VERSION="0.18.0"
GOBLINS_CHECKSUM="bb661a5ff1f6b501d5ee67449406e1a8071af751"
GOBLINS_SOURCE="https://codeberg.org/spritely/racket-goblins.git?path=goblins#v${GOBLINS_VERSION}"

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
UV_TOOL_DIR="/usr/local/uv/tools"
UV_PYTHON_INSTALL_DIR="/usr/local/uv/python"
