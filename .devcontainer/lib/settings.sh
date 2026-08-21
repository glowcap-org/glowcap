# shellcheck shell=bash
# The tables this directory configures itself from: pinned versions, the
# published ports, the host state each container shares, and the variables
# Compose expects.
#
# Every row here is a fact several files need to agree on, so it is written
# once and read rather than repeated. pins.sh and checksums.sh hold the
# version and hash values themselves; these helpers are how the rest of the
# directory reaches them.

pancake_devcontainer_source_pins() {
    local root="$1"
    # shellcheck disable=SC1091
    source "${root}/pins.sh"
    pancake_devcontainer_validate_pins
}

pancake_devcontainer_validate_pins() {
    case "${ZLS_ENABLED:-true}" in
        true)
            if [[ "${ZIG_VERSION%%.*}" != "${ZLS_VERSION%%.*}" ]]; then
                echo "pins.sh: ZIG_VERSION (${ZIG_VERSION}) and ZLS_VERSION (${ZLS_VERSION}) must target the same Zig generation" >&2
                return 1
            fi
            if [[ -z "${ZLS_SOURCE_REVISION:-}" || -z "${ZLS_SOURCE_SHA256:-}" ]]; then
                echo "pins.sh: ZLS source revision and SHA-256 must be pinned" >&2
                return 1
            fi
            ;;
        false) ;;
        *)
            echo "pins.sh: ZLS_ENABLED must be true or false, got '${ZLS_ENABLED}'" >&2
            return 1
            ;;
    esac
}

pancake_devcontainer_zls_enabled() {
    case "${ZLS_ENABLED:-true}" in
        true) return 0 ;;
        false) return 1 ;;
        *)
            echo "pins.sh: ZLS_ENABLED must be true or false, got '${ZLS_ENABLED}'" >&2
            return 2
            ;;
    esac
}

pancake_devcontainer_default_egress_network() {
    printf 'pancake-%s-egress\n' "$1"
}

pancake_devcontainer_port_rows() {
    printf '%s\n' \
        PANCAKE_ROOMS_WEB_HOST_PORT:8000 \
        PANCAKE_ROOMS_CAPTP_HOST_PORT:9099 \
        PANCAKE_ROOMS_RELAY_HOST_PORT:9200 \
        PANCAKE_ROOMS_TRACE_HOST_PORT:9300 \
        PANCAKE_OCAPNVIZ_HOST_PORT:5173 \
        PANCAKE_DOCS_HOST_PORT:1990
}

# User identity and agent-harness state shared by every pancake worktree. The
# host-relative source and absolute container target stay paired here so host
# initialization, container checks, and the committed mounts cannot drift.
pancake_devcontainer_host_state_rows() {
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

# The variables Compose reads for a checkout's identity, named once. The guard
# below refuses an inherited value that disagrees with `.env`, and the host
# tests have to clear the same set before building checkouts of their own — two
# lists would drift, and the drift would show up as a test that passes on a host
# and fails in a devcontainer.
pancake_devcontainer_compose_variables() {
    cat <<'EOF'
PANCAKE_WORKTREE
PANCAKE_GIT_COMMON_DIR
PANCAKE_ROOMS_WEB_HOST_PORT
PANCAKE_ROOMS_CAPTP_HOST_PORT
PANCAKE_ROOMS_RELAY_HOST_PORT
PANCAKE_ROOMS_TRACE_HOST_PORT
PANCAKE_OCAPNVIZ_HOST_PORT
PANCAKE_DOCS_HOST_PORT
EGRESS_NET
EOF
}
