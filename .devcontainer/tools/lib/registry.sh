# shellcheck shell=bash
# The managed-tool registry: one table owning every tool's identity. Tool
# names, the PATH names that answer for them, the pins.sh seed variable, and
# the update-pins dependency each upstream query uses are declared here and
# derived everywhere else, so an added tool is one row plus one driver.
#
# Sourced by bin/tools.sh, tools/wrapper.sh, and the tests after lib/mod.sh
# has loaded (pins included).
#
# tool | PATH names (comma-separated, "-" for none) | pins.sh version variable
#      | update-pins dep | selection policy (default seed)
#
#   seed      harnesses. A cold invocation installs the checkout's seed;
#             `ensure` also adopts a strictly newer seed; `update` moves to
#             the upstream latest, and that selection persists across
#             rebuilds.
#   pinned    exact-requirement assets (Playwright's browsers). The invoking
#             checkout's exact pin is prepared and selected as
#             required/<requirement>, so two worktrees on different pins
#             coexist; `update` refuses and names bin/update-pins.sh.
glowcap_tools_registry_rows() {
    printf '%s\n' \
        "claude|claude|CLAUDE_CODE_VERSION|claude|seed" \
        "codex|codex|CODEX_VERSION|codex|seed" \
        "opencode|opencode|OPENCODE_VERSION|opencode|seed" \
        "cursor-agent|agent,cursor-agent|CURSOR_AGENT_VERSION|cursor-agent|seed" \
        "playwright|-|PLAYWRIGHT_VERSION|playwright|pinned"
}

glowcap_tools_all() {
    glowcap_tools_registry_rows | cut -d'|' -f1
}

# The identifier form of a tool name: the prefix drivers and the lifecycle
# use for hook functions. Bash names cannot carry hyphens, so cursor-agent's
# hooks are glowcap_tools_cursor_agent_* while the tool key, the cache path,
# and the PATH names keep the upstream spelling.
glowcap_tools_ident() {
    printf '%s\n' "$(printf '%s' "$1" | tr '-' '_')"
}

glowcap_tools_path_names() {
    glowcap_tools_registry_rows | cut -d'|' -f2 | tr ',' '\n' | grep -v '^-$' || true
}

# The selection policy of one tool: seed or pinned.
glowcap_tools_policy() {
    glowcap_tools_registry_rows | grep -m1 "^$1|" | awk -F'|' '{ print ($5 == "" ? "seed" : $5) }'
}

glowcap_tools_seed_var() {
    local row
    row="$(glowcap_tools_registry_rows | grep -m1 "^$1|")" || return 1
    printf '%s\n' "${row}" | awk -F'|' '{ print $3 }'
}

glowcap_tools_dep() {
    glowcap_tools_registry_rows | grep -m1 "^$1|" | awk -F'|' '{ print $4 }'
}

# Map an invoked command name to its tool. Unknown names are a usage error.
glowcap_tools_for_name() {
    local name="$1" row names
    while IFS= read -r row; do
        names="${row#*|}"; names="${names%%|*}"
        if [[ ",${names}," == *",${name},"* ]]; then
            printf '%s\n' "${row%%|*}"
            return 0
        fi
    done < <(glowcap_tools_registry_rows)
    echo "tools: '${name}' is not a managed command; managed names: $(glowcap_tools_path_names | tr '\n' ' ')" >&2
    return 64
}

# The checkout's seed version for a tool, read from the pin variable.
glowcap_tools_seed() {
    local var
    var="$(glowcap_tools_seed_var "$1")"
    printf '%s\n' "${!var}"
}

# Every name one tool answers to, one per line.
glowcap_tools_names_for() {
    local aliases
    aliases="$(glowcap_tools_registry_rows | grep -m1 "^$1|" | cut -d'|' -f2)"
    if [[ "${aliases}" == "-" ]]; then
        return 0
    fi
    printf '%s\n' "${aliases}" | tr ',' '\n'
}
