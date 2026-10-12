# shellcheck shell=bash
# Claude Code driver: the exact npm package (glowcap_tools_npm_install),
# which resolves a self-contained platform binary.
#
# Update ownership: the process runs with DISABLE_UPDATES=1, the strongest
# control the shipped binary implements (`claude update` then refuses with
# "Updates are disabled by your administrator"). A bare `claude update` or
# `upgrade` routes to the front; `claude install` is a native-installer
# migration and is refused.

glowcap_tools_claude_download() {
    glowcap_tools_npm_install "$2" "@anthropic-ai/claude-code@$1" \
        --allow-scripts=@anthropic-ai/claude-code
}

glowcap_tools_claude_verify() {
    glowcap_tools_expect_version claude "*$2*" "$1/bin/claude"
}

glowcap_tools_claude_exec_path() {
    printf '%s\n' "$1/bin/claude"
}

glowcap_tools_claude_exec_env() {
    printf '%s\n' "DISABLE_UPDATES=1"
}

glowcap_tools_claude_intercept() {
    case "${1:-}" in
        update | upgrade) glowcap_tools_intercept_verb claude "$@" ;;
        install) printf 'refuse:claude install would switch to the native installer outside this lifecycle; claude is already installed\n' ;;
        *) printf 'pass\n' ;;
    esac
}
