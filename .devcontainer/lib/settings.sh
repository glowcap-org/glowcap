# shellcheck shell=bash
# The tables this directory configures itself from: pinned versions, the
# published ports, the host state each container shares, and the variables
# Compose expects.
#
# Every row here is a fact several files need to agree on, so it is written
# once and read rather than repeated. pins.sh and checksums.sh hold the
# version and hash values themselves; these helpers are how the rest of the
# directory reaches them.

glowcap_devcontainer_source_pins() {
    local root="$1"
    # shellcheck disable=SC1091
    source "${root}/pins.sh"
    glowcap_devcontainer_validate_pins
}

glowcap_devcontainer_validate_pins() {
    if ! [[ "${DEBIAN_BASE_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "pins.sh: DEBIAN_BASE_DIGEST must be sha256:<64 hex>, got '${DEBIAN_BASE_DIGEST:-}'" >&2
        return 1
    fi
    if ! [[ "${POSTGRES_IMAGE_PIN:-}" =~ ^[0-9]+\.[0-9]+-alpine@sha256:[0-9a-f]{64}$ ]]; then
        echo "pins.sh: POSTGRES_IMAGE_PIN must be <major>.<minor>-alpine@sha256:<64 hex>, got '${POSTGRES_IMAGE_PIN:-}'" >&2
        return 1
    fi
    if ! [[ "${PYTHON_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "pins.sh: PYTHON_VERSION must be a stable version triple, got '${PYTHON_VERSION:-}'" >&2
        return 1
    fi
    if [[ "${ZIG_VERSION%%.*}" != "${ZLS_VERSION%%.*}" ]]; then
        echo "pins.sh: ZIG_VERSION (${ZIG_VERSION}) and ZLS_VERSION (${ZLS_VERSION}) must target the same Zig generation" >&2
        return 1
    fi
    if [[ -z "${ZLS_SOURCE_REVISION:-}" || -z "${ZLS_SOURCE_SHA256:-}" ]]; then
        echo "pins.sh: ZLS source revision and SHA-256 must be pinned" >&2
        return 1
    fi
}

glowcap_devcontainer_default_egress_network() {
    printf 'glowcap-dev-%s-egress\n' "$1"
}

# Development host-port baselines; Compose owns container-side service ports.
# Worktree offsets apply uniformly to this table, including the primary's zero.
glowcap_devcontainer_port_rows() {
    printf '%s\n' \
        GLOWCAP_ROOMS_WEB_HOST_PORT:9080 \
        GLOWCAP_ROOMS_CAPTP_HOST_PORT:10099 \
        GLOWCAP_ROOMS_RELAY_HOST_PORT:10200 \
        GLOWCAP_ROOMS_TRACE_HOST_PORT:10300 \
        GLOWCAP_OCAPNVIZ_HOST_PORT:6173 \
        GLOWCAP_DOCS_HOST_PORT:2990
}

# The deployed Rooms HTTP endpoint keeps its host port even when it is down.
# Apply this to every development service, not just its web preview.
glowcap_devcontainer_validate_development_port() {
    if [[ "$1" -eq 8080 ]]; then
        echo "devcontainer: host port 8080 is reserved for the Rooms deployment; choose a development port in .devcontainer/.env" >&2
        return 1
    fi
}

# User identity and agent-harness state shared by every glowcap worktree. The
# host-relative source and absolute container target stay paired here so host
# initialization, container checks, and the committed mounts cannot drift.
glowcap_devcontainer_host_state_rows() {
    printf '%s\n' \
        .claude:/home/vscode/.claude \
        .codex:/home/vscode/.codex \
        .cursor:/home/vscode/.cursor \
        .config/cursor:/home/vscode/.config/cursor \
        .config/gh:/home/vscode/.config/gh \
        .config/opencode:/home/vscode/.config/opencode \
        .local/share/opencode:/home/vscode/.local/share/opencode \
        .config/agents:/home/vscode/.config/agents \
        .serena:/home/vscode/.serena
}

# Download and language-manager caches are shared with the host. Zig's local
# build cache is separate because host-bind atomic-file semantics vary by
# Docker host; docker-compose.yml owns its per-worktree volume.
glowcap_devcontainer_host_cache_rows() {
    printf '%s\n' \
        .cache/glowcap:/home/vscode/.cache/glowcap
}

glowcap_devcontainer_host_cache_layout() {
    printf '%s\n' tool cargo
}

glowcap_devcontainer_host_cache_layout_text() {
    cat <<'EOF'
glowcap caches — same tree on the host (~/.cache/glowcap) and in the
container (/home/vscode/.cache/glowcap). See .devcontainer/README.md
(Persistent paths).

  tool/   shared downloads (zig, deno, npm, pip, bun, uv, zls)
  cargo/  CARGO_HOME (registry, git, cargo install)

Per-worktree Zig objects and extracted packages live in the Docker volume
glowcap-dev-<worktree>-zig-work. See .devcontainer/README.md (Persistent paths).
EOF
}

glowcap_devcontainer_host_home_bind_rows() {
    glowcap_devcontainer_host_state_rows
    glowcap_devcontainer_host_cache_rows
}

# The variables Compose reads for a checkout's identity, named once. The guard
# below refuses an inherited value that disagrees with `.env`, and the host
# tests have to clear the same set before building checkouts of their own — two
# lists would drift, and the drift would show up as a test that passes on a host
# and fails in a devcontainer.
glowcap_devcontainer_compose_variables() {
    cat <<'EOF'
GLOWCAP_WORKTREE
GLOWCAP_CHECKOUT_DIR
GLOWCAP_GIT_COMMON_DIR
GLOWCAP_ROOMS_WEB_HOST_PORT
GLOWCAP_ROOMS_CAPTP_HOST_PORT
GLOWCAP_ROOMS_RELAY_HOST_PORT
GLOWCAP_ROOMS_TRACE_HOST_PORT
GLOWCAP_OCAPNVIZ_HOST_PORT
GLOWCAP_DOCS_HOST_PORT
EGRESS_NET
EOF
}
