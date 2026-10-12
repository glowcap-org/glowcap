# shellcheck shell=bash
# Codex driver: the exact npm package (glowcap_tools_npm_install).
#
# Update ownership: Codex publishes no suppression control. Its updater runs
# `npm install -g @openai/codex` against the image's root-owned prefix, so a
# bypassed update fails loudly instead of mutating the managed install. A
# bare `codex update` routes to the front.

glowcap_tools_codex_download() {
    glowcap_tools_npm_install "$2" "@openai/codex@$1"
}

glowcap_tools_codex_verify() {
    glowcap_tools_expect_version codex "*codex-cli $2*" "$1/bin/codex"
}

glowcap_tools_codex_exec_path() {
    printf '%s\n' "$1/bin/codex"
}

glowcap_tools_codex_intercept() {
    case "${1:-}" in
        update) glowcap_tools_intercept_verb codex "$@" ;;
        *) printf 'pass\n' ;;
    esac
}
